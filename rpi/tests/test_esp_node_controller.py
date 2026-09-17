"""EspNodeController tests — httpx.MockTransport instead of a real node."""

import json

import httpx
import pytest

from rpi.controller import ButtonStatus, ExecutionStatus
from rpi.services.esp_node_controller import EspNodeController, EspNodeError


def _client(handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


def test_execute_sends_buttons_to_the_nodes_execute_endpoint():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={"success": True, "retry": 0})

    controller = EspNodeController("http://192.168.1.42:8080", client=_client(handler))
    controller.execute(["해동", "시작"])

    assert seen["url"] == "http://192.168.1.42:8080/execute"
    assert seen["body"] == {"buttons": ["해동", "시작"]}


def test_execute_success_marks_all_buttons_succeeded():
    controller = EspNodeController(
        "http://node",
        client=_client(lambda r: httpx.Response(200, json={"success": True, "retry": 0})),
    )

    result = controller.execute(["해동", "시작"])

    assert result.status is ExecutionStatus.SUCCEEDED
    assert [b.button for b in result.buttons] == ["해동", "시작"]
    assert all(b.status is ButtonStatus.SUCCEEDED for b in result.buttons)


def test_execute_failure_marks_last_button_failed_with_retry_count():
    controller = EspNodeController(
        "http://node",
        client=_client(lambda r: httpx.Response(200, json={"success": False, "retry": 2})),
    )

    result = controller.execute(["해동", "시작"])

    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert result.buttons[0].status is ButtonStatus.SUCCEEDED
    assert result.buttons[1].status is ButtonStatus.FAILED
    assert result.buttons[1].attempts == 3  # retry + 1


def test_base_url_trailing_slash_is_stripped():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"success": True, "retry": 0})

    controller = EspNodeController("http://node/", client=_client(handler))
    controller.execute(["시작"])

    assert seen["url"] == "http://node/execute"


def test_non_200_response_raises_esp_node_error():
    controller = EspNodeController(
        "http://node",
        client=_client(lambda r: httpx.Response(500, text="internal error")),
    )

    with pytest.raises(EspNodeError, match="500"):
        controller.execute(["시작"])


def test_network_error_raises_esp_node_error():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    controller = EspNodeController("http://node", client=_client(handler))

    with pytest.raises(EspNodeError, match="could not reach"):
        controller.execute(["시작"])


# ── 실행 타임아웃과 정지 일치 (최종 교차 리뷰 치명) ─────────────────────────


def test_execute_timeout_scales_with_button_count():
    controller = EspNodeController("http://node:8080")
    addfinalizer = controller.close
    try:
        assert controller.timeout_for(0) == 30.0
        assert controller.timeout_for(1) == 36.0
        assert controller.timeout_for(5) == 60.0  # 고정 10초였다면 오판 실패
    finally:
        addfinalizer()


def test_execute_passes_dynamic_timeout_to_the_request():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["timeout"] = request.extensions.get("timeout")
        return httpx.Response(200, json={"success": True, "retry": 0})

    controller = EspNodeController("http://node:8080", client=_client(handler))
    controller.execute(["즉석밥", "시작"])

    # httpx는 timeout을 extensions로 전달한다 — 30 + 6*2 = 42초
    assert seen["timeout"]["read"] == 42.0


def test_execute_timeout_requests_stop_before_raising():
    # 화면은 실패인데 실물은 계속 누르는 불일치를 막는 지점 —
    # 포기하는 순간 정지 포트로 abort가 나가야 한다
    stop_calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/stop":
            stop_calls.append(str(request.url))
            return httpx.Response(200, json={"ok": True})
        raise httpx.ReadTimeout("timed out", request=request)

    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match="stop requested"):
        controller.execute(["시작"])

    assert stop_calls == ["http://node:8081/stop"]


def test_node_504_also_requests_stop():
    # 504 = 노드가 RPi4 응답을 못 받고 포기 — RPi4는 아직 실행 중일 수 있다
    stop_calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/stop":
            stop_calls.append(str(request.url))
            return httpx.Response(200, json={"ok": True})
        return httpx.Response(504, text='{"error":"no response from RPi4"}')

    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match="504"):
        controller.execute(["시작"])

    assert len(stop_calls) == 1


# ── 포기할 땐 정지 (교차 리뷰 #9) ───────────────────────────────────────────
#
# 규칙: **정지를 생략하는 경우는 "정지가 닿을 수 없는 경우" 하나뿐이다.**
# 예전에는 400/500을 "실행이 시작되지 않았다"고 단정해 생략했는데, 그건 노드 펌웨어의
# 현재 구현에 기댄 추론이었다. 아래 테스트들이 그 뒤집힌 규칙을 고정한다.


def _stop_counting_handler(respond):
    """/stop 호출을 세면서 나머지 요청은 respond(request)에 맡긴다."""
    stop_calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/stop":
            stop_calls.append(str(request.url))
            return httpx.Response(200, json={"ok": True})
        return respond(request)

    return handler, stop_calls


@pytest.mark.parametrize("status", [400, 404, 500, 502, 504])
def test_every_non_200_response_requests_stop(status):
    # 어떤 상태 코드가 "실행 전에 거절됐다"는 뜻인지는 노드 펌웨어의 사정이다.
    # 프록시나 그 주소의 다른 기기가 답했을 수도 있으므로 단정하지 않는다 —
    # 불필요한 정지는 유휴 RPi4가 무시하지만, 빠뜨린 정지는 실물이 계속 눌린다.
    handler, stop_calls = _stop_counting_handler(
        lambda r: httpx.Response(status, text="error")
    )
    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match=str(status)):
        controller.execute(["시작"])

    assert stop_calls == ["http://node:8081/stop"]


@pytest.mark.parametrize(
    "exc_factory",
    [
        lambda r: httpx.ConnectError("connection refused", request=r),
        lambda r: httpx.ConnectTimeout("connect timed out", request=r),
        lambda r: httpx.PoolTimeout("pool exhausted", request=r),
    ],
    ids=["connect-error", "connect-timeout", "pool-timeout"],
)
def test_connection_failures_skip_the_stop(exc_factory):
    """연결이 성립하지 않았다면 정지도 닿지 못한다 — 보내봐야 시간만 버린다.

    죽은 노드 하나가 실패마다 정지 타임아웃(2초)을 추가로 붙잡으면, 노드를 모두
    도는 경로에서 그 지연이 곱해진다.
    """
    def respond(request):
        raise exc_factory(request)

    handler, stop_calls = _stop_counting_handler(respond)
    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match="could not reach"):
        controller.execute(["시작"])

    assert stop_calls == []


@pytest.mark.parametrize(
    "exc_factory",
    [
        lambda r: httpx.ReadError("connection reset", request=r),
        lambda r: httpx.WriteError("broken pipe", request=r),
        lambda r: httpx.RemoteProtocolError("server disconnected", request=r),
    ],
    ids=["read-error", "write-error", "remote-protocol-error"],
)
def test_connection_lost_after_sending_requests_stop(exc_factory):
    """요청을 보낸 뒤 끊긴 것은 타임아웃과 같은 상황이다 — 노드는 계속 누른다.

    이 갈래가 예전에는 정지를 보내지 않았다. 시연장 Wi-Fi가 한 번 끊기기만 해도
    "화면은 실패, 실물은 동작 중"이 그대로 재현된다.
    """
    def respond(request):
        raise exc_factory(request)

    handler, stop_calls = _stop_counting_handler(respond)
    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match="lost contact"):
        controller.execute(["시작"])

    assert stop_calls == ["http://node:8081/stop"]


def test_stop_failure_does_not_mask_the_original_error():
    # 정지 전송까지 실패해도 호출자는 원래의 실패(타임아웃)를 봐야 한다.
    # 정지 경로가 예외를 던지면 그것이 원인을 덮어써서 진단이 어려워진다.
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/stop":
            raise httpx.ConnectError("stop port unreachable", request=request)
        raise httpx.ReadTimeout("timed out", request=request)

    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match="did not respond within"):
        controller.execute(["시작"])


def test_200_with_a_non_json_body_raises_without_requesting_stop():
    # 펌웨어는 실행 핸들러가 반환한 뒤에만 200을 보낸다 → 이미 끝난 실행이다.
    # 본문이 깨졌다고 정지를 보낼 이유가 없다(멀쩡한 다음 실행을 건드릴 뿐).
    handler, stop_calls = _stop_counting_handler(
        lambda r: httpx.Response(200, text="<html>captive portal</html>")
    )
    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match="not JSON"):
        controller.execute(["시작"])

    assert stop_calls == []


def test_200_with_a_non_object_body_raises_clearly():
    # body.get(...)이 AttributeError로 터지면 원인이 전송 문제로 보인다
    handler, stop_calls = _stop_counting_handler(
        lambda r: httpx.Response(200, json=[1, 2, 3])
    )
    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match="non-object body"):
        controller.execute(["시작"])

    assert stop_calls == []


def test_request_stop_posts_to_stop_port():
    # 펌웨어의 정지 리스너는 HTTP 포트 + 1 (config.h STOP_PORT) — /execute가
    # 블로킹 중이어도 받는 별도 포트다
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"ok": True})

    controller = EspNodeController("http://192.168.1.42:8080", client=_client(handler))
    controller.request_stop()

    assert seen["url"] == "http://192.168.1.42:8081/stop"


def test_request_stop_defaults_to_port_80_plus_one():
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"ok": True})

    controller = EspNodeController("http://node", client=_client(handler))
    controller.request_stop()

    assert seen["url"] == "http://node:81/stop"


def test_request_stop_swallows_network_errors():
    # 정지 브로드캐스트 중 죽은 노드 하나가 예외로 다른 노드의 정지를
    # 막으면 안 된다
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    controller = EspNodeController("http://node:8080", client=_client(handler))
    # 예외가 새어 나오면 여기서 실패. 삼키되 미확인으로는 드러낸다
    assert controller.request_stop() is False


def test_request_stop_reports_receipt_only_for_2xx():
    # True는 '노드가 요청을 받았다'는 응답이지 물리 정지 확인이 아니다 —
    # 오류 응답을 받았다고 세면 안 된다
    ok = EspNodeController(
        "http://node:8080",
        client=_client(lambda r: httpx.Response(200, json={"ok": True})),
    )
    broken = EspNodeController(
        "http://node:8080",
        client=_client(lambda r: httpx.Response(500, json={"ok": False})),
    )

    assert ok.request_stop() is True
    assert broken.request_stop() is False


def test_close_closes_an_owned_client():
    controller = EspNodeController("http://node")  # no injected client -> owns one
    controller.close()
    assert controller._client.is_closed


def test_close_does_not_close_an_injected_client():
    client = _client(lambda r: httpx.Response(200, json={"success": True, "retry": 0}))
    controller = EspNodeController("http://node", client=client)

    controller.close()

    assert not client.is_closed
    client.close()
