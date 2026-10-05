"""RPi5 side of the RPi5 <-> RPi4 UART protocol (docs/protocol.md) — the
mirror image of rpi4/services/act_executor.py's ActExecutor, which is the
RPi4 side of this same link.

  OUTBOUND (RPi5 -> RPi4)          INBOUND (RPi4 -> RPi5)
  ──────────────────────────────────────────────────────────
  execute {sequence_id, buttons} ←  result {sequence_id, success, retry,
                                             outcome?, button_results?,
                                             operation_confirmed?, operation_detail?,
                                             operation_source?, execution_mode?}
                                   ←  error  {sequence_id, reason}
                                   ←  progress {sequence_id, button, attempt,
                                       phase, ...}  (optional, never a result)
  abort {scope?}                  ←  (no reply expected)
  verify_pass {sequence_id,       ←  verify_result {sequence_id, ok, targets}
               targets}               (확인 주행, 2026-09-30 — progress phase "verify"가 먼저 온다)
  execute {..., hold?}            ←  progress {phase:"hold", hold_state, stop_outcome, ...}
                                      (정지 버튼 대기·보관 보고 — 결과 뒤에도 온다. ``last_hold``)
  (after an L3-confirmed result)  ←  progress {phase:"power_tail", power_tail:{status, tail_s, ...}}
                                      (콘센트 모듈 잔여 전류 꼬리 기록, 2026-10-05. ``last_power_tail``)
  (nothing — self-initiated)      ←  alert {kind, band_energy_ratio,
                                       mean_period_seconds} / alert_cleared
  estop_ack                       ←  estop_state {latched, source, reason, detail}
                                      (콘센트 모듈 비상정지 걸림 해제 확인, 2026-10-05. 걸릴 때도 자발로 온다.
                                       ``estop_latched``·``estop_detail``에 남는다)

`execute()` sends one sequence and awaits its matching result/error — RPi4
only ever runs one sequence at a time, so only one execute() may be
in-flight per ActClient. `alert`/`alert_cleared` are unsolicited pushes
that can arrive at any time (even mid-execute) and are forwarded to
`on_alert` immediately rather than resolving the pending execute().
`progress` frames (2026-09-29, optional) never resolve execute() either --
they are only recorded (``tap``) and forwarded to ``on_progress``; a result
still comes only from a ``result`` frame.

``tap`` (rpi/services/link_tap.py): every line sent or received is recorded
there (ring buffer + optional JSONL session log). Tap failures never break
the link.

Duck-typed reader/writer, matching ActExecutor's and UartBridge's pattern:
  - real hardware: asyncio.StreamReader / asyncio.StreamWriter (serial_asyncio)
  - tests:         asyncio.StreamReader.feed_data() / a fake writer
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import uuid
from collections import deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from rpi.controller.models import ButtonTarget

    from .link_tap import LinkFrameTap

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


#: result 프레임의 ``outcome`` 값(docs/protocol.md). rpi.controller.ExecutionOutcome과 같다.
RESULT_OUTCOMES = frozenset({"success", "failed", "stopped", "safety_stop"})


@dataclass(frozen=True)
class ActResult:
    sequence_id: str
    success: bool
    retry: int
    #: RPi4가 보고한 종료 방식(success|failed|stopped|safety_stop). 필드가 없는
    #: 옛 RPi4거나 값이 이상하면 None -- 호출자가 실패 이유를 모르는 것으로 다룬다.
    outcome: str | None = None
    #: 버튼별 보고(2026-09-29). 없거나 형식이 틀리면 None -- 집계 값으로 합성한다.
    button_results: "tuple[ButtonReport, ...] | None" = None
    #: L3 판정. True/False, 판정기 없음·미판정·옛 프레임이면 None.
    operation_confirmed: bool | None = None
    operation_detail: str | None = None
    #: 판정 입력 real | mock. 모르면 None(실제 근거로 치지 않는다).
    operation_source: str | None = None
    #: RPi4가 밝힌 실행 환경 real | mock | unknown. 옛 프레임이면 None.
    execution_mode: str | None = None


@dataclass(frozen=True)
class ButtonReport:
    """result 프레임 ``button_results``의 한 칸 -- RPi4 폐루프가 실제로 센 값."""

    button: str
    ok: bool
    attempts: int
    #: 실패했다면 층(L1/L2/L3). 성공이면 None.
    layer: str | None = None
    #: 재시도 누름마다의 정성 보정 {retry_number, xy_adjustment_required, increase_press_depth}.
    corrections: tuple[dict, ...] = ()


_LAYERS = frozenset({"L1", "L2", "L3"})


def parse_button_results(doc: dict, buttons: Sequence[str], success: bool) -> "tuple[ButtonReport, ...] | None":
    """``button_results``를 엄격하게 읽는다. 하나라도 이상하면 전체를 버린다(None).

    버린다는 것은 집계 ``retry``로 되돌아간다는 뜻이다(종전 동작). 요청한 시퀀스의
    앞부분이 아니거나, 성공이라면서 전 버튼을 덮지 않거나 실패 칸이 있으면 믿지 않는다.
    """
    raw = doc.get("button_results")
    if raw is None:
        return None
    try:
        if not isinstance(raw, list) or len(raw) > len(buttons):
            raise ValueError("length")
        reports = []
        for i, item in enumerate(raw):
            if not isinstance(item, dict):
                raise ValueError("item")
            button, ok, attempts = item.get("button"), item.get("ok"), item.get("attempts")
            layer = item.get("layer")
            if button != buttons[i] or not isinstance(ok, bool):
                raise ValueError("button")
            if isinstance(attempts, bool) or not isinstance(attempts, int) or attempts < 1:
                raise ValueError("attempts")
            if layer is not None and layer not in _LAYERS:
                raise ValueError("layer")
            corrections = item.get("corrections") or []
            if not isinstance(corrections, list) or not all(isinstance(c, dict) for c in corrections):
                raise ValueError("corrections")
            reports.append(ButtonReport(button, ok, attempts, layer,
                                        tuple(dict(c) for c in corrections)))
        if success and (len(reports) != len(buttons) or not all(r.ok for r in reports)):
            raise ValueError("success mismatch")
        if any(not r.ok for r in reports[:-1]):
            raise ValueError("failure before the end")
    except ValueError as exc:
        log.warning("ActClient: malformed button_results ignored (%s)", exc)
        return None
    return tuple(reports)


def parse_operation(doc: dict) -> tuple[bool | None, str | None, str | None]:
    """(operation_confirmed, operation_detail, operation_source). 형식이 틀리면 None으로."""
    confirmed = doc.get("operation_confirmed")
    if not isinstance(confirmed, bool):
        if confirmed is not None:
            log.warning("ActClient: operation_confirmed %r ignored", confirmed)
        confirmed = None
    detail = doc.get("operation_detail")
    detail = detail if isinstance(detail, str) and detail else None
    source = doc.get("operation_source")
    source = source if source in ("real", "mock") else None
    return confirmed, detail, source


def parse_execution_mode(doc: dict) -> str | None:
    mode = doc.get("execution_mode")
    return mode if mode in ("real", "mock", "unknown") else None


def parse_result_outcome(doc: dict, success: bool) -> str | None:
    """result 프레임의 ``outcome``을 읽는다. 없거나 모르는 값·``success``와 모순이면 None.

    ``success``가 기준이다(옛 프레임과의 호환 축). ``success=true``인데
    ``outcome=stopped``처럼 둘이 어긋나면 어느 쪽도 믿지 않고 보고 없음으로 둔다
    -- 정지를 성공으로, 실패를 정지로 바꿔 적지 않는다.
    """
    raw = doc.get("outcome")
    if raw is None:
        return None
    if not isinstance(raw, str) or raw not in RESULT_OUTCOMES:
        log.warning("ActClient: unknown result outcome %r ignored", raw)
        return None
    if (raw == "success") != success:
        log.warning(
            "ActClient: result outcome %r contradicts success=%s — ignored", raw, success
        )
        return None
    return raw


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
        tap: "LinkFrameTap | None" = None,
        on_progress: Callable[[dict], None] | None = None,
    ) -> None:
        self._reader = reader
        self._writer = writer
        self._cfg = config or ActClientConfig()
        self._on_alert = on_alert
        #: 보내고 받은 모든 줄의 기록(rpi/services/link_tap.py). None이면 기록 안 함.
        self.tap = tap
        self._on_progress = on_progress
        # (sequence_id, future) — 수신한 result/error를 반드시 현재 요청의
        # sequence_id와 대조해서 완료시킨다. 대조 없이 완료시키면, timeout으로
        # 버려진 이전 요청의 늦은 응답이 다음 요청의 결과로 오인된다.
        self._pending: tuple[str, asyncio.Future[dict]] | None = None
        # timeout으로 포기한 sequence_id의 무덤 — 늦게 도착한 응답을
        # '알 수 없는 메시지'가 아니라 '지연 도착'으로 명시적으로 폐기한다.
        self._stale_sequence_ids: deque[str] = deque(maxlen=8)
        self._read_task: asyncio.Task[None] | None = None
        #: RPi4가 보낸 마지막 정지 대기 보고(progress phase "hold"). 새 실행을 보내면 비운다.
        self.last_hold: dict | None = None
        #: RPi4가 보낸 마지막 잔여 전류 꼬리 보고(progress phase "power_tail"). 새 실행을 보내면 비운다.
        #: 기록용 측정값이다(판정 아님). 이력·CSV에는 아직 잇지 않았다(결과 저장 뒤에 도착한다).
        self.last_power_tail: dict | None = None
        self._progress_listeners: list[Callable[[dict], None]] = []
        #: RPi4의 비상정지 걸림(2026-10-05). True/False, 보고를 받은 적 없으면 None.
        #: ``alert kind=outlet_estop``·``estop_state``·``error reason=estop_latched``로 갱신한다.
        self.estop_latched: bool | None = None
        self.estop_detail: str | None = None
        self._estop_waiters: list[asyncio.Future[dict]] = []

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
        self,
        buttons: Sequence[str],
        sequence_id: str | None = None,
        targets: "Mapping[str, ButtonTarget] | None" = None,
        hold: "Mapping[str, object] | None" = None,
    ) -> ActResult:
        """Send one button sequence and await RPi4's result.

        ``targets``(선택): 버튼 → 갠트리 좌표(mm). 비어 있으면 메시지에
        ``targets`` 키를 넣지 않는다 — 종전 execute 줄과 바이트까지 같다.

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
            message: dict = {"type": "execute", "sequence_id": seq_id, "buttons": list(buttons)}
            if targets:
                message["targets"] = targets_payload(targets)
            if hold:
                # 정지 대기·보관 계획(선택). 옛 RPi4는 모르는 키를 무시한다.
                message["hold"] = dict(hold)
            self.last_hold = None
            self.last_power_tail = None
            await self._send(message)
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
        success = bool(doc.get("success", False))
        confirmed, detail, source = parse_operation(doc)
        return ActResult(
            sequence_id=doc.get("sequence_id", seq_id),
            success=success,
            retry=int(doc.get("retry", 0)),
            outcome=parse_result_outcome(doc, success),
            button_results=parse_button_results(doc, list(buttons), success),
            operation_confirmed=confirmed,
            operation_detail=detail,
            operation_source=source,
            execution_mode=parse_execution_mode(doc),
        )

    async def abort(self, scope: str | None = None) -> None:
        """Request RPi4 abort — best-effort, no reply is awaited (see protocol.md).

        ``scope="drive"``면 구동부만 멈추라는 뜻이다(정지 대기 중에도 정지 버튼을 누르지 않음).
        생략하면 종전 줄과 바이트까지 같다."""
        await self._send({"type": "abort"} if scope is None else {"type": "abort", "scope": scope})

    async def verify_pass(self, targets: "Sequence[Mapping[str, object]]",
                          sequence_id: str | None = None) -> dict:
        """확인 주행을 보내고 ``verify_result``를 기다린다. ``error``면 ActLinkError."""
        if self._pending is not None and not self._pending[1].done():
            raise ActLinkBusyError("another request is already awaiting a response")
        seq_id = sequence_id or str(uuid.uuid4())
        timeout = self._cfg.timeout_for(len(targets))
        future: asyncio.Future[dict] = asyncio.get_running_loop().create_future()
        self._pending = (seq_id, future)
        try:
            await self._send({"type": "verify_pass", "sequence_id": seq_id,
                              "targets": [dict(t) for t in targets]})
            doc = await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError as exc:
            self._stale_sequence_ids.append(seq_id)
            try:
                await self._send({"type": "abort", "scope": "drive"})
            except Exception:
                log.exception("abort send after verify timeout failed")
            raise ActLinkTimeoutError(f"no verify_result for {seq_id!r} within {timeout}s") from exc
        finally:
            if self._pending is not None and self._pending[0] == seq_id:
                self._pending = None
        if doc.get("type") == "error":
            raise ActLinkError(str(doc.get("detail") or doc.get("reason") or "unknown"))
        return doc

    def add_progress_listener(self, listener: Callable[[dict], None]) -> None:
        self._progress_listeners.append(listener)

    def remove_progress_listener(self, listener: Callable[[dict], None]) -> None:
        with contextlib.suppress(ValueError):
            self._progress_listeners.remove(listener)

    async def estop_ack(self, timeout_s: float = 10.0) -> dict:
        """비상정지 해제 확인을 보내고 RPi4의 ``estop_state``를 기다린다. 기한 안에 없으면 ActLinkTimeoutError.

        풀렸는지는 돌아온 ``latched``로 본다 — 버튼이 아직 눌려 있으면 RPi4가 풀지 않는다."""
        future: asyncio.Future[dict] = asyncio.get_running_loop().create_future()
        self._estop_waiters.append(future)
        try:
            await self._send({"type": "estop_ack"})
            return await asyncio.wait_for(future, timeout_s)
        except asyncio.TimeoutError as exc:
            raise ActLinkTimeoutError(f"no estop_state within {timeout_s}s") from exc
        finally:
            with contextlib.suppress(ValueError):
                self._estop_waiters.remove(future)

    def _note_estop(self, latched: bool, detail: str | None) -> None:
        self.estop_latched = latched
        self.estop_detail = detail if latched else None

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
            if self.tap is not None:
                self.tap.record("act_to_hub", None, raw)
            log.warning("ActClient: ignored unparseable line: %.120s", raw)
            return
        if not isinstance(doc, dict):
            if self.tap is not None:
                self.tap.record("act_to_hub", None, raw)
            return
        if self.tap is not None:
            self.tap.record("act_to_hub", doc)

        msg_type = doc.get("type")
        if msg_type == "estop_state":
            latched = doc.get("latched")
            if isinstance(latched, bool):
                detail = doc.get("detail")
                self._note_estop(latched, detail if isinstance(detail, str) else None)
            for waiter in list(self._estop_waiters):
                if not waiter.done():
                    waiter.set_result(doc)
            return
        if msg_type == "error" and doc.get("reason") == "estop_latched":
            detail = doc.get("detail")
            self._note_estop(True, detail if isinstance(detail, str) else self.estop_detail)
        if msg_type in ("result", "error", "verify_result"):
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

        if msg_type == "progress":
            # 진행 보고는 기록·관찰용이다. 대기 중인 execute()를 끝내지 않는다.
            if doc.get("phase") == "hold":
                self.last_hold = doc
            elif doc.get("phase") == "power_tail":
                self.last_power_tail = doc
            for listener in list(self._progress_listeners):
                try:
                    listener(doc)
                except Exception:  # noqa: BLE001
                    log.exception("ActClient: progress listener failed")
            if self._on_progress is not None:
                try:
                    self._on_progress(doc)
                except Exception:  # noqa: BLE001 - 관찰자 고장이 읽기 루프를 죽이지 않는다
                    log.exception("ActClient: on_progress callback failed")
            return

        event = _parse_alert(doc)
        if event is not None and event.kind == "outlet_estop" and event.raised:
            self._note_estop(True, self.estop_detail or "비상정지가 걸려 있어요")
        if event is not None and self._on_alert is not None:
            self._on_alert(event)
        # "ack" and unknown types: recorded by the tap only, otherwise ignored.

    # ── IO helper ────────────────────────────────────────────────────────────

    async def _send(self, doc: dict) -> None:
        payload = (json.dumps(doc, ensure_ascii=False) + "\n").encode("utf-8")
        log.debug("TX -> %s", payload.rstrip().decode())
        if self.tap is not None:
            self.tap.record("hub_to_act", doc)
        self._writer.write(payload)
        await self._writer.drain()


def targets_payload(targets: "Mapping[str, ButtonTarget]") -> dict[str, dict]:
    """ButtonTarget → docs/protocol.md의 ``targets`` JSON 모양."""
    out: dict[str, dict] = {}
    for name, target in targets.items():
        entry: dict = {"x_mm": target.x_mm, "y_mm": target.y_mm}
        if target.press_ms is not None:
            entry["press_ms"] = target.press_ms
        out[name] = entry
    return out
