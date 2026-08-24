"""RPi5 side of the RPi5 <-> RPi4 UART protocol (docs/protocol.md) — the
mirror image of rpi4/services/act_executor.py's ActExecutor, which is the
RPi4 side of this same link.

  OUTBOUND (RPi5 -> RPi4)          INBOUND (RPi4 -> RPi5)
  ──────────────────────────────────────────────────────────
  execute {sequence_id, buttons} ←  result {sequence_id, success, retry}
                                   ←  error  {sequence_id, reason}
  abort                           ←  (no reply expected)
  (nothing — self-initiated)      ←  alert {kind, band_energy_ratio,
                                       mean_period_seconds} / alert_cleared

`execute()` sends one sequence and awaits its matching result/error — RPi4
only ever runs one sequence at a time, so only one execute() may be
in-flight per ActClient. `alert`/`alert_cleared` are unsolicited pushes
that can arrive at any time (even mid-execute) and are forwarded to
`on_alert` immediately rather than resolving the pending execute().

Duck-typed reader/writer, matching ActExecutor's and UartBridge's pattern:
  - real hardware: asyncio.StreamReader / asyncio.StreamWriter (serial_asyncio)
  - tests:         asyncio.StreamReader.feed_data() / a fake writer
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from collections import deque
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Protocol

log = logging.getLogger(__name__)


class ActLinkError(RuntimeError):
    """Base class for RPi5-side failures talking to the RPi4 board."""


class ActLinkBusyError(ActLinkError):
    """Raised when execute() is called while a previous call is still in flight."""


class ActLinkTimeoutError(ActLinkError):
    """Raised when RPi4 doesn't respond within the configured timeout."""


@dataclass(frozen=True)
class ActClientConfig:
    # 시퀀스 길이와 무관한 기본 여유(연결·해석·홈 복귀 등)
    response_timeout_seconds: float = 30.0
    # 버튼 1개당 추가 여유 — 실기기에서 버튼 하나는 이동+누름+검증+재시도
    # (최대 3회)로 수 초가 걸린다. 고정 30s는 6버튼 이상 시퀀스가 정상
    # 진행 중인데도 timeout으로 오판되는 원인이었다(교차 리뷰 #6).
    #
    # 기본 6초는 실측이 아닌 설계 추정치다. 실기기에서 (이동 최악값 + 누름 +
    # 센서 판정 창 + 재시도 3회)의 p95를 재서 SIMPLELAY_UART_PER_BUTTON_TIMEOUT
    # 으로 조정한다 — 코드 수정 없이 현장에서 맞출 수 있어야 한다.
    per_button_timeout_seconds: float = 6.0

    def timeout_for(self, button_count: int) -> float:
        return self.response_timeout_seconds + (
            self.per_button_timeout_seconds * max(0, button_count)
        )

    @classmethod
    def from_env(cls) -> "ActClientConfig":
        """실기기 캘리브레이션용 env 오버라이드. 잘못된 값은 무시하고 기본값."""

        def _positive(name: str, fallback: float) -> float:
            raw = os.environ.get(name, "").strip()
            if not raw:
                return fallback
            try:
                value = float(raw)
            except ValueError:
                log.warning("%s=%r is not a number — using %s", name, raw, fallback)
                return fallback
            if value < 0:
                log.warning("%s=%r is negative — using %s", name, raw, fallback)
                return fallback
            return value

        return cls(
            response_timeout_seconds=_positive(
                "SIMPLELAY_UART_BASE_TIMEOUT", cls.response_timeout_seconds
            ),
            per_button_timeout_seconds=_positive(
                "SIMPLELAY_UART_PER_BUTTON_TIMEOUT", cls.per_button_timeout_seconds
            ),
        )


@dataclass(frozen=True)
class ActResult:
    sequence_id: str
    success: bool
    retry: int


@dataclass(frozen=True)
class AlertEvent:
    """Parsed form of RPi4's self-initiated alert/alert_cleared messages."""

    kind: str
    raised: bool  # True = "alert" (just started), False = "alert_cleared"
    band_energy_ratio: float | None = None
    mean_period_seconds: float | None = None


def _parse_alert(doc: dict) -> AlertEvent | None:
    msg_type = doc.get("type")
    if msg_type not in ("alert", "alert_cleared"):
        return None
    kind = doc.get("kind")
    if not isinstance(kind, str) or not kind:
        return None
    return AlertEvent(
        kind=kind,
        raised=msg_type == "alert",
        band_energy_ratio=doc.get("band_energy_ratio"),
        mean_period_seconds=doc.get("mean_period_seconds"),
    )


class _WriterLike(Protocol):
    def write(self, data: bytes) -> None: ...
    async def drain(self) -> None: ...


class ActClient:
    """Sends resolved button sequences to the RPi4 board and awaits results.

    Args:
        reader:    asyncio.StreamReader (serial or test-injected)
        writer:    asyncio.StreamWriter-compatible (serial or fake)
        config:    Response timeout, etc.
        on_alert:  Called from the background read loop whenever RPi4 pushes
                   an alert/alert_cleared — fire-and-forget, not awaited.
    """

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: _WriterLike,
        config: ActClientConfig | None = None,
        on_alert: Callable[[AlertEvent], None] | None = None,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self._cfg = config or ActClientConfig()
        self._on_alert = on_alert
        # (sequence_id, future) — 수신한 result/error를 반드시 현재 요청의
        # sequence_id와 대조해서 완료시킨다. 대조 없이 완료시키면, timeout으로
        # 버려진 이전 요청의 늦은 응답이 다음 요청의 결과로 오인된다.
        self._pending: tuple[str, asyncio.Future[dict]] | None = None
        # timeout으로 포기한 sequence_id의 무덤 — 늦게 도착한 응답을
        # '알 수 없는 메시지'가 아니라 '지연 도착'으로 명시적으로 폐기한다.
        self._stale_sequence_ids: deque[str] = deque(maxlen=8)
        self._read_task: asyncio.Task[None] | None = None

    # ── Public API ───────────────────────────────────────────────────────────

    async def start(self) -> None:
        """Start the background read loop. Call once before execute()/abort()."""
        self._read_task = asyncio.create_task(self._read_loop())

    async def stop(self) -> None:
        """Cancel the background read loop. Safe to call more than once."""
        if self._read_task is None:
            return
        self._read_task.cancel()
        try:
            await self._read_task
        except asyncio.CancelledError:
            pass
        self._read_task = None

    async def execute(
        self, buttons: Sequence[str], sequence_id: str | None = None
    ) -> ActResult:
        """Send one button sequence and await RPi4's result.

        Raises ActLinkBusyError if a previous execute() hasn't resolved yet,
        ActLinkTimeoutError if RPi4 never responds, ActLinkError if RPi4
        reports an ``error`` message for this sequence.
        """
        if self._pending is not None and not self._pending[1].done():
            raise ActLinkBusyError("an execute() call is already awaiting a response")

        seq_id = sequence_id or str(uuid.uuid4())
        timeout = self._cfg.timeout_for(len(buttons))
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict] = loop.create_future()
        self._pending = (seq_id, future)

        # _send()도 반드시 이 try 안에 있어야 한다. 밖에 두면 UART 단선으로
        # drain()이 실패했을 때 _pending이 영원히 남아(future는 끝내 완료되지
        # 않음) 이후 모든 실행이 ActLinkBusyError로 거부됐다 — 케이블 접촉
        # 불량 한 번이 재부팅 전까지 실행 경로를 통째로 막는 구조였다.
        try:
            await self._send(
                {"type": "execute", "sequence_id": seq_id, "buttons": list(buttons)}
            )
            doc = await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError as exc:
            # 이 sequence의 응답이 늦게라도 오면 폐기 대상으로 기록
            self._stale_sequence_ids.append(seq_id)
            # RPi5는 지금부터 이 실행을 실패로 보고한다 — RPi4가 아직 버튼을
            # 누르고 있을 수 있으므로 중단도 함께 요청한다(불일치 방지).
            # 전송 실패는 로그만: timeout 예외 경로를 덮어쓰면 안 된다.
            try:
                await self._send({"type": "abort"})
            except Exception:
                log.exception("abort send after timeout failed")
            raise ActLinkTimeoutError(
                f"no response for sequence_id={seq_id!r} within {timeout}s"
            ) from exc
        finally:
            # 내 요청일 때만 비운다 — 이 execute()가 늦게 정리되는 사이
            # 다음 요청이 _pending을 차지했다면 그것을 지워선 안 된다.
            if self._pending is not None and self._pending[0] == seq_id:
                self._pending = None

        if doc.get("type") == "error":
            raise ActLinkError(
                f"RPi4 reported error for sequence_id={seq_id!r}: {doc.get('reason', 'unknown')}"
            )
        return ActResult(
            sequence_id=doc.get("sequence_id", seq_id),
            success=bool(doc.get("success", False)),
            retry=int(doc.get("retry", 0)),
        )

    async def abort(self) -> None:
        """Request RPi4 abort — best-effort, no reply is awaited (see protocol.md)."""
        await self._send({"type": "abort"})

    async def inject_failure(self, button_index: int, attempts: int) -> None:
        """리허설 실패 주입 무장을 RPi4로 전달 — abort처럼 응답 없는 단방향
        (protocol.md). 검증이 RPi4에서 일어나는 UART 모드에서 POST
        /demo/inject-failure가 실제로 발동하게 하는 다리다."""
        await self._send({
            "type": "inject_failure",
            "button_index": button_index,
            "attempts": attempts,
        })

    async def clear_failure(self) -> None:
        """무장 해제(DELETE /demo/inject-failure의 UART 전달판)."""
        await self._send({"type": "clear_failure"})

    def response_timeout_for(self, button_count: int) -> float:
        """이 클라이언트가 해당 길이의 시퀀스에 허용할 응답 대기 시간.
        동기 브리지(ActClientController)가 자기 대기 시간을 여기에 맞춘다."""
        return self._cfg.timeout_for(button_count)

    # ── Background read loop ────────────────────────────────────────────────

    async def _read_loop(self) -> None:
        try:
            while True:
                raw_bytes = await self._reader.readuntil(b"\n")
                raw = raw_bytes.decode("utf-8", errors="replace").strip()
                if raw:
                    self._handle_line(raw)
        except asyncio.IncompleteReadError:
            log.info("ActClient: serial stream closed (EOF)")
        except asyncio.CancelledError:
            raise

    def _handle_line(self, raw: str) -> None:
        log.debug("RX <- %s", raw)
        try:
            doc = json.loads(raw)
        except json.JSONDecodeError:
            log.warning("ActClient: ignored unparseable line: %.120s", raw)
            return
        if not isinstance(doc, dict):
            return

        msg_type = doc.get("type")
        if msg_type in ("result", "error"):
            received_id = doc.get("sequence_id")
            pending = self._pending
            if (
                pending is not None
                and not pending[1].done()
                and received_id == pending[0]
            ):
                pending[1].set_result(doc)
            elif received_id in self._stale_sequence_ids:
                # timeout으로 이미 실패 처리한 요청의 지연 응답 — 조용히 폐기.
                # 대조 없이 완료시키면 다음 job의 결과로 오인된다.
                log.warning(
                    "ActClient: late %s for timed-out sequence %r discarded",
                    msg_type, received_id,
                )
            else:
                log.warning("ActClient: unsolicited %s ignored: %.120s", msg_type, raw)
            return

        event = _parse_alert(doc)
        if event is not None and self._on_alert is not None:
            self._on_alert(event)
        # "ack" (per-step progress) and unknown types: not yet consumed.

    # ── IO helper ────────────────────────────────────────────────────────────

    async def _send(self, doc: dict) -> None:
        payload = (json.dumps(doc, ensure_ascii=False) + "\n").encode("utf-8")
        log.debug("TX -> %s", payload.rstrip().decode())
        self._writer.write(payload)
        await self._writer.drain()
