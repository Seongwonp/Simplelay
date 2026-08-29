"""본선 데모용 전송: RPi5 → 게이트웨이 ESP32 → (ESP-NOW) → 가전 노드.

왜 게이트웨이가 끼는가: ESP-NOW는 ESP32 라디오끼리만 통한다. RPi5에는 그 라디오가
없으므로 UART로 붙은 ESP32가 대신 쏴준다. 게이트웨이 역할은 기존 폰 BLE 폴백
브릿지 ESP32가 겸한다(팀 결정) -- 전용 보드를 추가하지 않는 대신, **같은 UART에
BLE 브릿지 트래픽이 함께 흐른다**.

    RPi5 --UART--> 게이트웨이 ESP32 --ESP-NOW--> 노드 ESP32 --UART--> RPi4

HTTP 경로(esp_node_controller.py)와 같은 ButtonSequenceController 계약을 지킨다 --
전송 교체가 배선 변경으로 끝나야 하기 때문이다. 타임아웃 산정식도 같은 값을 쓴다:
두 경로가 서로 다른 시각에 포기하면 "한쪽은 실패로 보고, 다른 쪽은 계속 실행"이라는
가장 위험한 상태가 만들어진다.

연결은 pyserial에 묶지 않고 덕타이핑으로 주입받는다(act_client.py와 같은 방식) --
테스트에서 가짜 포트를 넣을 수 있고, 프로덕션에서는 serial.Serial을 그대로 넘긴다.

**포트는 리더 스레드 하나가 소유한다.** 처음에는 실행 대기 루프가 포트를 직접 읽고
자기 것이 아닌 줄을 건너뛰었는데, 그건 "무시"가 아니라 **소비하고 버리는** 것이었다.
같은 UART에 흐르는 BLE 브릿지 트래픽(제안·결과·센서)이 실행 대기 중에 도착하면 그대로
사라졌다. 지금은 리더가 모든 줄을 읽어 종류에 따라 나눠 주고, 임자 없는 줄은 버리는
대신 콜백으로 넘긴다.
"""

from __future__ import annotations

import json
import logging
import re
import threading
from collections.abc import Callable
from typing import Protocol

from rpi.controller import ExecutionResult

from .aggregate_result import synthesize_execution_result
from .esp_node_controller import (
    EXECUTE_BASE_TIMEOUT_SECONDS,
    EXECUTE_PER_BUTTON_SECONDS,
)

log = logging.getLogger(__name__)

STOP_REQUEST_TIMEOUT_SECONDS = 2.0

# 포트가 즉시 b""를 돌려주는 구현(테스트용 가짜 등)에서 리더가 CPU를 태우지 않게 하는
# 최소 간격. 실제 pyserial은 자체 read timeout으로 알아서 쉬므로 영향이 없다.
_IDLE_SLEEP_SECONDS = 0.002

_MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")

# 이 링크가 처리하는 줄 종류. 나머지는 전부 임자 없는 줄로 넘긴다.
_RESULT_TYPES = frozenset({"node_result", "node_error"})


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


def _parse_line(raw: bytes) -> dict | None:
    try:
        doc = json.loads(raw.decode("utf-8").strip())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None  # 깨진 줄이거나 JSON이 아닌 트래픽
    return doc if isinstance(doc, dict) else None


class _Waiter:
    """실행 한 건이 응답을 기다리는 자리. 리더 스레드가 채우고 실행 스레드가 읽는다."""

    __slots__ = ("done", "success", "retry", "error")

    def __init__(self) -> None:
        self.done = threading.Event()
        self.success = False
        self.retry = 0
        self.error: str | None = None


class EspNowGatewayLink:
    """게이트웨이 UART 하나를 여러 노드 컨트롤러가 공유한다.

    **리더 스레드가 포트를 단독으로 읽는다.** 읽은 줄은 sequence_id로 대기 중인
    실행에게 전달하고, 임자가 없으면 ``on_unclaimed_line``으로 넘긴다(기본은 디버그
    로그). 실행 대기 루프가 포트를 직접 읽던 이전 구조는 남의 줄을 소비해 없애버렸다.

    쓰기는 ``_write_lock``으로 직렬화한다. **실행 대기는 락을 잡지 않는다** --
    한때 실행이 응답 대기 내내 락을 쥐고 있어서 정지가 그 뒤에 줄을 섰고, 실행 중에는
    정지가 아예 나가지 않았다(화면은 정지, 실물은 계속 동작). 지금은 대기가
    ``threading.Event``라 어떤 락도 붙잡지 않는다.
    """

    def __init__(
        self,
        port: SerialLike,
        on_unclaimed_line: Callable[[dict], None] | None = None,
    ) -> None:
        self._port = port
        self._on_unclaimed = on_unclaimed_line
        self._write_lock = threading.Lock()
        self._waiters_lock = threading.Lock()
        self._waiters: dict[str, _Waiter] = {}
        self._seq = 0
        self._closed = threading.Event()
        self._reader = threading.Thread(
            target=self._read_loop, name="espnow-gateway-reader", daemon=True
        )
        self._reader.start()

    # ── 수신 ──────────────────────────────────────────────────────────────

    def _read_loop(self) -> None:
        while not self._closed.is_set():
            try:
                raw = self._port.readline()
            except Exception:  # noqa: BLE001 -- 포트가 끊겨도 스레드는 조용히 끝난다
                log.exception("게이트웨이 포트 읽기 실패 — 리더 종료")
                return
            if not raw:
                # 포트 자체 read 타임아웃. 종료 신호를 확인할 겸 잠깐 쉰다.
                self._closed.wait(_IDLE_SLEEP_SECONDS)
                continue
            doc = _parse_line(raw)
            if doc is None:
                continue
            self._route(doc)

    def _route(self, doc: dict) -> None:
        kind = doc.get("type")
        sequence_id = doc.get("sequence_id")
        if kind in _RESULT_TYPES and isinstance(sequence_id, str):
            with self._waiters_lock:
                waiter = self._waiters.get(sequence_id)
            if waiter is not None:
                if kind == "node_error":
                    waiter.error = str(doc.get("error", "unknown"))
                else:
                    waiter.success = bool(doc.get("success", False))
                    waiter.retry = int(doc.get("retry", 0))
                waiter.done.set()
                return
            # 이미 포기한 실행의 늦은 응답 — 버리되 조용히는 아니다
            log.info("임자 없는 노드 응답(늦은 도착?): %s", sequence_id)
            return

        # BLE 브릿지 트래픽 등 우리 것이 아닌 줄. 이전에는 여기서 사라졌다.
        if self._on_unclaimed is not None:
            try:
                self._on_unclaimed(doc)
            except Exception:  # noqa: BLE001 -- 남의 줄 처리가 전송을 죽이면 안 된다
                log.exception("임자 없는 줄 처리 중 오류")
        else:
            log.debug("게이트웨이 UART의 다른 트래픽: %s", kind)

    # ── 송신 ──────────────────────────────────────────────────────────────

    def _next_sequence_id(self) -> str:
        with self._waiters_lock:
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
        sequence_id = self._next_sequence_id()
        waiter = _Waiter()
        with self._waiters_lock:
            self._waiters[sequence_id] = waiter
        try:
            self._send(
                {
                    "type": "node_execute",
                    "sequence_id": sequence_id,
                    "mac": mac,
                    "buttons": list(buttons),
                }
            )
            if not waiter.done.wait(timeout):
                raise EspNowGatewayError(
                    f"노드 {mac}가 {timeout:.0f}초 안에 응답하지 않았습니다"
                )
            if waiter.error is not None:
                raise EspNowGatewayError(
                    f"게이트웨이가 노드 {mac} 오류를 보고: {waiter.error}"
                )
            return waiter.success, waiter.retry
        finally:
            with self._waiters_lock:
                self._waiters.pop(sequence_id, None)

    def request_stop(self, mac: str) -> None:
        """정지 요청.

        **어떤 대기도 거치지 않는다** -- 정지가 가장 필요한 순간이 바로 실행 중이기
        때문이다. 쓰기 락만 잠깐 잡으므로 실행이 응답을 기다리는 중에도 즉시 나간다.

        예외는 삼킨다: 정지 경로에서 던지면 여러 노드 브로드캐스트가 첫 실패에서
        멈춰 나머지 노드가 계속 동작한다.
        """
        try:
            self._send({"type": "node_stop", "mac": mac})
        except Exception as exc:  # noqa: BLE001 -- 정지는 best-effort
            log.error("노드 %s 정지 요청 실패: %s", mac, exc)

    def close(self) -> None:
        """리더 스레드를 멈춘다. 포트 자체는 만든 쪽이 닫는다."""
        self._closed.set()
        self._reader.join(timeout=2.0)


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
