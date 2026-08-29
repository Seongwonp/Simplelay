"""ESP-NOW 노드 컨트롤러 -- 게이트웨이 UART를 가짜 포트로 대신해 검증한다.

실기기 없이 확인할 수 있는 것: 프로토콜 모양, 시퀀스 대조, 공유 UART의 다른 트래픽
처리, 실행 중 정지, 타임아웃 시 정지 전송, 실패 결과 합성.

가짜 포트는 **요청을 받고 나서** 응답을 내놓는다. 링크가 리더 스레드로 포트를 읽기
때문에 응답을 미리 넣어두면 실행이 대기자를 등록하기도 전에 읽혀 버린다 -- 실제
게이트웨이도 요청을 받아야 답하므로 이쪽이 실제 동작에 더 가깝다.
"""

from __future__ import annotations

import contextlib
import json
import threading
import time

import pytest

from rpi.controller import ButtonStatus, ExecutionStatus
from rpi.services.espnow_node_controller import (
    EspNowGatewayError,
    EspNowGatewayLink,
    EspNowNodeController,
    controller_factory,
    normalize_mac,
)

_MAC = "AA:BB:CC:DD:EE:FF"

# 타임아웃을 실제로 기다려야 하는 테스트용 짧은 값 (기본값은 30초 + 6초/버튼)
_FAST = {"base_timeout_seconds": 0.4, "per_button_timeout_seconds": 0.0}


class FakePort:
    """게이트웨이 UART 대역.

    보낸 줄을 기록하고, ``reply_to_execute``가 설정돼 있으면 node_execute를 받는
    즉시 그 응답을 큐에 넣는다(요청의 sequence_id를 자동으로 채워서).
    """

    def __init__(self) -> None:
        self.written: list[dict] = []
        self.reply_to_execute: dict | None = None
        self.extra_traffic: list[dict | str] = []  # 응답 앞에 섞어 보낼 남의 줄
        self._replies: list[bytes] = []
        self._lock = threading.Lock()

    # ── 링크가 쓰는 쪽 ──
    def write(self, data: bytes) -> int:
        for line in data.decode("utf-8").splitlines():
            if not line.strip():
                continue
            doc = json.loads(line)
            self.written.append(doc)
            if doc.get("type") == "node_execute" and self.reply_to_execute is not None:
                self.queue_response_for(doc["sequence_id"])
        return len(data)

    def readline(self) -> bytes:
        with self._lock:
            if self._replies:
                return self._replies.pop(0)
        time.sleep(0.001)  # 실제 포트의 read 타임아웃 대역
        return b""

    # ── 테스트가 쓰는 쪽 ──
    def queue_response_for(self, sequence_id: str) -> None:
        lines: list[bytes] = []
        for item in self.extra_traffic:
            raw = item if isinstance(item, str) else json.dumps(item, ensure_ascii=False)
            lines.append((raw + "\n").encode("utf-8"))
        reply = dict(self.reply_to_execute or {})
        reply.setdefault("sequence_id", sequence_id)
        lines.append((json.dumps(reply, ensure_ascii=False) + "\n").encode("utf-8"))
        with self._lock:
            self._replies.extend(lines)

    def queue_raw(self, doc: dict) -> None:
        with self._lock:
            self._replies.append(
                (json.dumps(doc, ensure_ascii=False) + "\n").encode("utf-8")
            )

    def sent_types(self) -> list[str]:
        return [m.get("type") for m in self.written]

    def wait_for_sent(self, kind: str, timeout: float = 1.0) -> None:
        deadline = time.monotonic() + timeout
        while kind not in self.sent_types():
            assert time.monotonic() < deadline, f"{kind}가 전송되지 않았다"
            time.sleep(0.005)


@pytest.fixture
def port() -> FakePort:
    return FakePort()


@pytest.fixture
def link(port: FakePort):
    made = EspNowGatewayLink(port)
    yield made
    made.close()


@pytest.fixture
def ok_link(port: FakePort):
    """성공 응답을 돌려주는 링크."""
    port.reply_to_execute = {"type": "node_result", "success": True, "retry": 0}
    made = EspNowGatewayLink(port)
    yield made
    made.close()


class TestNormalizeMac:
    def test_uppercases(self):
        assert normalize_mac("aa:bb:cc:dd:ee:ff") == _MAC

    def test_strips_whitespace(self):
        assert normalize_mac("  AA:BB:CC:DD:EE:FF  ") == _MAC

    @pytest.mark.parametrize(
        "bad", ["", "not-a-mac", "AA:BB:CC:DD:EE", "http://192.168.0.5:8080", "AABBCCDDEEFF"]
    )
    def test_rejects_bad_format(self, bad: str):
        # HTTP 모드의 base_url 자리를 그대로 쓰므로 형식 검증이 없으면
        # 실행 트래픽이 엉뚱한 곳으로 가거나 조용히 사라진다
        with pytest.raises(ValueError):
            normalize_mac(bad)


class TestExecute:
    def test_sends_execute_with_mac_and_buttons(self, port: FakePort, ok_link):
        EspNowNodeController(_MAC, ok_link, **_FAST).execute(["해동", "시작"])

        sent = port.written[0]
        assert sent["type"] == "node_execute"
        assert sent["mac"] == _MAC
        assert sent["buttons"] == ["해동", "시작"]

    def test_success_result_marks_every_button_succeeded(self, ok_link):
        result = EspNowNodeController(_MAC, ok_link, **_FAST).execute(["해동", "시작"])

        assert result.status is ExecutionStatus.SUCCEEDED
        assert [b.status for b in result.buttons] == [
            ButtonStatus.SUCCEEDED,
            ButtonStatus.SUCCEEDED,
        ]

    def test_failure_result_marks_last_button_failed_with_attempts(
        self, port: FakePort
    ):
        port.reply_to_execute = {"type": "node_result", "success": False, "retry": 2}
        made = EspNowGatewayLink(port)
        try:
            result = EspNowNodeController(_MAC, made, **_FAST).execute(["해동", "시작"])
        finally:
            made.close()

        assert result.status is ExecutionStatus.SAFETY_STOPPED
        assert result.buttons[-1].status is ButtonStatus.FAILED
        assert result.buttons[-1].attempts == 3

    def test_other_traffic_on_the_shared_uart_does_not_break_the_result(
        self, port: FakePort
    ):
        # 게이트웨이는 BLE 브릿지 역할을 겸하므로 같은 UART에 남의 줄이 섞인다
        port.extra_traffic = [
            {"type": "suggestion", "label": "우유 데우기"},
            "not json at all",
            {"type": "node_result", "sequence_id": "gw-999", "success": False, "retry": 9},
        ]
        port.reply_to_execute = {"type": "node_result", "success": True, "retry": 0}
        made = EspNowGatewayLink(port)
        try:
            result = EspNowNodeController(_MAC, made, **_FAST).execute(["시작"])
        finally:
            made.close()

        assert result.status is ExecutionStatus.SUCCEEDED

    def test_unclaimed_lines_are_handed_over_not_swallowed(self, port: FakePort):
        """남의 줄은 **버리는 게 아니라** 넘겨준다.

        이전 구조는 실행 대기 루프가 포트를 직접 읽으며 자기 것이 아닌 줄을 소비하고
        버렸다 -- BLE 브릿지의 제안·센서 줄이 실행 중에 도착하면 그대로 사라졌다.
        """
        seen: list[dict] = []
        port.extra_traffic = [{"type": "suggestion", "label": "우유 데우기"}]
        port.reply_to_execute = {"type": "node_result", "success": True, "retry": 0}
        made = EspNowGatewayLink(port, on_unclaimed_line=seen.append)
        try:
            EspNowNodeController(_MAC, made, **_FAST).execute(["시작"])
        finally:
            made.close()

        assert [d["type"] for d in seen] == ["suggestion"]

    def test_gateway_error_raises(self, port: FakePort):
        port.reply_to_execute = {"type": "node_error", "error": "peer unreachable"}
        made = EspNowGatewayLink(port)
        try:
            with pytest.raises(EspNowGatewayError, match="peer unreachable"):
                EspNowNodeController(_MAC, made, **_FAST).execute(["시작"])
        finally:
            made.close()

    def test_timeout_raises_and_requests_stop(self, port: FakePort, link):
        # 응답만 못 받았을 뿐 노드는 계속 누르고 있을 수 있다 -- HTTP 경로와 같은 원칙
        controller = EspNowNodeController(_MAC, link, **_FAST)

        with pytest.raises(EspNowGatewayError):
            controller.execute(["시작"])

        assert "node_stop" in port.sent_types()

    def test_gateway_error_also_requests_stop(self, port: FakePort):
        port.reply_to_execute = {"type": "node_error", "error": "boom"}
        made = EspNowGatewayLink(port)
        try:
            with pytest.raises(EspNowGatewayError):
                EspNowNodeController(_MAC, made, **_FAST).execute(["시작"])
        finally:
            made.close()

        assert "node_stop" in port.sent_types()

    def test_late_response_for_an_abandoned_request_is_ignored(
        self, port: FakePort, link
    ):
        """포기한 실행의 늦은 응답이 다음 실행 결과로 쓰이면 안 된다."""
        controller = EspNowNodeController(_MAC, link, **_FAST)
        with pytest.raises(EspNowGatewayError):
            controller.execute(["시작"])  # 타임아웃으로 포기

        # 첫 요청의 응답이 이제야 도착한다
        first_seq = port.written[0]["sequence_id"]
        port.queue_raw(
            {"type": "node_result", "sequence_id": first_seq, "success": True, "retry": 0}
        )
        time.sleep(0.05)

        # 두 번째 실행은 자기 응답만 받아야 한다
        port.reply_to_execute = {"type": "node_result", "success": False, "retry": 1}
        result = controller.execute(["시작"])

        assert result.status is ExecutionStatus.SAFETY_STOPPED


class TestTimeoutFormula:
    def test_matches_http_path_formula(self, link):
        # 두 경로가 다른 시각에 포기하면 한쪽은 실패 보고, 다른 쪽은 계속 실행이 된다
        from rpi.services.esp_node_controller import EspNodeController

        espnow = EspNowNodeController(_MAC, link)
        http = EspNodeController("http://192.0.2.1:8080")

        for count in (0, 1, 5, 20):
            assert espnow.timeout_for(count) == http.timeout_for(count)
        http.close()


class TestStop:
    def test_request_stop_sends_mac(self, port: FakePort, link):
        EspNowNodeController(_MAC, link).request_stop()

        assert port.written[-1] == {"type": "node_stop", "mac": _MAC}

    def test_stop_failure_is_swallowed(self):
        # 정지 브로드캐스트 도중 예외가 나면 다른 노드의 정지까지 막힌다
        class BrokenPort(FakePort):
            def write(self, data: bytes) -> int:
                raise OSError("port gone")

        made = EspNowGatewayLink(BrokenPort())
        try:
            EspNowNodeController(_MAC, made).request_stop()  # 예외가 새면 실패
        finally:
            made.close()

    def test_close_does_not_close_shared_link(self, port: FakePort, link):
        controller = EspNowNodeController(_MAC, link)

        controller.close()

        # 링크는 다른 노드도 쓰므로 살아 있어야 한다
        controller.request_stop()
        assert port.sent_types() == ["node_stop"]


class TestControllerFactory:
    def test_binds_shared_link_and_matches_registry_signature(
        self, port: FakePort, link
    ):
        controller = controller_factory(link)(_MAC)

        assert isinstance(controller, EspNowNodeController)
        controller.request_stop()
        assert port.written[-1]["mac"] == _MAC

    def test_rejects_non_mac_address(self, link):
        with pytest.raises(ValueError):
            controller_factory(link)("http://192.168.0.5:8080")


# ═══════════════════════════════════════════════════════════════════════════════
# 실행 중 긴급 정지 (동시성)
# ═══════════════════════════════════════════════════════════════════════════════

class TestStopDuringExecution:
    """실행이 응답을 기다리는 **도중에** 정지가 실제로 전선에 나가야 한다.

    한동안 execute()가 응답 대기 내내 락을 쥐고 있고 request_stop()이 같은 락을
    요구해서, 정지가 실행이 끝난 뒤에야 전송됐다. 화면은 정지됐다는데 실물은 계속
    누르는 상태 — 기존 테스트는 execute가 락을 놓은 뒤를 확인해서 이를 못 잡았다.
    """

    def test_stop_is_written_while_execute_is_still_waiting(
        self, port: FakePort, link
    ):
        # 응답을 주지 않아 실행이 계속 대기한다
        controller = EspNowNodeController(
            _MAC, link, base_timeout_seconds=3.0, per_button_timeout_seconds=0.0
        )

        def run_execute() -> None:
            with contextlib.suppress(EspNowGatewayError):
                controller.execute(["시작"])

        worker = threading.Thread(target=run_execute, daemon=True)
        worker.start()
        port.wait_for_sent("node_execute")

        stopped = threading.Event()

        def run_stop() -> None:
            controller.request_stop()
            stopped.set()

        threading.Thread(target=run_stop, daemon=True).start()

        # 실행 타임아웃(3초)보다 훨씬 짧은 시간 안에 끝나야 한다.
        # 대기가 락을 잡고 있으면 여기서 실패한다.
        assert stopped.wait(1.0), "정지가 실행 대기에 막혔다"
        assert "node_stop" in port.sent_types(), "정지가 전선에 나가지 않았다"

        worker.join(timeout=6.0)
        assert not worker.is_alive()

    def test_stop_does_not_corrupt_the_in_flight_execute_line(
        self, port: FakePort, link
    ):
        # 정지가 실행 대기 중에 끼어들어도 각 줄은 온전해야 한다
        controller = EspNowNodeController(
            _MAC, link, base_timeout_seconds=0.6, per_button_timeout_seconds=0.0
        )

        def run_execute() -> None:
            with contextlib.suppress(EspNowGatewayError):
                controller.execute(["해동", "시작"])

        worker = threading.Thread(target=run_execute, daemon=True)
        worker.start()
        port.wait_for_sent("node_execute")
        for _ in range(5):
            controller.request_stop()
        worker.join(timeout=6.0)

        # FakePort.write가 줄마다 json.loads를 하므로, 깨진 줄이 있었다면
        # 여기 도달하기 전에 예외가 났을 것이다.
        assert port.written[0]["type"] == "node_execute"
        assert port.written[0]["buttons"] == ["해동", "시작"]
        # 직접 보낸 5회 + 타임아웃이 스스로 보내는 1회
        assert port.sent_types().count("node_stop") >= 5
        assert all(m["mac"] == _MAC for m in port.written if m["type"] == "node_stop")
