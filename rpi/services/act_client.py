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
  abort {scope?, stop_id}         ←  stop_report {stop_id, target, stop_level, ack_ms, stop_detail?}
  execute {…, heartbeat_s?} + heartbeat {sequence_id}
                                      (실행 중 생존 신호, 2026-10-16 G5 — act_info.heartbeat_protocol을 알린 RPi4에만. 결과까지
                                       heartbeat_s 주기로, 링크 이벤트 루프의 작업. 답 없음. RPi4가 침묵에 스스로 멈추면 결과
                                       abort_reason "motion_link_lost", 다시 이은 뒤 act_info.last_link_stop → ``last_link_stop``)
  execute·abort {…, run_ref?}         (실행 표지, 2026-10-15 G2 — 쉬는 중 RPi4가 받은 abort를 같은 표지의 execute에 묶는다.
                                       그 execute는 누르지 않고 result {success:false, outcome:"stopped", button_results:[]})
                                      (정지 보고 규약 1, 2026-10-13 — act_info.stop_report_protocol을 알린 RPi4만 답한다.
                                       ``abort_with_report()``. 옛 RPi4면 기다리지 않고 ``sent``)
  verify_pass {sequence_id,       ←  verify_result {sequence_id, ok, targets}
               targets}               (확인 주행, 2026-09-30 — progress phase "verify"가 먼저 온다)
  verify_pass {…, heartbeat_s?} + heartbeat {sequence_id}
                                      (10/19 — 실행과 같은 생존 신호. 끊기면 RPi4가 스스로 멈추고
                                       verify_result {ok:false, abort_reason:"motion_link_lost"})
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
  clock_probe {probe}             ←  clock_ref {probe, clock_id, t_monotonic_ns}
                                      (사건 신선도 기준점, 3차 평가 M1 2026-10-14 — act_info.clock_protocol을 알린 RPi4에만,
                                       act_info를 받을 때마다 한 번. rpi/services/event_clock.py)
                                      (2026-10-06 평가 C1·B3: RPi5가 다시 켜져도 걸림 상태를 다시 안다. 받기 전
                                       ``estop_latched``는 None = '확인 중'이고 실행을 거절한다)
  rehearsal {action, request_id}  ←  rehearsal_result {request_id, ok, ...}(가짜 콘센트·모의 모션 RPi4만)
  dev_motion {request_id, op, …}  ←  dev_motion_result {request_id, op, ok, reason?, detail?, moved?, homed?, x_mm?, y_mm?}
                                      (개발자 조작 규약 1, 2026-10-10 — act_info.dev_motion_protocol을 알린 RPi4에만 보낸다.
                                       ``dev_motion()``. 요청 하나에 답 하나, 재전송 없음)
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
import re
import uuid
from collections import deque
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Protocol

from rpi.controller.models import PRE_PRESS_REFUSALS, ExecuteRefusedBeforePress

from . import link_auth
from .appliance_done import parse_appliance_done
from .link_heartbeat import DEFAULT_PERIOD_S as DEFAULT_HEARTBEAT_PERIOD_S
from .link_heartbeat import parse_link_stop, supports_heartbeat
from .link_heartbeat import period_from_env as heartbeat_period_from_env

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


class ActExecuteRefused(ActLinkError, ExecuteRefusedBeforePress):
    """RPi4(또는 보내기 전 RPi5)가 **누르기 전에** 분명히 거절했다(2026-10-19) — 아무것도 누르지 않았다.

    ``ActLinkError``의 하위라 종전처럼 잡는 호출자는 그대로 동작한다. `ActClientController`는 이것을 예외 대신
    '보내지 않음·실패' 결과(`refused_before_press`)로 바꿔, 서비스가 '연결이 끊겨 눌렸는지 확인하지 못했어요'로 적지 않게 한다."""

    def __init__(self, reason: str, detail: str | None, message: str) -> None:
        ExecuteRefusedBeforePress.__init__(self, reason, detail, message)


@dataclass(frozen=True)
class ActClientConfig:
    # 시퀀스 길이와 무관한 기본 여유(연결·해석·홈 복귀 등)
    response_timeout_seconds: float = 30.0
    # 버튼 1개당 추가 여유 — 실기기에서 버튼 하나는 이동+누름+검증+재시도
    # (최대 3회)로 수 초가 걸린다. 고정 30s는 6버튼 이상 시퀀스가 정상
    # 진행 중인 실행을 timeout으로 오판하지 않도록 한다.
    #
    # 기본 6초는 실측이 아닌 설계 추정치다. 실기기에서 (이동 최악값 + 누름 +
    # 센서 판정 창 + 재시도 3회)의 p95를 재서 SIMPLELAY_UART_PER_BUTTON_TIMEOUT
    # 으로 조정한다 — 코드 수정 없이 현장에서 맞출 수 있어야 한다.
    per_button_timeout_seconds: float = 6.0
    # 실행 중 생존 신호 주기(2026-10-16 G5) — RPi4가 act_info.heartbeat_protocol을 알렸을 때만 보낸다.
    # 기본 1 s는 추측값(측정 필요). SIMPLELAY_LINK_HEARTBEAT_S(0.2~5).
    heartbeat_seconds: float = DEFAULT_HEARTBEAT_PERIOD_S

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
            heartbeat_seconds=heartbeat_period_from_env(),
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
    #: 모션 장치 쪽 이유로 재시도 없이 멈춘 원인(2026-10-14, 예: ``motion_alarm: stall``). 없거나 형식이 틀리면 None.
    abort_reason: str | None = None


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


_ABORT_REASON = re.compile(r"motion_[a-z_]{1,40}(: [A-Za-z0-9_.\-]{1,40})?")


def parse_abort_reason(doc: dict) -> str | None:
    """화면 판정용 원인: 알려진 미확인 표지 또는 ``motion_…``만 받는다."""
    reason = doc.get("abort_reason")
    if reason is None:
        return None
    if isinstance(reason, str) and (reason == "press_unconfirmed" or _ABORT_REASON.fullmatch(reason)):
        return reason
    log.warning("ActClient: abort_reason %.80r ignored", reason)
    return None


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
        link_key: "str | bytes | None" = None,
    ) -> None:
        """``hello``: start() 때 ``hello``를 보낸다(2026-10-06 평가 C1). 운영 경로(UART 공장·시뮬레이터)는 True로
        만든다 — 기본 False는 줄 단위로 RPi4를 흉내 내는 시험이 첫 줄을 execute로 기대하기 때문이다.

        ``connector``(2026-10-06 교차 리뷰): 링크가 끊기면(EOF·읽기 오류) 이것으로 새 (reader, writer)를 연다.
        ``reconnect_backoff=(처음, 상한)`` 초 간격으로 두 배씩 늘리며 다시 시도하고, 이으면 hello부터 보낸다.
        None이면 종전처럼 읽기 루프가 끝난다(끊김 표시·대기 요청 실패는 똑같이 한다).

        ``reader``·``writer``가 None이면(첫 연결 전, 2026-10-06 인계 §6) 링크 끊김으로 시작하고 start()가 배경에서
        ``connector``로 첫 연결을 시도한다 — 첫 시도는 바로, 실패하면 재연결과 같은 간격으로. 잇기 전에는
        보내기를 ``ActLinkError``로 거절하고 걸림 상태는 None(모름)이다.

        ``link_key``(2026-10-12, 무선 링크 인증): 짝 키(``SIMPLELAY_LINK_KEY``, 16자 이상 — 짧으면 `LinkKeyError`).
        주면 hello에 새 ``cn``을 싣고 K로 서명하며, RPi4의 서명된 hello 답(``cn``·``sn``)을 받기 전까지 링크를
        내려 둔다(``link_up=False``). 그 뒤 모든 프레임은 세션 키로 서명하고 ``seq``를 붙인다(link_auth.py).
        서명 없는·MAC이 틀린·``seq``를 되돌린 프레임은 버린다. None이면 종전 그대로(봉투 없음)."""
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
        #: 개발자 조작 답을 기다리는 요청(request_id → future). 2026-10-10.
        self._dev_waiters: dict[str, asyncio.Future[dict]] = {}
        #: 정지 보고를 기다리는 abort(stop_id → future). 2026-10-13.
        self._stop_waiters: dict[str, asyncio.Future[dict]] = {}
        #: RPi4가 보낸 마지막 정지 보고(``stop_report``). 없으면 None.
        self.last_stop_report: dict | None = None
        #: RPi4가 보낸 마지막 가전 완료 기록(검증한 것만). 2026-10-06.
        self.last_appliance_done: dict | None = None
        #: RPi4가 링크를 잃고 스스로 멈춘 마지막 실행(``act_info.last_link_stop``, 2026-10-16 G5). 끊겨도 남는다.
        self.last_link_stop: dict | None = None
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
        self._link_key = None if link_key is None else link_auth.validate_key(link_key)
        #: 인증된 세션(키가 있을 때만). 보낸 hello의 ``cn``(답 대기 중)·답 기다림 task.
        self._session: link_auth.LinkSession | None = None
        self._hello_cn: str | None = None
        self._auth_task: asyncio.Task[None] | None = None
        #: 사건 신선도 기준점을 주기적으로 다시 잡는 작업(4차 평가 M-N1). 끊기면 멈춘다.
        self._clock_task: asyncio.Task[None] | None = None
        self._auth_drops = link_auth.DropLog()
        #: 줄이 이어져 있나(인증과 무관). 키가 없으면 ``link_up``과 같다.
        self._transport_up = reader is not None
        #: 링크가 살아 있나(끊긴 동안·첫 연결 전·키가 있는데 인증 전 False — 보내기는 ActLinkError로 거절한다).
        self.link_up = reader is not None and self._link_key is None
        #: 끊긴 횟수·마지막 끊김 이유(진단용).
        self.link_drops = 0
        self.link_down_reason: str | None = (
            self.NOT_CONNECTED_REASON if reader is None
            else self.AUTH_PENDING_REASON if self._link_key is not None else None)
        #: 한 번이라도 이어졌나(첫 연결 전 False).
        self.ever_connected = reader is not None

    #: 재연결 간격(처음, 상한) 초. 끊긴 뒤 처음 간격만큼 쉬고 시도하며, 실패마다 두 배(상한까지).
    RECONNECT_BACKOFF: tuple[float, float] = (0.5, 5.0)
    #: 첫 연결 전 ``link_down_reason``.
    NOT_CONNECTED_REASON = "not connected yet"
    #: 키가 있을 때 hello 답(인증) 전 ``link_down_reason``.
    AUTH_PENDING_REASON = "RPi4 인증 확인 중"
    #: 인증 실패(답이 없거나 서명이 맞지 않음). /health·/dev/state에 그대로 보인다.
    AUTH_FAILED_REASON = "RPi4 인증 실패 — 두 보드의 SIMPLELAY_LINK_KEY가 같은지 확인"
    #: hello를 보낸 뒤 서명된 답을 이만큼 기다리고, 없으면 인증 실패로 보고 늘어나는 간격으로 다시 보낸다.
    AUTH_REPLY_TIMEOUT_S = 3.0

    # Public API

    async def start(self) -> None:
        """Start the background read loop. Call once before execute()/abort()."""
        self._read_task = asyncio.create_task(self._read_loop())
        # 첫 연결 전이면 hello는 연결이 이어진 뒤 _reconnect가 보낸다.
        if self._hello_on_start and self._transport_up:
            await self.hello()

    async def hello(self) -> None:
        """RPi4에 (다시) 연결했다고 알린다 — 답은 ``act_info``와 ``estop_state``(평가 C1).

        키가 있으면 새 세션을 연다: 지금 세션을 버리고(답이 올 때까지 링크 내려감) 새 ``cn``으로 서명한 hello를
        보낸다. RPi4도 올바른 hello마다 새 세션을 연다."""
        try:
            if self._link_key is None:
                await self._send({"type": "hello"})
            else:
                await self._send_hello()
        except ActLinkError as exc:  # 끊긴 동안 — 재연결이 hello를 다시 보낸다
            log.info("ActClient: hello not sent (%s)", exc)
        except Exception:  # noqa: BLE001 - 보내지 못하면 걸림 상태는 None(확인 중)으로 남는다
            log.exception("ActClient: hello send failed")

    async def stop(self) -> None:
        """Cancel the background read loop. Safe to call more than once."""
        self._cancel_auth_task()
        self._cancel_clock_task()
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
        *,
        appliance_id: str | None = None,
        run_ref: str | None = None,
        button_behaviors: Mapping[str, str] | None = None,
    ) -> ActResult:
        """Send one button sequence and await RPi4's result.

        ``run_ref``(선택, 2026-10-15 G2): RPi5가 정한 이번 실행의 표지 — 같은 실행의 abort에도 싣는다. RPi4는 실행 시작
        전에 같은 표지의 abort를 받았으면 이 시퀀스를 누르지 않고 정지 결과로 답한다. 없으면 키를 넣지 않는다(종전 줄).

        ``appliance_id``: 실행 대상 가전 — **필수**(2026-10-07, 평가 H3, execute 규약 2). RPi4는 이 대상의
        CT 채널로 L3·정지 확인을 고르고, 대상 없는 프레임은 ``target_required``로 거절한다. 없으면
        보내지 않고 `ActLinkError`. 결과 프레임의 ``appliance_id``가 다르면 `ActLinkError`.

        ``targets``(선택): 버튼 → 갠트리 좌표(mm). 비어 있으면 메시지에
        ``targets`` 키를 넣지 않는다 — 종전 execute 줄과 바이트까지 같다.

        Raises ActLinkBusyError if a previous execute() hasn't resolved yet,
        ActLinkTimeoutError if RPi4 never responds, ActLinkError if RPi4
        reports an ``error`` message for this sequence.
        """
        if not isinstance(appliance_id, str) or not appliance_id.strip():
            raise ActLinkError("execute target (appliance_id) is required — not sent to RPi4")
        if self._pending is not None and not self._pending[1].done():
            raise ActLinkBusyError("an execute() call is already awaiting a response")

        if self.act_info or self._hello_on_start:
            protocol = self.act_info.get("execute_protocol")
            if type(protocol) is not int or protocol < 2:
                # 보내지 않았다 — 누르기 전 거절(2026-10-19). 메시지는 종전 그대로.
                raise ActExecuteRefused(
                    "execute_protocol_v2_required", None,
                    "execute_protocol_v2_required: target binding requires execute_protocol >= 2")
        seq_id = sequence_id or str(uuid.uuid4())
        timeout = self._cfg.timeout_for(len(buttons))
        loop = asyncio.get_running_loop()
        future: asyncio.Future[dict] = loop.create_future()
        self._pending = (seq_id, future)
        heartbeat_task: asyncio.Task[None] | None = None

        # _send()도 반드시 이 try 안에 있어야 한다. 밖에 두면 UART 단선으로
        # drain()이 실패했을 때 _pending이 영원히 남아(future는 끝내 완료되지
        # 않음) 이후 모든 실행이 ActLinkBusyError로 거부됐다 — 케이블 접촉
        # 불량 한 번이 재부팅 전까지 실행 경로를 통째로 막는 구조였다.
        try:
            message: dict = {"type": "execute", "sequence_id": seq_id, "buttons": list(buttons),
                             "appliance_id": appliance_id}
            if button_behaviors is not None:
                message["button_behaviors"] = dict(button_behaviors)
            if targets:
                message["targets"] = targets_payload(targets)
            if hold:
                # 정지 대기·보관 계획(선택). 옛 RPi4는 모르는 키를 무시한다.
                message["hold"] = dict(hold)
            if run_ref is not None:
                # 실행 표지(선택). 옛 RPi4는 모르는 키를 무시한다.
                message["run_ref"] = run_ref
            period = self._cfg.heartbeat_seconds
            beat = supports_heartbeat(self.act_info)
            if beat:
                # 실행 중 생존 신호(2026-10-16 G5) — 알린 RPi4에만. 옛 RPi4에는 종전 줄 그대로.
                message["heartbeat_s"] = period
            self.last_hold = None
            self.last_power_tail = None
            await self._send(message)
            if beat:
                heartbeat_task = asyncio.create_task(self._send_heartbeats(seq_id, future, period))
            doc = await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError as exc:
            # 이 sequence의 응답이 늦게라도 오면 폐기 대상으로 기록
            self._stale_sequence_ids.append(seq_id)
            # RPi5는 지금부터 이 실행을 실패로 보고한다 — RPi4가 아직 버튼을
            # 누르고 있을 수 있으므로 중단도 함께 요청한다(불일치 방지).
            # 전송 실패는 로그만: timeout 예외 경로를 덮어쓰면 안 된다.
            # 2026-10-19: 구동부만(scope=drive) — 맨 abort는 가전 범위라, RPi4가 이미 실행을 끝내고 정지 버튼 위에서
            # 기다리는 중이면 가전 정지 버튼을 눌렀다. 이 실행의 표지(run_ref)를 실어, 아직 execute를 못 받은 RPi4가 뒤이어
            # 온 execute를 누르지 않게 한다(G2와 같은 이중 방어). 옛 RPi4도 scope=drive를 안다(9/30 정지 대기부터).
            abort: dict = {"type": "abort", "scope": "drive"}
            if run_ref is not None:
                abort["run_ref"] = run_ref
            try:
                await self._send(abort)
            except Exception:
                log.exception("abort send after timeout failed")
            raise ActLinkTimeoutError(
                f"no response for sequence_id={seq_id!r} within {timeout}s"
            ) from exc
        finally:
            if heartbeat_task is not None:
                heartbeat_task.cancel()
            # 내 요청일 때만 비운다 — 이 execute()가 늦게 정리되는 사이
            # 다음 요청이 _pending을 차지했다면 그것을 지워선 안 된다.
            if self._pending is not None and self._pending[0] == seq_id:
                self._pending = None

        if doc.get("type") == "error":
            reason = doc.get("reason", "unknown")
            message = f"RPi4 reported error for sequence_id={seq_id!r}: {reason}"
            if reason in PRE_PRESS_REFUSALS:
                # RPi4가 실행을 시작하기 전에 거절했다 — 아무것도 누르지 않았다(2026-10-19).
                detail = doc.get("detail")
                raise ActExecuteRefused(reason, detail if isinstance(detail, str) else None, message)
            raise ActLinkError(message)
        reported = doc.get("appliance_id")
        if reported is not None and reported != appliance_id:
            # 다른 가전의 결과(L3 확인 포함)를 이 실행의 결과로 쓰지 않는다.
            raise ActLinkError(
                f"RPi4 result for sequence_id={seq_id!r} is for {reported!r}, not {appliance_id!r}"
            )
        success = bool(doc.get("success", False))
        confirmed, detail, source = parse_operation(doc)
        if reported is None and confirmed is not None:
            # 옛 RPi4(결과에 대상 없음)의 L3는 어느 가전 채널로 본 것인지 모른다 — 확인으로 쓰지 않고 '모름'으로
            # 낮춘다. 전자레인지 CT 확인이 세탁기를 확인해서는 안 된다.
            log.warning("ActClient: result %r has no appliance_id (old RPi4) — operation_confirmed %r "
                        "treated as unknown", seq_id, confirmed)
            confirmed = None
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
            abort_reason=None if success else parse_abort_reason(doc),
        )

    async def _send_heartbeats(self, seq_id: str, future: "asyncio.Future[dict]", period: float) -> None:
        """이 실행의 결과가 올 때까지 ``heartbeat``를 ``period``마다 보낸다(2026-10-16 G5).

        링크 이벤트 루프의 작업이다 — 서비스 스레드·공용 스레드 풀을 거치지 않고, 정지(abort)·정지 보고 대기와 따로 돈다.
        못 보내면(링크 끊김) 그만둔다 — RPi4는 침묵으로 알아채고 스스로 멈춘다."""
        while not future.done():
            await asyncio.sleep(period)
            if future.done():
                return
            try:
                await self._send({"type": "heartbeat", "sequence_id": seq_id})
            except asyncio.CancelledError:
                raise
            except Exception as exc:  # noqa: BLE001 - 끊김은 읽기 루프·기한이 처리한다
                log.info("ActClient: heartbeat not sent (%s)", exc)
                return

    async def abort(self, scope: str | None = None, stop_id: str | None = None,
                    run_ref: str | None = None) -> None:
        """Request RPi4 abort — best-effort, no reply is awaited (see protocol.md).

        ``scope="drive"``면 구동부만 멈추라는 뜻이다(정지 대기 중에도 정지 버튼을 누르지 않음).
        ``stop_id``를 주면 RPi4가 ``stop_report``로 확인 단계를 알린다(`abort_with_report`).
        ``run_ref``(2026-10-15 G2)를 주면 RPi4가 쉬는 중일 때 그 실행의 execute를 누르지 않게 기억한다.
        모두 생략하면 종전 줄과 바이트까지 같다."""
        doc: dict = {"type": "abort"}
        if scope is not None:
            doc["scope"] = scope
        if stop_id is not None:
            doc["stop_id"] = stop_id
        if run_ref is not None:
            doc["run_ref"] = run_ref
        await self._send(doc)

    #: 정지 보고를 기다리는 기본 기한(초) — RPi4의 MCU 응답 기한(0.3 s)+멈춤 확인(status 두 번)보다 넉넉하게.
    #: 호스트 박자, 측정 필요.
    STOP_REPORT_TIMEOUT_S = 1.5

    async def abort_with_report(self, scope: str | None = None, timeout_s: float | None = None,
                                run_ref: str | None = None) -> dict:
        """정지를 **먼저 보내고**, RPi4의 ``stop_report``를 기다려 ``{"stop_level", "ack_ms", "target", …}``로 돌려준다.

        RPi4가 정지 보고 규약(``act_info.stop_report_protocol``)을 알리지 않았으면(옛 판·구성 받기 전) 기다리지 않고
        ``sent``다 — 보낸 것까지만 안다. 기한 안에 보고가 없어도 ``sent``. 보내지 못하면 `ActLinkError`."""
        stop_id = "s" + uuid.uuid4().hex[:15]
        protocol = (self.act_info or {}).get("stop_report_protocol")
        supported = type(protocol) is int and protocol >= 1
        future: asyncio.Future[dict] | None = None
        if supported:
            future = asyncio.get_running_loop().create_future()
            self._stop_waiters[stop_id] = future
        try:
            await self.abort(scope, stop_id=stop_id, run_ref=run_ref)
            if future is None:
                return {"stop_id": stop_id, "stop_level": "sent", "ack_ms": None, "target": None,
                        "stop_detail": "RPi4가 정지 확인 단계를 알리지 않는 판이에요"}
            try:
                doc = await asyncio.wait_for(future, self.STOP_REPORT_TIMEOUT_S if timeout_s is None else timeout_s)
            except asyncio.TimeoutError:
                return {"stop_id": stop_id, "stop_level": "sent", "ack_ms": None, "target": None,
                        "stop_detail": "RPi4의 정지 확인 보고가 기한 안에 오지 않았어요"}
        finally:
            self._stop_waiters.pop(stop_id, None)
        return _read_stop_report(doc)

    async def verify_pass(self, targets: "Sequence[Mapping[str, object]]",
                          sequence_id: str | None = None) -> dict:
        """확인 주행을 보내고 ``verify_result``를 기다린다. ``error``면 ActLinkError."""
        if self._pending is not None and not self._pending[1].done():
            raise ActLinkBusyError("another request is already awaiting a response")
        seq_id = sequence_id or str(uuid.uuid4())
        timeout = self._cfg.timeout_for(len(targets))
        future: asyncio.Future[dict] = asyncio.get_running_loop().create_future()
        self._pending = (seq_id, future)
        heartbeat_task: asyncio.Task[None] | None = None
        try:
            message: dict = {"type": "verify_pass", "sequence_id": seq_id, "targets": [dict(t) for t in targets]}
            # 확인 주행도 실행과 같은 생존 신호(10/19) — 알린 RPi4에만, 이 주행 번호로. 옛 RPi4에는 종전 줄 그대로.
            period = self._cfg.heartbeat_seconds
            beat = supports_heartbeat(self.act_info)
            if beat:
                message["heartbeat_s"] = period
            await self._send(message)
            if beat:
                heartbeat_task = asyncio.create_task(self._send_heartbeats(seq_id, future, period))
            doc = await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError as exc:
            self._stale_sequence_ids.append(seq_id)
            try:
                await self._send({"type": "abort", "scope": "drive"})
            except Exception:
                log.exception("abort send after verify timeout failed")
            raise ActLinkTimeoutError(f"no verify_result for {seq_id!r} within {timeout}s") from exc
        finally:
            if heartbeat_task is not None:
                heartbeat_task.cancel()
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

    async def dev_motion(self, op: str, timeout_s: float, **fields: object) -> dict:
        """개발자 조작 한 번을 보내고 ``dev_motion_result``를 기다린다(2026-10-10, 개발자 조작 규약 1).

        재전송하지 않는다 — 기한 안에 답이 없으면 `ActLinkTimeoutError`(호출자가 정지로 정리한다). 링크가 끊기면
        `ActLinkError`. 거절(``ok:false``)은 예외가 아니라 답 그대로 돌려준다."""
        request_id = "d" + uuid.uuid4().hex[:15]
        future: asyncio.Future[dict] = asyncio.get_running_loop().create_future()
        self._dev_waiters[request_id] = future
        try:
            await self._send({"type": "dev_motion", "request_id": request_id, "op": op, **fields})
            return await asyncio.wait_for(future, timeout_s)
        except asyncio.TimeoutError as exc:
            raise ActLinkTimeoutError(f"no dev_motion_result for {op!r} within {timeout_s}s") from exc
        finally:
            self._dev_waiters.pop(request_id, None)

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

    # Background read loop

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
            if self._transport_up:
                self._mark_link_down(reason)
            if self._connector is None:
                return
            await self._reconnect()

    @staticmethod
    def _event_clock():
        from .event_clock import get_event_clock  # noqa: PLC0415

        return get_event_clock()

    def _request_clock_ref(self) -> None:
        """사건 신선도 기준점(3차 평가 M1): ``act_info.clock_protocol`` ≥ 1인 RPi4에 탐침을 보낸다. 옛 RPi4면 보내지 않는다 —
        그러면 그 링크의 사건은 신선도 근거가 없어 자동 실행이 보류된다."""
        protocol = self.act_info.get("clock_protocol")
        self._cancel_clock_task()
        if not isinstance(protocol, int) or isinstance(protocol, bool) or protocol < 1:
            return
        from .event_clock import refresh_interval_s  # noqa: PLC0415

        interval = refresh_interval_s()

        async def send() -> None:
            # 4차 평가 M-N1: 기준점은 유효 기간이 있다 — 연결이 유지되는 동안 주기적으로 다시 탐침한다(끊기면 멈춘다).
            while True:
                try:
                    await self._send({"type": "clock_probe", "probe": self._event_clock().new_probe()})
                except asyncio.CancelledError:
                    raise
                except Exception as exc:  # noqa: BLE001 - 못 보내면 기준점이 없다(보류) — 읽기 루프는 살린다
                    log.info("ActClient: clock_probe not sent (%s)", exc)
                    return
                await asyncio.sleep(interval)

        try:
            self._clock_task = asyncio.get_running_loop().create_task(send())
        except RuntimeError:  # 루프 밖(시험 대역) — 기준점 없음
            log.info("ActClient: no running loop for clock_probe")

    def _cancel_clock_task(self) -> None:
        task, self._clock_task = self._clock_task, None
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()

    def _mark_link_down(self, reason: str) -> None:
        """끊김: 기다리던 요청을 모두 바로 실패시키고, 걸림 상태를 '모름'으로 돌린다(풀림으로 가정하지 않는다)."""
        log.warning("ActClient: link down (%s)", reason)
        # 사건 신선도 기준점도 버린다(3차 평가 M1) — 다음 세션의 clock_ref 전까지 그 링크 사건은 자동 실행 보류.
        self._event_clock().link_down()
        self._cancel_clock_task()
        self.link_up = False
        self._transport_up = False
        self._session = None
        self._hello_cn = None
        self._cancel_auth_task()
        self.link_drops += 1
        self.link_down_reason = reason
        # 다시 이은 뒤 RPi4의 답(estop_state)으로만 다시 안다 — 그때까지 서비스가 '확인하는 중'으로 거절한다.
        self.estop_latched = None
        self.estop_detail = None
        self.act_info = {}
        error = ActLinkError(f"RPi4 연결이 끊겼어요 ({reason})")
        pending = self._pending
        if pending is not None and not pending[1].done():
            # 짧은 단선이었다면 RPi4가 늦게 결과를 보낼 수 있다 — 다음 요청의 결과로 오인하지 않게.
            self._stale_sequence_ids.append(pending[0])
            pending[1].set_exception(error)
        for waiter in [*self._estop_waiters, *self._rehearsal_waiters.values(), *self._dev_waiters.values(),
                       *self._stop_waiters.values()]:
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
            self._transport_up = True
            self.link_up = self._link_key is None
            self.link_down_reason = None if self._link_key is None else self.AUTH_PENDING_REASON
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
        if self._link_key is not None:
            opened = self._open_frame(doc)
            if opened is None:
                if self.tap is not None:
                    self.tap.record("act_to_hub", None, raw)
                return  # 버린다 — 아무것도 바꾸지 않는다
            doc = opened
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
        if msg_type == "clock_ref":
            if not self._event_clock().on_clock_ref(doc):
                log.info("ActClient: clock_ref without a matching probe ignored")
            return
        if msg_type == "act_info":
            self.act_info = {k: v for k, v in doc.items() if k != "type"}
            link_stop = parse_link_stop(doc.get("last_link_stop"))
            if link_stop is not None:
                # RPi4가 링크를 잃고 스스로 멈췄던 실행(2026-10-16 G5) — 다시 이은 뒤 한 번 온다. 끊겨도 남겨 둔다.
                log.warning("ActClient: RPi4 reports it stopped %r by itself after losing the link",
                            link_stop["sequence_id"])
                self.last_link_stop = link_stop
            self._request_clock_ref()
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
        if msg_type == "stop_report":
            self.last_stop_report = _read_stop_report(doc)
            waiter = self._stop_waiters.get(doc.get("stop_id"))
            if waiter is not None and not waiter.done():
                waiter.set_result(doc)
            return
        if msg_type == "dev_motion_result":
            waiter = self._dev_waiters.get(doc.get("request_id"))
            if waiter is not None and not waiter.done():
                waiter.set_result(doc)
            else:
                # 기한이 지나 포기한 요청의 늦은 답 — 다음 요청의 결과로 쓰지 않는다(요청마다 새 id).
                log.warning("ActClient: late or unknown dev_motion_result ignored: %.120s", raw)
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
            self._note_estop(True, self.estop_detail or "비상 버튼이 눌려 있어요")
        if event is not None and self._on_alert is not None:
            self._on_alert(event)
        # "ack" and unknown types: recorded by the tap only, otherwise ignored.

    # IO helper

    async def _send(self, doc: dict) -> None:
        if not self.link_up:
            raise ActLinkError(f"RPi4 연결이 끊겨 다시 잇는 중이에요 ({self.link_down_reason})")
        if self._session is not None:
            doc = self._session.seal(doc)  # seq를 매기고 바로 쓴다(사이에 await 없음 — seq 순서 = 줄 순서)
        await self._write(doc)

    async def _write(self, doc: dict) -> None:
        payload = (json.dumps(doc, ensure_ascii=False) + "\n").encode("utf-8")
        log.debug("TX -> %s", payload.rstrip().decode())
        if self.tap is not None:
            self.tap.record("hub_to_act", doc)
        # 이 쓰기가 시작된 링크를 붙잡아 둔다 — drain이 늦게 실패하는 사이 읽기 루프가 이미 링크를 내리고
        # 다시 이었을 수 있다(10/8 리뷰 LOW). 그때는 옛 링크의 실패이므로 새 링크를 내리지 않는다.
        writer, reader = self._writer, self._reader
        try:
            writer.write(payload)
            await writer.drain()
        except Exception as exc:
            if self._transport_up and self._writer is writer:
                self._mark_link_down(f"write failed: {type(exc).__name__}: {exc}")
                # EOF가 오지 않는 쓰기 전용 고장도 같은 재연결 경로로 보낸다.
                if reader is not None:
                    reader.set_exception(exc)
            # execute가 아직 future를 await하기 전이면 예외를 회수해 경고 누수를 막는다.
            # 응답 기한 경로에서는 wait_for가 이미 future를 취소했다 — 취소된 future의 .exception()은
            # CancelledError(BaseException)를 던져 execute/verify_pass의 기한 초과 오류를 덮는다(10/8 리뷰).
            pending = self._pending
            if pending is not None and pending[1].done() and not pending[1].cancelled():
                pending[1].exception()
            raise


    # 링크 인증(2026-10-12)

    def _signed_hello(self) -> dict:
        assert self._link_key is not None
        doc = {"type": "hello", "cn": link_auth.new_nonce()}
        doc["mac"] = link_auth.compute_mac(self._link_key, doc)
        self._hello_cn = doc["cn"]
        return doc

    async def _send_hello(self) -> None:
        """새 ``cn``으로 서명한 hello를 보낸다. 답이 올 때까지 링크는 내려가 있다(보내기 거절)."""
        if not self._transport_up:
            raise ActLinkError(f"RPi4 연결이 끊겨 다시 잇는 중이에요 ({self.link_down_reason})")
        self._session = None
        self.link_up = False
        if self.link_down_reason != self.AUTH_FAILED_REASON:
            self.link_down_reason = self.AUTH_PENDING_REASON
        if self._auth_task is None or self._auth_task.done():
            self._auth_task = asyncio.create_task(self._watch_auth())
        await self._write(self._signed_hello())

    async def _watch_auth(self) -> None:
        """hello 답을 기다린다. 기한 안에 없으면 인증 실패로 두고 재연결과 같은 늘어나는 간격으로 hello를 다시 보낸다."""
        delay, ceiling = self._backoff
        while True:
            await asyncio.sleep(self.AUTH_REPLY_TIMEOUT_S)
            if self._session is not None or not self._transport_up:
                return
            self._note_auth_failure("no signed hello reply")
            await asyncio.sleep(delay)
            delay = min(delay * 2, ceiling)
            if self._session is not None or not self._transport_up:
                return
            try:
                await self._write(self._signed_hello())
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001 - 쓰기 실패는 _write가 링크를 내린다
                return

    def _cancel_auth_task(self) -> None:
        task, self._auth_task = self._auth_task, None
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()

    def _note_auth_failure(self, why: str) -> None:
        if self._session is None:
            self.link_up = False
            self.link_down_reason = self.AUTH_FAILED_REASON
        self._auth_drops.warn(log, why, "RPi4")

    def _open_frame(self, doc: dict) -> dict | None:
        """키가 있을 때 받은 문서를 확인한다. 받아들이면 봉투를 뗀 본문, 아니면 None(버린다)."""
        key = self._link_key
        assert key is not None
        if "sn" in doc:
            # hello 답 — 지금 기다리는 hello의 cn에 묶여 있고 K로 서명돼 있어야 한다.
            cn, sn = doc.get("cn"), doc.get("sn")
            if not link_auth.is_nonce(sn) or "seq" in doc or not link_auth.mac_ok(key, doc):
                self._note_auth_failure("bad hello reply")
                return None
            if self._hello_cn is None or cn != self._hello_cn:
                # 앞서 보낸 hello의 늦은 답(그 사이 hello를 다시 보냄)·재전송 — 실패가 아니라 버릴 뿐이다.
                self._auth_drops.warn(log, "stale hello reply", doc.get("type"))
                return None
            self._session = link_auth.LinkSession(link_auth.session_key(key, cn, sn))
            self._hello_cn = None
            self.link_up = True
            self.link_down_reason = None
            self._cancel_auth_task()
            log.info("ActClient: RPi4 authenticated — link up")
            return link_auth.strip_auth(doc)
        if self._session is None:
            # 인증 전에는 아무것도 믿지 않는다. 서명 없는 답이면 RPi4에 키가 없는 것 — 인증 실패로 보인다.
            # 서명된 프레임은 hello를 다시 보내기 전 세션의 늦은 프레임일 수 있어 버리기만 한다.
            if "mac" not in doc:
                self._note_auth_failure("unsigned frame (RPi4 has no link key?)")
            else:
                self._auth_drops.warn(log, "out-of-session frame", doc.get("type"))
            return None
        if not self._session.accept(doc):
            self._auth_drops.warn(log, "bad mac or seq", doc.get("type"))
            return None
        return link_auth.strip_auth(doc)


_STOP_TARGETS = ("run", "dev", "hold", "idle")


def _read_stop_report(doc: dict) -> dict:
    """``stop_report`` → ``{"stop_id", "stop_level", "ack_ms", "target", "stop_detail"}``(2026-10-13).

    ``stop_level``이 null이면 멈출 것이 없었거나 정지 줄을 쓰지 못한 것이라 None으로 둔다. 모르는 값은 ``sent``로
    낮춰 읽는다(`rpi.services.stop_confirm`)."""
    from .stop_confirm import read_ack_ms, read_stop_level  # noqa: PLC0415

    raw = doc.get("stop_level")
    level = None if raw is None else read_stop_level(raw)
    target = doc.get("target") if doc.get("target") in _STOP_TARGETS else None
    detail = doc.get("stop_detail") if isinstance(doc.get("stop_detail"), str) else None
    return {"stop_id": doc.get("stop_id") if isinstance(doc.get("stop_id"), str) else None,
            "stop_level": level, "ack_ms": read_ack_ms(doc.get("ack_ms"), level) if level else None,
            "target": target, "stop_detail": detail}


def targets_payload(targets: "Mapping[str, ButtonTarget]") -> dict[str, dict]:
    """ButtonTarget → docs/protocol.md의 ``targets`` JSON 모양."""
    out: dict[str, dict] = {}
    for name, target in targets.items():
        entry: dict = {"x_mm": target.x_mm, "y_mm": target.y_mm}
        if target.press_ms is not None:
            entry["press_ms"] = target.press_ms
        out[name] = entry
    return out
