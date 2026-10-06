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
  (nothing — self-initiated)      ←  appliance_done {appliance_id, event, state, inputs, source, ...}
                                      (세탁 끝: CT 전력 + 종료음 융합, 2026-10-06. 검증 뒤 ``on_appliance_done``,
                                       ``last_appliance_done``. 검증에 실패한 프레임은 버린다)
  hello (start() 때 한 번)        ←  act_info {done_watch, rehearsal, outlet, motion} + estop_state {announce:true}
                                      (2026-10-06 평가 C1·B3: RPi5가 다시 켜져도 걸림 상태를 다시 안다. 받기 전
                                       ``estop_latched``는 None = '확인 중'이고 실행을 거절한다)
  rehearsal {action, request_id}  ←  rehearsal_result {request_id, ok, ...}(가짜 콘센트·모의 모션 RPi4만)
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
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol

from .appliance_done import parse_appliance_done

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
        reader: asyncio.StreamReader | None,
        writer: _WriterLike | None,
        config: ActClientConfig | None = None,
        on_alert: Callable[[AlertEvent], None] | None = None,
        tap: "LinkFrameTap | None" = None,
        on_progress: Callable[[dict], None] | None = None,
        on_appliance_done: Callable[[dict], None] | None = None,
        on_act_info: Callable[[dict], None] | None = None,
        hello: bool = False,
        connector: "Callable[[], Awaitable[tuple[asyncio.StreamReader, _WriterLike]]] | None" = None,
        reconnect_backoff: tuple[float, float] | None = None,
    ) -> None:
        """``hello``: start() 때 ``hello``를 보낸다(2026-10-06 평가 C1). 운영 경로(UART 공장·시뮬레이터)는 True로
        만든다 — 기본 False는 줄 단위로 RPi4를 흉내 내는 시험이 첫 줄을 execute로 기대하기 때문이다.

        ``connector``(2026-10-06 교차 리뷰): 링크가 끊기면(EOF·읽기 오류) 이것으로 새 (reader, writer)를 연다.
        ``reconnect_backoff=(처음, 상한)`` 초 간격으로 두 배씩 늘리며 다시 시도하고, 이으면 hello부터 보낸다.
        None이면 종전처럼 읽기 루프가 끝난다(끊김 표시·대기 요청 실패는 똑같이 한다).

        ``reader``·``writer``가 None이면(첫 연결 전, 2026-10-06 인계 §6) 링크 끊김으로 시작하고 start()가 배경에서
        ``connector``로 첫 연결을 시도한다 — 첫 시도는 바로, 실패하면 재연결과 같은 간격으로. 잇기 전에는
        보내기를 ``ActLinkError``로 거절하고 걸림 상태는 None(모름)이다."""
        if (reader is None) != (writer is None):
            raise ValueError("reader and writer must both be given or both be None")
        if reader is None and connector is None:
            raise ValueError("connector is required when starting without a stream")
        self._reader = reader
        self._writer = writer
        self._cfg = config or ActClientConfig()
        self._on_alert = on_alert
        #: 보내고 받은 모든 줄의 기록(rpi/services/link_tap.py). None이면 기록 안 함.
        self.tap = tap
        self._on_progress = on_progress
        self._on_appliance_done = on_appliance_done
        self._on_act_info = on_act_info
        self._hello_on_start = hello
        #: RPi4가 알린 구성(``act_info``). 받기 전에는 빈 dict.
        self.act_info: dict = {}
        #: 비상정지가 새로 걸린 횟수(평가 B5) — 루틴이 '실행 중 한 번이라도 걸렸나'를 본다.
        self.estop_trips = 0
        self._rehearsal_waiters: dict[str, asyncio.Future[dict]] = {}
        #: RPi4가 보낸 마지막 가전 완료 기록(검증한 것만). 2026-10-06.
        self.last_appliance_done: dict | None = None
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
        self._connector = connector
        self._backoff = reconnect_backoff or self.RECONNECT_BACKOFF
        #: 링크가 살아 있나(끊긴 동안·첫 연결 전 False — 보내기는 ActLinkError로 거절한다).
        self.link_up = reader is not None
        #: 끊긴 횟수·마지막 끊김 이유(진단용).
        self.link_drops = 0
        self.link_down_reason: str | None = None if reader is not None else self.NOT_CONNECTED_REASON
        #: 한 번이라도 이어졌나(첫 연결 전 False).
        self.ever_connected = reader is not None

    #: 재연결 간격(처음, 상한) 초. 끊긴 뒤 처음 간격만큼 쉬고 시도하며, 실패마다 두 배(상한까지).
    RECONNECT_BACKOFF: tuple[float, float] = (0.5, 5.0)
    #: 첫 연결 전 ``link_down_reason``.
    NOT_CONNECTED_REASON = "not connected yet"

    # ── Public API ───────────────────────────────────────────────────────────

    async def start(self) -> None:
        """Start the background read loop. Call once before execute()/abort()."""
        self._read_task = asyncio.create_task(self._read_loop())
        # 첫 연결 전이면 hello는 연결이 이어진 뒤 _reconnect가 보낸다.
        if self._hello_on_start and self.link_up:
            await self.hello()

    async def hello(self) -> None:
        """RPi4에 (다시) 연결했다고 알린다 — 답은 ``act_info``와 ``estop_state``(평가 C1)."""
        try:
            await self._send({"type": "hello"})
        except ActLinkError as exc:  # 끊긴 동안 — 재연결이 hello를 다시 보낸다
            log.info("ActClient: hello not sent (%s)", exc)
        except Exception:  # noqa: BLE001 - 보내지 못하면 걸림 상태는 None(확인 중)으로 남는다
            log.exception("ActClient: hello send failed")

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

    async def rehearsal(self, action: str, timeout_s: float = 5.0, **fields: object) -> dict:
        """리허설 주입을 RPi4로 보내고 ``rehearsal_result``를 기다린다(가짜 콘센트·모의 모션 RPi4만 받는다)."""
        request_id = uuid.uuid4().hex[:12]
        future: asyncio.Future[dict] = asyncio.get_running_loop().create_future()
        self._rehearsal_waiters[request_id] = future
        try:
            await self._send({"type": "rehearsal", "action": action, "request_id": request_id, **fields})
            return await asyncio.wait_for(future, timeout_s)
        except asyncio.TimeoutError as exc:
            raise ActLinkTimeoutError(f"no rehearsal_result within {timeout_s}s") from exc
        finally:
            self._rehearsal_waiters.pop(request_id, None)

    def _note_estop(self, latched: bool, detail: str | None) -> None:
        if latched and self.estop_latched is not True:
            self.estop_trips += 1
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
        """줄을 읽는다. 끊기면(EOF·읽기 오류) 끊김으로 표시하고, ``connector``가 있으면 다시 잇는다."""
        if self._reader is None:  # 첫 연결 전 — 바로 한 번 시도하고, 실패하면 같은 간격으로 다시
            await self._reconnect(initial=True)
        while True:
            try:
                while True:
                    raw_bytes = await self._reader.readuntil(b"\n")
                    raw = raw_bytes.decode("utf-8", errors="replace").strip()
                    if raw:
                        self._handle_line(raw)
            except asyncio.IncompleteReadError:
                reason = "EOF"
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - serial.SerialException(socket disconnected) 등
                reason = f"{type(exc).__name__}: {exc}"
            self._mark_link_down(reason)
            if self._connector is None:
                return
            await self._reconnect()

    def _mark_link_down(self, reason: str) -> None:
        """끊김: 기다리던 요청을 모두 바로 실패시키고, 걸림 상태를 '모름'으로 돌린다(풀림으로 가정하지 않는다)."""
        log.warning("ActClient: link down (%s)", reason)
        self.link_up = False
        self.link_drops += 1
        self.link_down_reason = reason
        # 다시 이은 뒤 RPi4의 답(estop_state)으로만 다시 안다 — 그때까지 서비스가 '확인하는 중'으로 거절한다.
        self.estop_latched = None
        self.estop_detail = None
        error = ActLinkError(f"RPi4 연결이 끊겼어요 ({reason})")
        pending = self._pending
        if pending is not None and not pending[1].done():
            # 짧은 단선이었다면 RPi4가 늦게 결과를 보낼 수 있다 — 다음 요청의 결과로 오인하지 않게.
            self._stale_sequence_ids.append(pending[0])
            pending[1].set_exception(error)
        for waiter in [*self._estop_waiters, *self._rehearsal_waiters.values()]:
            if not waiter.done():
                waiter.set_exception(error)
        close = getattr(self._writer, "close", None)
        if callable(close):
            with contextlib.suppress(Exception):
                close()

    async def _reconnect(self, initial: bool = False) -> None:
        """``initial``(첫 연결): 첫 시도는 쉬지 않고 바로 한다. 그 뒤 간격은 재연결과 같다."""
        delay, ceiling = self._backoff
        wait = 0.0 if initial else delay
        while True:
            await asyncio.sleep(wait)
            try:
                reader, writer = await self._connector()  # type: ignore[misc]
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - 상대가 아직 다시 뜨는 중
                if initial and wait == 0.0:
                    wait = delay
                else:
                    wait = delay = min(delay * 2, ceiling)
                log.info("ActClient: %s failed (%s) — retry in %.1fs",
                         "first connect" if not self.ever_connected else "reconnect", exc, wait)
                continue
            self._reader, self._writer = reader, writer
            self.link_up = True
            self.link_down_reason = None
            log.info("ActClient: link %s — sending hello",
                     "established" if not self.ever_connected else "re-established")
            self.ever_connected = True
            # 걸림 상태·구성을 다시 받는다. 답(estop_state)이 올 때까지 estop_latched는 None(확인 중).
            await self.hello()
            return

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
            if doc.get("announce") is True:
                return  # 연결 알림 — 해제 확인의 답이 아니다
            for waiter in list(self._estop_waiters):
                if not waiter.done():
                    waiter.set_result(doc)
            return
        if msg_type == "act_info":
            self.act_info = {k: v for k, v in doc.items() if k != "type"}
            if self._on_act_info is not None:
                try:
                    self._on_act_info(dict(self.act_info))
                except Exception:  # noqa: BLE001 - 듣는 쪽 고장이 읽기 루프를 죽이지 않는다
                    log.exception("ActClient: on_act_info callback failed")
            return
        if msg_type == "rehearsal_result":
            waiter = self._rehearsal_waiters.get(doc.get("request_id"))
            if waiter is not None and not waiter.done():
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

        if msg_type == "appliance_done":
            record = parse_appliance_done(doc)
            if record is None:
                log.warning("ActClient: invalid appliance_done ignored: %.160s", raw)
                return
            self.last_appliance_done = record
            if self._on_appliance_done is not None:
                try:
                    self._on_appliance_done(record)
                except Exception:  # noqa: BLE001 - 듣는 쪽 고장이 읽기 루프를 죽이지 않는다
                    log.exception("ActClient: on_appliance_done callback failed")
            return

        event = _parse_alert(doc)
        if event is not None and event.kind == "outlet_estop" and event.raised:
            self._note_estop(True, self.estop_detail or "비상정지가 걸려 있어요")
        if event is not None and self._on_alert is not None:
            self._on_alert(event)
        # "ack" and unknown types: recorded by the tap only, otherwise ignored.

    # ── IO helper ────────────────────────────────────────────────────────────

    async def _send(self, doc: dict) -> None:
        if not self.link_up:
            raise ActLinkError(f"RPi4 연결이 끊겨 다시 잇는 중이에요 ({self.link_down_reason})")
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
