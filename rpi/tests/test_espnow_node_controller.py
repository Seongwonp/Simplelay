"""ESP-NOW 노드 컨트롤러 -- 게이트웨이 UART를 가짜 포트로 대신해 검증한다.

실기기 없이 확인할 수 있는 것: 프로토콜 모양, 시퀀스 대조, BLE 브릿지 트래픽
무시, 타임아웃 시 정지 전송, 실패 결과 합성.
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


class FakePort:
    """게이트웨이 UART 대역. 보낸 줄을 기록하고 미리 넣어둔 줄을 돌려준다."""

    def __init__(self, replies: list[str] | None = None) -> None:
        self.written: list[dict] = []
        self._replies = list(replies or [])

    def write(self, data: bytes) -> int:
        for line in data.decode("utf-8").splitlines():
            if line.strip():
                self.written.append(json.loads(line))
        return len(data)

    def readline(self) -> bytes:
        if not self._replies:
            return b""  # 포트 read 타임아웃과 같은 상태
        return (self._replies.pop(0) + "\n").encode("utf-8")

    def queue(self, doc: dict) -> None:
        self._replies.append(json.dumps(doc, ensure_ascii=False))

    def queue_raw(self, line: str) -> None:
        self._replies.append(line)

    def sent_types(self) -> list[str]:
        return [m.get("type") for m in self.written]


def _link_and_port(*, auto_reply: bool = True) -> tuple[EspNowGatewayLink, FakePort]:
    port = FakePort()
    link = EspNowGatewayLink(port)
    if auto_reply:
        port.queue({"type": "node_result", "sequence_id": "gw-1", "success": True, "retry": 0})
    return link, port


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
        # 실행 트래픽이 조용히 사라진다
        with pytest.raises(ValueError):
            normalize_mac(bad)


class TestExecute:
    def test_sends_execute_with_mac_and_buttons(self):
        link, port = _link_and_port()

        EspNowNodeController(_MAC, link).execute(["해동", "시작"])

        sent = port.written[0]
        assert sent["type"] == "node_execute"
        assert sent["mac"] == _MAC
        assert sent["buttons"] == ["해동", "시작"]

    def test_success_result_marks_every_button_succeeded(self):
        link, _ = _link_and_port()

        result = EspNowNodeController(_MAC, link).execute(["해동", "시작"])

        assert result.status is ExecutionStatus.SUCCEEDED
        assert [b.status for b in result.buttons] == [
            ButtonStatus.SUCCEEDED,
            ButtonStatus.SUCCEEDED,
        ]

    def test_failure_result_marks_last_button_failed_with_attempts(self):
        port = FakePort()
        port.queue({"type": "node_result", "sequence_id": "gw-1", "success": False, "retry": 2})

        result = EspNowNodeController(_MAC, EspNowGatewayLink(port)).execute(["해동", "시작"])

        assert result.status is ExecutionStatus.SAFETY_STOPPED
        assert result.buttons[-1].status is ButtonStatus.FAILED
        assert result.buttons[-1].attempts == 3

    def test_ignores_ble_bridge_traffic_on_the_shared_uart(self):
        # 게이트웨이는 BLE 브릿지 역할을 겸하므로 같은 UART에 남의 줄이 섞인다
        port = FakePort()
        port.queue({"type": "suggestion", "label": "우유 데우기"})
        port.queue_raw("not json at all")
        port.queue({"type": "node_result", "sequence_id": "gw-99", "success": False, "retry": 9})
        port.queue({"type": "node_result", "sequence_id": "gw-1", "success": True, "retry": 0})

        result = EspNowNodeController(_MAC, EspNowGatewayLink(port)).execute(["시작"])

        assert result.status is ExecutionStatus.SUCCEEDED

    def test_gateway_error_raises(self):
        port = FakePort()
        port.queue({"type": "node_error", "sequence_id": "gw-1", "error": "peer unreachable"})

        with pytest.raises(EspNowGatewayError, match="peer unreachable"):
            EspNowNodeController(_MAC, EspNowGatewayLink(port)).execute(["시작"])

    def test_timeout_raises_and_requests_stop(self):
        # 응답만 못 받았을 뿐 노드는 계속 누르고 있을 수 있다 -- HTTP 경로와 같은 원칙
        port = FakePort()  # 아무 응답도 없음
        controller = EspNowNodeController(
            _MAC, EspNowGatewayLink(port), base_timeout_seconds=0.05,
            per_button_timeout_seconds=0.0,
        )

        with pytest.raises(EspNowGatewayError):
            controller.execute(["시작"])

        assert "node_stop" in port.sent_types()

    def test_gateway_error_also_requests_stop(self):
        port = FakePort()
        port.queue({"type": "node_error", "sequence_id": "gw-1", "error": "boom"})
        controller = EspNowNodeController(_MAC, EspNowGatewayLink(port))

        with pytest.raises(EspNowGatewayError):
            controller.execute(["시작"])

        assert "node_stop" in port.sent_types()


class TestTimeoutFormula:
    def test_matches_http_path_formula(self):
        # 두 경로가 다른 시각에 포기하면 한쪽은 실패 보고, 다른 쪽은 계속 실행이 된다
        from rpi.services.esp_node_controller import EspNodeController

        link, _ = _link_and_port()
        espnow = EspNowNodeController(_MAC, link)
        http = EspNodeController("http://192.0.2.1:8080")

        for count in (0, 1, 5, 20):
            assert espnow.timeout_for(count) == http.timeout_for(count)
        http.close()


class TestStop:
    def test_request_stop_sends_mac(self):
        link, port = _link_and_port(auto_reply=False)

        EspNowNodeController(_MAC, link).request_stop()

        assert port.written[-1] == {"type": "node_stop", "mac": _MAC}

    def test_stop_failure_is_swallowed(self):
        # 정지 브로드캐스트 도중 예외가 나면 다른 노드의 정지까지 막힌다
        class BrokenPort(FakePort):
            def write(self, data: bytes) -> int:
                raise OSError("port gone")

        link = EspNowGatewayLink(BrokenPort())

        EspNowNodeController(_MAC, link).request_stop()  # 예외가 새어나오면 실패

    def test_close_does_not_close_shared_link(self):
        link, port = _link_and_port(auto_reply=False)
        controller = EspNowNodeController(_MAC, link)

        controller.close()

        # 링크는 다른 노드도 쓰므로 살아 있어야 한다
        controller.request_stop()
        assert port.sent_types() == ["node_stop"]


class TestControllerFactory:
    def test_binds_shared_link_and_matches_registry_signature(self):
        link, port = _link_and_port(auto_reply=False)

        make = controller_factory(link)
        controller = make(_MAC)

        assert isinstance(controller, EspNowNodeController)
        controller.request_stop()
        assert port.written[-1]["mac"] == _MAC

    def test_rejects_non_mac_address(self):
        link, _ = _link_and_port(auto_reply=False)

        with pytest.raises(ValueError):
            controller_factory(link)("http://192.168.0.5:8080")


# ═══════════════════════════════════════════════════════════════════════════════
# 실행 중 긴급 정지 (동시성)
# ═══════════════════════════════════════════════════════════════════════════════

class _BlockingPort(FakePort):
    """execute를 응답 없이 붙잡아 두는 포트. 정지가 그 사이 나가는지 보기 위한 것."""

    def __init__(self) -> None:
        super().__init__()
        self.execute_sent = threading.Event()

    def write(self, data: bytes) -> int:
        n = super().write(data)
        if self.written and self.written[-1].get("type") == "node_execute":
            self.execute_sent.set()
        return n

    def readline(self) -> bytes:
        time.sleep(0.005)  # 응답이 오지 않는 상태를 흉내낸다(바쁜 대기 방지)
        return b""


class TestStopDuringExecution:
    """실행이 응답을 기다리는 **도중에** 정지가 실제로 전선에 나가야 한다.

    한동안 execute()가 응답 대기 내내 락을 쥐고 있고 request_stop()이 같은 락을
    요구해서, 정지가 실행이 끝난 뒤에야 전송됐다. 화면은 정지됐다는데 실물은 계속
    누르는 상태 — 기존 테스트는 execute가 타임아웃으로 락을 놓은 뒤를 확인해서
    이 실패를 잡지 못했다.
    """

    def test_stop_is_written_while_execute_is_still_waiting(self):
        port = _BlockingPort()
        controller = EspNowNodeController(
            _MAC,
            EspNowGatewayLink(port),
            base_timeout_seconds=3.0,      # 정지 확인 여유보다 훨씬 길게
            per_button_timeout_seconds=0.0,
        )

        def run_execute() -> None:
            with contextlib.suppress(EspNowGatewayError):
                controller.execute(["시작"])

        worker = threading.Thread(target=run_execute, daemon=True)
        worker.start()
        assert port.execute_sent.wait(1.0), "execute가 전송되지 않았다"

        # 실행이 아직 대기 중인 시점에 정지를 건다
        stopped = threading.Event()

        def run_stop() -> None:
            controller.request_stop()
            stopped.set()

        threading.Thread(target=run_stop, daemon=True).start()

        # 실행 타임아웃(3초)보다 훨씬 짧은 시간 안에 끝나야 한다.
        # 락에 막히면 여기서 실패한다.
        assert stopped.wait(1.0), "정지가 실행 락에 막혔다"
        assert "node_stop" in port.sent_types(), "정지가 전선에 나가지 않았다"

        worker.join(timeout=6.0)
        assert not worker.is_alive()

    def test_stop_does_not_corrupt_the_in_flight_execute_line(self):
        # 정지가 실행 대기 중에 끼어들어도 각 줄은 온전해야 한다
        port = _BlockingPort()
        link = EspNowGatewayLink(port)
        controller = EspNowNodeController(
            _MAC, link, base_timeout_seconds=1.0, per_button_timeout_seconds=0.0
        )

        def run_execute() -> None:
            with contextlib.suppress(EspNowGatewayError):
                controller.execute(["해동", "시작"])

        worker = threading.Thread(target=run_execute, daemon=True)
        worker.start()
        assert port.execute_sent.wait(1.0)
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
