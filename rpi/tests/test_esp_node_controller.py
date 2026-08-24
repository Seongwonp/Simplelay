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
    controller.execute(["해동", "시간 90초", "시작"])

    # httpx는 timeout을 extensions로 전달한다 — 30 + 6*3 = 48초
    assert seen["timeout"]["read"] == 48.0


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


@pytest.mark.parametrize("status", [400, 500])
def test_client_and_handler_errors_do_not_request_stop(status):
    # 400/500은 실행이 시작되지 않은 경우 — 불필요한 정지를 보내지 않는다
    stop_calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/stop":
            stop_calls.append(1)
            return httpx.Response(200, json={"ok": True})
        return httpx.Response(status, text="error")

    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError):
        controller.execute(["시작"])

    assert stop_calls == []


def test_stop_failure_during_timeout_does_not_mask_the_timeout_error():
    # 정지 전송까지 실패해도 호출자는 원래의 타임아웃 실패를 봐야 한다
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("node down", request=request)

    controller = EspNodeController("http://node:8080", client=_client(handler))

    with pytest.raises(EspNodeError, match="could not reach"):
        controller.execute(["시작"])


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
    controller.request_stop()  # 예외가 새어 나오면 여기서 실패


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
