"""콘센트 모듈 링크(RPi4 ↔ ESP32 콘센트 모듈) — **실물 미검증**, 가짜 출력(fake_outlet)으로만 시험.

2026-09-30 하드웨어 방향 확정 §1: ESP32 콘센트 모듈이 분할형 CT로 가전 전류를 재서 유효 전력
추정값을 RPi4로 **직접** 보낸다(L3 판정은 RPi4). 물리 비상정지 버튼과 가전 전원 릴레이도
그 모듈에 있다 — 버튼은 모듈 안에서 릴레이를 열고, 호스트에는 사후에 ``estop`` 이벤트로 알린다.

전송: 줄 단위 JSON(``\\n`` 종료), 모션 MCU 링크(`rpi/controller/serial_motion.py`)와 같은 형식.
전송 계층은 같은 `LineTransport`(``write_line``/``read_line``)를 쓴다 — 실기기는
`PySerialLineTransport`, 시험은 `InMemoryLinePipe` + `rpi.tools.fake_outlet.FakeOutlet`.
명령 표: ``firmware-outlet/protocol_table.json``(시험이 펌웨어 소스·가짜 출력과 대조한다).

호스트 → 모듈                                   모듈 → 호스트(응답)
  {"id":1,"cmd":"status"}                         {"id":1,"ok":true,"relay":"off","estop":false,"button":false,
                                                   "rate_hz":10,"ct":"ads1115","cal":"placeholder","uptime_ms":…}
  {"id":2,"cmd":"ping"}                           {"id":2,"ok":true}
  {"id":3,"cmd":"relay_on"}                       {"id":3,"ok":true} | {"id":3,"ok":false,"error":"estop_latched"}
  {"id":4,"cmd":"relay_off"}                      {"id":4,"ok":true}
  {"id":5,"cmd":"estop_reset"}                    {"id":5,"ok":true} | {"id":5,"ok":false,"error":"estop_active"}
  {"id":6,"cmd":"rate","hz":10}                   {"id":6,"ok":true} | bad_args
모듈 → 호스트(자발 이벤트, id 없음)
  {"event":"ready","fw":"firmware-outlet","protocol":"line-json/outlet-v0","reset":"poweron","relay":"off",
   "ct":"ads1115","ct_ok":true,"estop":false}   (estop: 재부팅 전에 걸린 비상정지를 기억하고 있으면 true)
  {"event":"power","t_ms":…,"seq":…,"watts":…,"irms_a":…,"vrms_est":220.0,"ct_mv":…,"n":…,"err":…,"relay":"on"}
  {"event":"estop","source":"button","t_ms":…,"relay":"off"}
  {"event":"fault","reason":"ct_init"} / {"event":"host_timeout","relay":"off"}

``watts``는 **추정값**이다: CT 실효 전류 × 설정 상용 전압(``vrms_est``, 측정 아님) × 설정 역률.
보정 계수가 자리표시자인 동안(``status.cal == "placeholder"``) 절대값은 근거가 아니다 — L3 판정은
기준선 대비 변화에 기대므로 그 오차에 비교적 둔감하다(rpi/verifier/power.py).

시각: 샘플의 ``t_s``는 **호스트 단조 시각에 맞춘 모듈 시각**이다. 첫 샘플, ``ready`` 배너(모듈 재시작) 뒤
첫 샘플, 또는 ``seq``가 작은 값으로 되돌아간 샘플에서만 ``anchor = 수신 시각 − t_ms/1000``을 다시 잡고 이후
``t_s = anchor + t_ms/1000``. 그 밖에 ``t_ms``·``seq``가 늘지 않은 줄(중복·순서 뒤바뀜)은 버리고 신선도도
갱신하지 않는다 — 같은 줄의 반복이 '샘플이 오고 있음'으로 보이지 않게(2026-10-05 리뷰 L1).

품질(2026-10-05 리뷰 M1): 창 샘플 수 ``n``이 ``min_samples`` 미만이거나 판독 실패 비율 ``err/n``이
``max_err_ratio``를 넘는 power 줄은 버린다(신선한 샘플로 세지 않는다). 둘 다 측정 필요.

끊김: 마지막 power 수신 뒤 ``stale_s``가 지나면 ``SerialPowerSensor.read()``는 0 W를 지어내지 않고
`PowerSensorStale`을 던진다. 컨트롤러는 그것을 'L3 판정 불가 — 전력 센서를 읽지 못함'으로 안전 정지한다.

생존(2026-10-05 리뷰 M2): 어떤 줄이든(응답·ping 응답 포함) 마지막으로 받은 뒤 ``offline_s``가 지나면
`OutletLink.not_ready_reason`이 이유를 돌려준다 — RPi4는 그동안 execute를 ``outlet_offline``으로 거절한다
(모듈이 조용하면 물리 비상정지 이벤트도 볼 수 없다). 읽기에서 포트 오류가 나면 ``reopen``으로 backoff
간격을 두고 다시 연다. ``status_poll_s``마다 status를 물어 ``estop`` 표시를 반영한다(이벤트 줄을 잃어도
걸림을 놓치지 않게). 모듈 걸림(``module_estop``)이 새로 참이 되면 듣는 쪽에 ``{"event":"estop",
"source":"ready"|"status"}``를 넘긴다.
"""

from __future__ import annotations

import contextlib
import itertools
import json
import logging
import math
import os
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

from .power import PowerSample

log = logging.getLogger(__name__)

OUTLET_PROTOCOL = "line-json/outlet-v0"

#: 모듈이 보내는 자발 이벤트 이름(power 제외 — power는 링 버퍼로 간다).
OUTLET_EVENTS = ("ready", "power", "estop", "fault", "host_timeout")
#: 호스트가 보내는 명령.
OUTLET_COMMANDS = ("status", "ping", "relay_on", "relay_off", "estop_reset", "rate")


class OutletError(RuntimeError):
    """콘센트 모듈 링크 오류의 공통 부모."""


class PowerSensorStale(OutletError):
    """전력 샘플이 ``stale_s`` 넘게 오지 않았다. 0 W로 대신하지 않는다."""


class OutletTimeout(OutletError):
    """명령 응답이 기한 안에 오지 않았다."""


class OutletOffline(OutletError):
    """포트를 다시 여는 중이라 보낼 수 없다."""


class OutletRefused(OutletError):
    """모듈이 ``ok:false``로 답했다(``code``: estop_latched·estop_active·bad_args·unknown_cmd)."""

    def __init__(self, cmd: str, code: str) -> None:
        self.cmd = cmd
        self.code = code
        super().__init__(f"콘센트 모듈이 {cmd}을(를) 거절함: {code}")


@dataclass(frozen=True)
class OutletConfig:
    """호스트 쪽 박자. 기구·전기 값이 아니라 기본값을 둔다 — 그래도 실측 뒤 조정(측정 필요)."""

    #: 마지막 power 수신 뒤 이만큼 지나면 '데이터 없음'(초). 10 Hz 보고 기준 샘플 10개.
    stale_s: float = 1.0
    #: 링 버퍼 길이(샘플 수). 10 Hz 기준 10분 — 잔여 전류 꼬리를 볼 만큼.
    ring_size: int = 6000
    #: 명령 응답 기한(초).
    reply_timeout_s: float = 1.0
    #: ping 간격(초). None이면 보내지 않는다. 모듈 HOST_SILENCE_RELAY_OFF=1일 때 필요.
    heartbeat_s: float | None = 1.0
    #: 읽는 쪽이 이만큼 넘게 밀리면 밀린 샘플을 건너뛰고 최신으로 간다(초).
    max_lag_s: float = 1.0
    #: 어떤 줄도 이만큼 받지 못하면 모듈 무응답(초). heartbeat(1 s) 응답 몇 개를 놓칠 여유. 측정 필요.
    offline_s: float = 3.0
    #: status 조회 간격(초) — 응답의 ``estop``을 반영한다. None이면 조회하지 않는다.
    status_poll_s: float | None = 2.0
    #: power 줄의 창 샘플 수 하한. 10 Hz 보고면 ADS1115 창 80·내장 ADC 창 200 — 그 1/4. 측정 필요.
    min_samples: int = 20
    #: power 줄의 판독 실패 비율(err/n) 상한. 넘으면 버린다. 측정 필요.
    max_err_ratio: float = 0.1

    def __post_init__(self) -> None:
        for name in ("stale_s", "reply_timeout_s", "max_lag_s", "offline_s"):
            value = getattr(self, name)
            if not (isinstance(value, (int, float)) and math.isfinite(value) and value > 0):
                raise ValueError(f"{name}는 0보다 큰 유한한 수여야 합니다: {value!r}")
        for name in ("heartbeat_s", "status_poll_s"):
            value = getattr(self, name)
            if value is not None and not (math.isfinite(value) and value > 0):
                raise ValueError(f"{name}는 0보다 큰 수 또는 None이어야 합니다: {value!r}")
        if self.ring_size < 10:
            raise ValueError("ring_size는 10 이상이어야 합니다")
        if isinstance(self.min_samples, bool) or not isinstance(self.min_samples, int) or self.min_samples < 1:
            raise ValueError(f"min_samples는 1 이상의 정수여야 합니다: {self.min_samples!r}")
        if not (math.isfinite(self.max_err_ratio) and 0 <= self.max_err_ratio <= 1):
            raise ValueError(f"max_err_ratio는 0~1이어야 합니다: {self.max_err_ratio!r}")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "OutletConfig":
        """``SIMPLELAY_OUTLET_STALE_MS``·``_HEARTBEAT_MS``·``_STATUS_POLL_MS``(0/off = 끔)·``_OFFLINE_MS``·
        ``_MIN_SAMPLES``·``_MAX_ERR_RATIO``."""
        src = os.environ if env is None else env
        base = cls()
        stale = _env_ms(src, "SIMPLELAY_OUTLET_STALE_MS")
        offline = _env_ms(src, "SIMPLELAY_OUTLET_OFFLINE_MS")
        min_raw = (src.get("SIMPLELAY_OUTLET_MIN_SAMPLES") or "").strip()
        err_raw = (src.get("SIMPLELAY_OUTLET_MAX_ERR_RATIO") or "").strip()
        try:
            min_samples = int(min_raw) if min_raw else base.min_samples
            max_err = float(err_raw) if err_raw else base.max_err_ratio
        except ValueError as exc:
            raise RuntimeError(f"SIMPLELAY_OUTLET_MIN_SAMPLES/MAX_ERR_RATIO 값을 읽을 수 없습니다: {exc}") from exc
        return cls(stale_s=stale if stale is not None else base.stale_s, ring_size=base.ring_size,
                   reply_timeout_s=base.reply_timeout_s,
                   heartbeat_s=_env_optional_ms(src, "SIMPLELAY_OUTLET_HEARTBEAT_MS", base.heartbeat_s),
                   max_lag_s=base.max_lag_s,
                   offline_s=offline if offline is not None else base.offline_s,
                   status_poll_s=_env_optional_ms(src, "SIMPLELAY_OUTLET_STATUS_POLL_MS", base.status_poll_s),
                   min_samples=min_samples, max_err_ratio=max_err)


def _env_optional_ms(src: Mapping[str, str], name: str, default: float | None) -> float | None:
    raw = (src.get(name) or "").strip().lower()
    if raw in ("0", "off", "false", "no"):
        return None
    return _env_ms(src, name) if raw else default


def _env_ms(src: Mapping[str, str], name: str) -> float | None:
    raw = (src.get(name) or "").strip()
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc
    if not (math.isfinite(value) and value > 0):
        raise RuntimeError(f"{name}는 0보다 커야 합니다: {raw!r}")
    return value / 1000.0


@dataclass(frozen=True)
class OutletPower:
    """power 이벤트 하나(호스트 시각에 맞춘 뒤)."""

    index: int  # 호스트가 매긴 연속 번호(링 버퍼 커서용)
    t_s: float  # 호스트 단조 시각에 맞춘 모듈 시각
    watts: float
    t_ms: int  # 모듈 millis
    seq: int | None
    irms_a: float | None
    vrms_est: float | None
    relay: str | None
    received_s: float  # 수신한 호스트 단조 시각

    def sample(self) -> PowerSample:
        return PowerSample(self.t_s, self.watts)


def _num(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    f = float(value)
    return f if math.isfinite(f) else None


def parse_outlet_line(line: str) -> dict | None:
    """한 줄 → JSON 객체. 부트 로그·깨진 줄은 None(무시)."""
    line = line.strip()
    if not line.startswith("{"):
        return None
    try:
        doc = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


#: ``seq``가 이 값 이하로 되돌아가면 모듈 재시작으로 본다(ready 배너를 놓쳤을 때). 부팅 뒤 0부터 센다.
SEQ_RESTART_MAX = 5
#: 포트를 다시 여는 간격(초). 마지막 값에서 멈춘다. 호스트 박자.
REOPEN_BACKOFF_S = (0.5, 1.0, 2.0, 4.0, 5.0)


def _opt_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def power_quality_problem(doc: Mapping[str, Any], config: "OutletConfig") -> str | None:
    """창 샘플 수·판독 실패 비율로 본 power 줄의 문제(없으면 None). ``n``이 없으면 믿지 않는다."""
    n = _opt_int(doc.get("n"))
    if n is None:
        return "n 없음"
    if n < config.min_samples:
        return f"창 샘플 {n}개 < 하한 {config.min_samples}"
    err = _opt_int(doc.get("err"))
    if err is not None and err > 0 and err / n > config.max_err_ratio:
        return f"판독 실패 {err}/{n} > {config.max_err_ratio:g}"
    return None


def power_fields(doc: Mapping[str, Any]) -> tuple[int, float] | None:
    """power 이벤트의 (t_ms, watts). 형식이 틀리거나 음수·비유한 전력이면 None(버린다)."""
    t_ms = doc.get("t_ms")
    if isinstance(t_ms, bool) or not isinstance(t_ms, int) or t_ms < 0:
        return None
    watts = _num(doc.get("watts"))
    if watts is None or watts < 0:
        return None
    return t_ms, watts


class OutletLink:
    """콘센트 모듈 한 대와의 링크. 읽기 스레드가 줄을 받아 power는 링 버퍼로, 응답은 대기 중인
    명령으로, 그 밖의 이벤트는 듣는 쪽(``add_listener``)으로 보낸다.

    ``mock=True``는 가짜 출력(fake_outlet)에 붙은 링크다 — 여기서 나온 판정은 합성 입력으로 표시한다.
    """

    def __init__(
        self,
        transport: Any,
        config: OutletConfig | None = None,
        *,
        mock: bool = False,
        clock: Callable[[], float] = time.monotonic,
        reopen: Callable[[], Any] | None = None,
        reopen_backoff_s: tuple[float, ...] = REOPEN_BACKOFF_S,
    ) -> None:
        """``reopen``: 읽기에서 포트 오류(USB 빠짐 등)가 나면 새 전송을 여는 함수. None이면 다시 열지 않는다."""
        self._transport = transport
        self._reopen = reopen
        self._reopen_backoff_s = reopen_backoff_s
        self._reopening = False
        #: 포트를 다시 연 횟수(시험·상태 확인용).
        self.reopens = 0
        self.config = config or OutletConfig()
        self.mock = mock
        self._clock = clock
        self._cond = threading.Condition()
        self._ring: deque[OutletPower] = deque(maxlen=self.config.ring_size)
        self._next_index = 0
        self._anchor_s: float | None = None
        self._last_t_ms: int | None = None
        self._last_t_s: float | None = None
        self._last_power_rx: float | None = None
        self._last_seq: int | None = None
        self._reanchor = False
        #: 어떤 줄이든 마지막으로 받은 호스트 시각(생존 판단). 신선도(_last_power_rx)와 다르다.
        self._last_rx: float | None = None
        #: 모듈이 보고한 비상정지 걸림(estop 이벤트·ready·status). 모르면 None.
        self.module_estop: bool | None = None
        self._replies: dict[int, dict] = {}
        self._ids = itertools.count(1)
        self._write_lock = threading.Lock()
        self._listeners: list[Callable[[dict], None]] = []
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self.last_ready: dict | None = None
        self.last_fault: dict | None = None
        self.estop_events: list[dict] = []
        self.dropped_power = 0
        #: 품질(n·err) 미달로 버린 power 줄 수.
        self.dropped_quality = 0
        #: 중복·순서 뒤바뀜으로 버린 power 줄 수.
        self.dropped_out_of_order = 0
        self.started_at_s = clock()

    # ── 수명 ─────────────────────────────────────────────────────────────────

    def start(self) -> "OutletLink":
        reader = threading.Thread(target=self._read_loop, daemon=True, name="outlet-reader")
        self._threads.append(reader)
        reader.start()
        if self.config.heartbeat_s is not None or self.config.status_poll_s is not None:
            hb = threading.Thread(target=self._keepalive_loop, daemon=True, name="outlet-keepalive")
            self._threads.append(hb)
            hb.start()
        return self

    def close(self) -> None:
        self._stop.set()
        with self._cond:
            self._cond.notify_all()
        for thread in self._threads:
            thread.join(timeout=2.0)
        close = getattr(self._transport, "close", None)
        if callable(close):
            try:
                close()
            except Exception:  # noqa: BLE001 - 종료 경로
                log.debug("outlet transport close failed", exc_info=True)

    def add_listener(self, listener: Callable[[dict], None]) -> None:
        """power 외 자발 이벤트(ready·estop·fault·host_timeout)를 받는다. **읽기 스레드에서** 불린다."""
        self._listeners.append(listener)

    # ── 전력 샘플 ────────────────────────────────────────────────────────────

    def sensor(self) -> "SerialPowerSensor":
        """독립 커서를 가진 PowerSensor 하나. 소비자(L3·꼬리 관찰·기록기)마다 따로 만든다."""
        return SerialPowerSensor(self)

    def latest(self) -> OutletPower | None:
        with self._cond:
            return self._ring[-1] if self._ring else None

    def samples_since(self, t_s: float) -> list[PowerSample]:
        with self._cond:
            return [p.sample() for p in self._ring if p.t_s >= t_s]

    def is_stale(self) -> bool:
        with self._cond:
            last = self._last_power_rx
        reference = last if last is not None else self.started_at_s
        return self._clock() - reference > self.config.stale_s

    def not_ready_reason(self) -> str | None:
        """모듈과 말이 통하지 않으면 사람이 읽을 이유, 아니면 None. RPi4 실행기가 execute 전에 본다."""
        if self._reopening:
            return "콘센트 모듈 포트를 다시 여는 중이에요(USB 연결 확인)"
        with self._cond:
            last = self._last_rx
        reference = last if last is not None else self.started_at_s
        silence = self._clock() - reference
        if silence > self.config.offline_s:
            if last is None:
                return f"콘센트 모듈이 {silence:.1f}초째 한 번도 답하지 않았어요(연결 확인)"
            return f"콘센트 모듈이 {silence:.1f}초째 답하지 않아요(한도 {self.config.offline_s:g}초)"
        return None

    # ── 명령 ─────────────────────────────────────────────────────────────────

    def request(self, cmd: str, timeout_s: float | None = None, **fields: Any) -> dict:
        """명령 하나를 보내고 같은 id의 응답을 기다린다. ``ok:false``면 `OutletRefused`."""
        req_id = next(self._ids)
        body = {"id": req_id, "cmd": cmd, **fields}
        self._write(body)
        deadline = self._clock() + (self.config.reply_timeout_s if timeout_s is None else timeout_s)
        with self._cond:
            while req_id not in self._replies:
                remaining = deadline - self._clock()
                if remaining <= 0 or self._stop.is_set():
                    raise OutletTimeout(f"콘센트 모듈이 {cmd}에 답하지 않음")
                self._cond.wait(min(remaining, 0.05))
            reply = self._replies.pop(req_id)
        if reply.get("ok") is not True:
            raise OutletRefused(cmd, str(reply.get("error") or "unknown"))
        return reply

    def status(self) -> dict:
        return self.request("status")

    def ping(self) -> None:
        self.request("ping")

    def relay_on(self) -> None:
        self.request("relay_on")

    def relay_off(self) -> None:
        self.request("relay_off")

    def estop_reset(self) -> None:
        self.request("estop_reset")
        with self._cond:
            self.module_estop = False

    def reset_estop_if_released(self) -> tuple[bool, str | None]:
        """사람의 해제 확인을 모듈에 옮긴다. ``(풀렸나, 사유)`` — 버튼이 아직 눌려 있으면 보내지 않는다.

        사유: ``estop_button_pressed``(눌림·단선) · ``outlet_unreachable``(무응답·거절).
        """
        try:
            status = self.status()
        except OutletError as exc:
            log.warning("outlet status before estop reset failed: %s", exc)
            return False, "outlet_unreachable"
        if status.get("button") is not False:
            return False, "estop_button_pressed"
        if status.get("estop") is False:
            return True, None
        try:
            self.estop_reset()
        except OutletRefused as exc:
            return False, "estop_button_pressed" if exc.code == "estop_active" else "outlet_unreachable"
        except OutletError as exc:
            log.warning("outlet estop_reset failed: %s", exc)
            return False, "outlet_unreachable"
        return True, None

    def set_rate(self, hz: int) -> None:
        self.request("rate", hz=int(hz))

    def wait_ready(self, timeout_s: float = 3.0) -> dict | None:
        """부팅 배너를 기다리거나 status로 응답을 확인한다. 둘 다 없으면 None."""
        deadline = self._clock() + timeout_s
        while self._clock() < deadline:
            if self.last_ready is not None:
                return self.last_ready
            try:
                return self.status()
            except OutletError:
                continue
        return None

    # ── 내부 ─────────────────────────────────────────────────────────────────

    def _write(self, body: dict) -> None:
        with self._write_lock:
            if self._reopening:
                raise OutletOffline("콘센트 모듈 포트를 다시 여는 중")
            try:
                self._transport.write_line(json.dumps(body, separators=(",", ":")))
            except OutletError:
                raise
            except Exception as exc:  # noqa: BLE001 - 포트 오류는 링크 오류로 올린다
                raise OutletOffline(f"콘센트 모듈로 쓰지 못함: {exc}") from exc

    def _keepalive_loop(self) -> None:
        """ping(응답은 기다리지 않는다 — 생존은 받은 줄로 본다)과 주기 status(``estop`` 반영)."""
        hb, poll = self.config.heartbeat_s, self.config.status_poll_s
        tick = min(v for v in (hb, poll) if v is not None)
        next_poll = self._clock() + poll if poll is not None else None
        while not self._stop.wait(tick):
            if next_poll is not None and poll is not None and self._clock() >= next_poll:
                next_poll = self._clock() + poll
                try:
                    self.status()  # 응답의 estop은 handle_doc이 반영한다
                except OutletError as exc:
                    log.debug("outlet status poll failed: %s", exc)
                continue  # status 응답도 생존 신호다 — 이번 틱 ping은 생략
            if hb is not None:
                try:
                    self._write({"id": next(self._ids), "cmd": "ping"})
                except Exception:  # noqa: BLE001 - heartbeat 실패가 읽기를 죽이지 않게
                    log.debug("outlet heartbeat write failed", exc_info=True)

    def _read_loop(self) -> None:
        while not self._stop.is_set():
            try:
                line = self._transport.read_line(0.1)
            except Exception:  # noqa: BLE001 - 포트 오류는 무응답(not_ready_reason)으로 드러난다
                log.exception("outlet read failed")
                if self._reopen is None:
                    if self._stop.wait(0.5):
                        return
                    continue
                if not self._reconnect():
                    return
                continue
            if line is None:
                continue
            doc = parse_outlet_line(line)
            if doc is None:
                continue
            self.handle_doc(doc)

    def _reconnect(self) -> bool:
        """포트를 닫고 backoff 간격으로 다시 연다. 닫히는 중이면 False."""
        assert self._reopen is not None
        with self._write_lock:
            self._reopening = True
            old = self._transport
        with contextlib.suppress(Exception):
            close = getattr(old, "close", None)
            if callable(close):
                close()
        attempt = 0
        while True:
            wait = self._reopen_backoff_s[min(attempt, len(self._reopen_backoff_s) - 1)]
            attempt += 1
            if self._stop.wait(wait):
                return False
            try:
                fresh = self._reopen()
            except Exception as exc:  # noqa: BLE001 - 아직 꽂히지 않음
                log.warning("outlet port reopen failed (attempt %d): %s", attempt, exc)
                continue
            with self._write_lock:
                self._transport = fresh
                self._reopening = False
            with self._cond:
                self._reanchor = True  # 포트 열기로 모듈이 리셋됐을 수 있다
            self.reopens += 1
            log.warning("outlet port reopened (attempt %d)", attempt)
            return True

    def _notify(self, doc: dict) -> None:
        for listener in list(self._listeners):
            try:
                listener(doc)
            except Exception:  # noqa: BLE001 - 듣는 쪽 오류가 읽기를 멈추지 않게
                log.exception("outlet listener failed for %s", doc.get("event"))

    def _note_module_estop(self, value: object, source: str) -> None:
        """ready·status가 보고한 걸림 표시를 반영한다. 새로 참이 되면 듣는 쪽에 estop으로 넘긴다."""
        if not isinstance(value, bool):
            return
        with self._cond:
            newly = value and self.module_estop is not True
            self.module_estop = value
        if newly:
            log.warning("outlet module reports a latched E-STOP (via %s)", source)
            self._notify({"event": "estop", "source": source, "reported": True})

    def handle_doc(self, doc: dict) -> None:
        """받은 문서 하나를 처리한다(읽기 스레드, 또는 시험에서 직접)."""
        with self._cond:
            self._last_rx = self._clock()  # 어떤 줄이든 생존 신호(신선도와 별개)
        event = doc.get("event")
        if event == "power":
            self._on_power(doc)
            return
        if isinstance(event, str):
            if event == "ready":
                self.last_ready = doc
                with self._cond:
                    self._reanchor = True  # 모듈 재시작 — 다음 power에서 시각을 다시 맞춘다
            elif event == "fault":
                self.last_fault = doc
                log.error("outlet module fault: %s", doc.get("reason"))
            elif event == "estop":
                self.estop_events.append(doc)
                with self._cond:
                    self.module_estop = True
                log.warning("outlet module E-STOP (source=%s) — appliance relay opened by the module",
                            doc.get("source"))
            self._notify(doc)
            if event == "ready":
                self._note_module_estop(doc.get("estop"), "ready")
            return
        req_id = doc.get("id")
        if isinstance(req_id, int) and not isinstance(req_id, bool):
            if doc.get("ok") is True and "estop" in doc:
                self._note_module_estop(doc.get("estop"), "status")
            with self._cond:
                self._replies[req_id] = doc
                # 오래 안 찾아간 응답(heartbeat ping 등)이 쌓이지 않게 자른다.
                if len(self._replies) > 64:
                    for stale in sorted(self._replies)[:-32]:
                        self._replies.pop(stale, None)
                self._cond.notify_all()

    def _on_power(self, doc: dict) -> None:
        parsed = power_fields(doc)
        if parsed is None:
            self.dropped_power += 1
            return
        problem = power_quality_problem(doc, self.config)
        if problem is not None:
            self.dropped_quality += 1
            log.debug("outlet power line dropped (%s)", problem)
            return
        t_ms, watts = parsed
        seq = _opt_int(doc.get("seq"))
        now = self._clock()
        with self._cond:
            restarted = self._reanchor or (
                seq is not None and self._last_seq is not None and seq < self._last_seq
                and seq <= SEQ_RESTART_MAX
            )
            if self._anchor_s is None or self._last_t_ms is None or restarted:
                # 첫 샘플 또는 모듈 재시작(ready 배너·seq 되돌아감) — 다시 맞춘다. 시각은 계속 늘어나야 한다.
                anchor = now - t_ms / 1000.0
                if self._last_t_s is not None and anchor + t_ms / 1000.0 <= self._last_t_s:
                    anchor = self._last_t_s + 1e-3 - t_ms / 1000.0
                self._anchor_s = anchor
                self._reanchor = False
            elif t_ms <= self._last_t_ms or (
                seq is not None and self._last_seq is not None and seq <= self._last_seq
            ):
                # 중복·순서 뒤바뀜 — 버리고 신선도도 갱신하지 않는다.
                self.dropped_out_of_order += 1
                return
            t_s = self._anchor_s + t_ms / 1000.0
            relay = doc.get("relay")
            item = OutletPower(
                index=self._next_index,
                t_s=t_s,
                watts=watts,
                t_ms=t_ms,
                seq=seq,
                irms_a=_num(doc.get("irms_a")),
                vrms_est=_num(doc.get("vrms_est")),
                relay=relay if isinstance(relay, str) else None,
                received_s=now,
            )
            self._next_index += 1
            self._ring.append(item)
            self._last_t_ms = t_ms
            self._last_t_s = t_s
            self._last_seq = seq
            self._last_power_rx = now
            self._cond.notify_all()


class SerialPowerSensor:
    """`PowerSensor` 구현 — 콘센트 모듈 power 이벤트를 한 개씩 돌려준다.

    - 커서는 만든 시점의 최신 샘플 **다음**부터다(이전 실행의 묵은 샘플을 기준선에 섞지 않는다).
    - 다음 샘플이 아직 없으면 기다린다. 마지막 수신 뒤 ``stale_s``가 지나면 `PowerSensorStale`.
      0 W나 마지막 값을 반복해 '읽은 척'하지 않는다.
    - 읽는 쪽이 ``max_lag_s`` 넘게 밀리면 최신 샘플로 건너뛴다(판정이 과거를 보지 않게).
    """

    def __init__(self, link: OutletLink) -> None:
        self._link = link
        latest = link.latest()
        self._cursor = latest.index if latest is not None else -1
        self.source = "mock" if link.mock else "real"

    @property
    def link(self) -> OutletLink:
        return self._link

    def read(self) -> PowerSample:
        link = self._link
        cfg = link.config
        with link._cond:  # noqa: SLF001 - 같은 모듈의 짝 클래스
            while True:
                ring = link._ring  # noqa: SLF001
                if ring and ring[-1].index > self._cursor:
                    first = ring[0].index
                    offset = max(0, self._cursor + 1 - first)
                    candidate = ring[offset]
                    newest = ring[-1]
                    if newest.t_s - candidate.t_s > cfg.max_lag_s:
                        candidate = newest
                    self._cursor = candidate.index
                    return candidate.sample()
                last = link._last_power_rx  # noqa: SLF001
                reference = last if last is not None else link.started_at_s
                waited = link._clock() - reference  # noqa: SLF001
                if waited > cfg.stale_s:
                    if last is None:
                        raise PowerSensorStale(
                            f"콘센트 모듈 전력 샘플을 한 번도 받지 못함({cfg.stale_s:.1f}초 넘게) — "
                            "연결·CT 초기화 확인 필요"
                        )
                    raise PowerSensorStale(
                        f"콘센트 모듈 전력 샘플이 {waited:.1f}초째 끊김(한도 {cfg.stale_s:.1f}초)"
                    )
                if link._stop.is_set():  # noqa: SLF001
                    raise PowerSensorStale("콘센트 모듈 링크가 닫힘")
                link._cond.wait(min(0.05, cfg.stale_s - waited + 1e-3))  # noqa: SLF001
