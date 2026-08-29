"""본선 데모용 전송: RPi5 → 게이트웨이 ESP32 → (ESP-NOW) → 가전 노드.

왜 게이트웨이가 끼는가: ESP-NOW는 ESP32 라디오끼리만 통한다. RPi5에는 그 라디오가
없으므로 UART로 붙은 ESP32가 대신 쏴준다. 게이트웨이 역할은 기존 폰 BLE 폴백
브릿지 ESP32가 겸한다(팀 결정) -- 전용 보드를 추가하지 않는 대신, **같은 UART에
BLE 브릿지 트래픽이 함께 흐른다**. 그래서 이 링크는 자기 것이 아닌 줄을 조용히
건너뛴다.

    RPi5 --UART--> 게이트웨이 ESP32 --ESP-NOW--> 노드 ESP32 --UART--> RPi4

HTTP 경로(esp_node_controller.py)와 같은 ButtonSequenceController 계약을 지킨다 --
전송 교체가 배선 변경으로 끝나야 하기 때문이다. 타임아웃 산정식도 같은 값을 쓴다:
두 경로가 서로 다른 시각에 포기하면 "한쪽은 실패로 보고, 다른 쪽은 계속 실행"이라는
가장 위험한 상태가 만들어진다.

연결은 pyserial에 묶지 않고 덕타이핑으로 주입받는다(act_client.py와 같은 방식) --
테스트에서 가짜 포트를 넣을 수 있고, 프로덕션에서는 serial.Serial을 그대로 넘긴다.
"""

from __future__ import annotations

import json
import logging
import re
import threading
import time
from typing import Protocol

from rpi.controller import ExecutionResult

from .aggregate_result import synthesize_execution_result
from .esp_node_controller import (
    EXECUTE_BASE_TIMEOUT_SECONDS,
    EXECUTE_PER_BUTTON_SECONDS,
)

log = logging.getLogger(__name__)

STOP_REQUEST_TIMEOUT_SECONDS = 2.0

_MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")


class EspNowGatewayError(RuntimeError):
    """게이트웨이가 응답하지 않거나 오류를 보고했을 때."""


def normalize_mac(value: str) -> str:
    """노드 주소(MAC)를 검증하고 대문자로 통일한다.

    HTTP 모드의 base_url 자리에 MAC이 들어오므로, 형식이 틀리면 여기서 잡아야
    한다 -- 안 그러면 실행 트래픽이 엉뚱한 곳으로 가거나 조용히 사라진다.
    """
    mac = value.strip()
    if not _MAC_RE.match(mac):
        raise ValueError(f"노드 주소가 MAC 형식이 아닙니다: {value!r}")
    return mac.upper()


class SerialLike(Protocol):
    """pyserial의 Serial과 같은 모양이면 무엇이든 된다(테스트용 가짜 포함)."""

    def write(self, data: bytes) -> int: ...
    def readline(self) -> bytes: ...


class EspNowGatewayLink:
    """게이트웨이 UART 하나를 여러 노드 컨트롤러가 공유한다.

    **락을 두 개로 나눈다.** 처음엔 하나로 묶었는데, 그러면 `execute()`가 응답을
    기다리는 내내 락을 쥐고 있어서 `request_stop()`이 그 뒤에 줄을 선다 --
    즉 **실행 중에는 정지가 나가지 않고**, 실행이 끝나거나 타임아웃된 뒤에야
    전송된다. 화면은 정지됐다고 돌아오는데 실물은 계속 누르는 상태로, 이
    프로젝트에서 가장 위험한 실패 모드다(교차 리뷰 치명 지적).

    - ``_write_lock``: 한 줄을 쓰는 동안만 잡는다. 아주 짧고, 실행·정지가 공유한다.
    - ``_exec_lock``: 실행 한 건의 송신~응답 대기를 직렬화한다(포트 읽기 소유권).
      정지는 **이 락을 건드리지 않는다.**
    """

    def __init__(self, port: SerialLike) -> None:
        self._port = port
        self._write_lock = threading.Lock()
        self._exec_lock = threading.Lock()
        self._seq = 0

    def _next_sequence_id(self) -> str:
        self._seq += 1
        return f"gw-{self._seq}"

    def _send(self, message: dict) -> None:
        """한 줄을 원자적으로 쓴다 -- 실행 대기 중 정지가 끼어들어도 줄이 섞이지 않는다."""
        line = json.dumps(message, ensure_ascii=False) + "\n"
        with self._write_lock:
            self._port.write(line.encode("utf-8"))

    def execute(
        self, mac: str, buttons: list[str], timeout: float
    ) -> tuple[bool, int]:
        """노드에 버튼 시퀀스를 보내고 결과를 기다린다. (success, retry) 반환."""
        with self._exec_lock:
            sequence_id = self._next_sequence_id()
            self._send(
                {
                    "type": "node_execute",
                    "sequence_id": sequence_id,
                    "mac": mac,
                    "buttons": list(buttons),
                }
            )
            return self._await_result(sequence_id, mac, timeout)

    def _await_result(
        self, sequence_id: str, mac: str, timeout: float
    ) -> tuple[bool, int]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            raw = self._port.readline()
            if not raw:
                continue  # 포트 자체 read 타임아웃 -- 마감까지는 계속 기다린다
            doc = _parse_line(raw)
            if doc is None:
                continue
            # 이 UART에는 BLE 브릿지 트래픽도 흐른다. 우리 것이 아니면 넘긴다.
            if doc.get("sequence_id") != sequence_id:
                continue

            kind = doc.get("type")
            if kind == "node_result":
                return bool(doc.get("success", False)), int(doc.get("retry", 0))
            if kind == "node_error":
                raise EspNowGatewayError(
                    f"게이트웨이가 노드 {mac} 오류를 보고: {doc.get('error')}"
                )

        raise EspNowGatewayError(
            f"노드 {mac}가 {timeout:.0f}초 안에 응답하지 않았습니다"
        )

    def request_stop(self, mac: str) -> None:
        """정지 요청.

        **실행 락을 거치지 않는다** -- 정지가 가장 필요한 순간이 바로 실행 중이기
        때문이다. 쓰기 락만 잠깐 잡으므로 실행이 응답을 기다리는 중에도 즉시 나간다.

        예외는 삼킨다: 정지 경로에서 던지면 여러 노드 브로드캐스트가 첫 실패에서
        멈춰 나머지 노드가 계속 동작한다.
        """
        try:
            self._send({"type": "node_stop", "mac": mac})
        except Exception as exc:  # noqa: BLE001 -- 정지는 best-effort
            log.error("노드 %s 정지 요청 실패: %s", mac, exc)


def _parse_line(raw: bytes) -> dict | None:
    try:
        doc = json.loads(raw.decode("utf-8").strip())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None  # 브릿지의 다른 트래픽이거나 깨진 줄
    return doc if isinstance(doc, dict) else None


class EspNowNodeController:
    """한 가전 노드를 담당하는 컨트롤러. 주소가 URL이 아니라 MAC이다."""

    def __init__(
        self,
        mac: str,
        link: EspNowGatewayLink,
        base_timeout_seconds: float = EXECUTE_BASE_TIMEOUT_SECONDS,
        per_button_timeout_seconds: float = EXECUTE_PER_BUTTON_SECONDS,
    ) -> None:
        self._mac = normalize_mac(mac)
        self._link = link
        self._base_timeout = base_timeout_seconds
        self._per_button_timeout = per_button_timeout_seconds

    def timeout_for(self, button_count: int) -> float:
        return self._base_timeout + self._per_button_timeout * max(0, button_count)

    def execute(self, buttons: list[str] | tuple[str, ...]) -> ExecutionResult:
        buttons = list(buttons)
        timeout = self.timeout_for(len(buttons))
        try:
            success, retry = self._link.execute(self._mac, buttons, timeout)
        except EspNowGatewayError:
            # 응답만 못 받았을 뿐 노드는 아직 누르고 있을 수 있다 -- HTTP 경로와
            # 같은 원칙으로 반드시 정지를 보낸다.
            self.request_stop()
            raise
        return synthesize_execution_result(buttons, success, retry)

    def request_stop(self) -> None:
        self._link.request_stop(self._mac)

    def close(self) -> None:
        """링크는 여러 노드가 공유하므로 여기서 닫지 않는다."""


def controller_factory(link: EspNowGatewayLink):
    """NodeRegistry가 기대하는 ``Callable[[str], ButtonSequenceController]``를 만든다.

    등록된 주소(여기서는 MAC)만 받아 컨트롤러를 만드는 모양이라, 공유 링크는
    이 클로저가 들고 있는다 -- 레지스트리는 전송 방식을 몰라도 된다.
    """

    def _make(mac: str) -> EspNowNodeController:
        return EspNowNodeController(mac, link)

    return _make
