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
   "ct":"ads1115","ct_ok":true}
  {"event":"power","t_ms":…,"seq":…,"watts":…,"irms_a":…,"vrms_est":220.0,"ct_mv":…,"n":…,"err":…,"relay":"on"}
  {"event":"estop","source":"button","t_ms":…,"relay":"off"}
  {"event":"fault","reason":"ct_init"} / {"event":"host_timeout","relay":"off"}

``watts``는 **추정값**이다: CT 실효 전류 × 설정 상용 전압(``vrms_est``, 측정 아님) × 설정 역률.
보정 계수가 자리표시자인 동안(``status.cal == "placeholder"``) 절대값은 근거가 아니다 — L3 판정은
기준선 대비 변화에 기대므로 그 오차에 비교적 둔감하다(rpi/verifier/power.py).

시각: 샘플의 ``t_s``는 **호스트 단조 시각에 맞춘 모듈 시각**이다. 첫 샘플(또는 모듈 재시작으로 ``t_ms``가
되돌아간 샘플)에서 ``anchor = 수신 시각 − t_ms/1000``을 잡고 이후 ``t_s = anchor + t_ms/1000``.
시리얼 지연으로 수신 간격이 흔들려도 샘플 간격은 모듈 시계를 따른다(측정 필요: 지연 크기).

끊김: 마지막 power 수신 뒤 ``stale_s``가 지나면 ``SerialPowerSensor.read()``는 0 W를 지어내지 않고
`PowerSensorStale`을 던진다. 컨트롤러는 그것을 'L3 판정 불가 — 전력 센서를 읽지 못함'으로 안전 정지한다.
"""

from __future__ import annotations

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

    def __post_init__(self) -> None:
        for name in ("stale_s", "reply_timeout_s", "max_lag_s"):
            value = getattr(self, name)
            if not (isinstance(value, (int, float)) and math.isfinite(value) and value > 0):
                raise ValueError(f"{name}는 0보다 큰 유한한 수여야 합니다: {value!r}")
        if self.heartbeat_s is not None and not (math.isfinite(self.heartbeat_s) and self.heartbeat_s > 0):
            raise ValueError(f"heartbeat_s는 0보다 큰 수 또는 None이어야 합니다: {self.heartbeat_s!r}")
        if self.ring_size < 10:
            raise ValueError("ring_size는 10 이상이어야 합니다")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "OutletConfig":
        """``SIMPLELAY_OUTLET_STALE_MS``·``SIMPLELAY_OUTLET_HEARTBEAT_MS``(0/off = 끔)."""
        src = os.environ if env is None else env
        base = cls()
        stale = _env_ms(src, "SIMPLELAY_OUTLET_STALE_MS")
        hb_raw = (src.get("SIMPLELAY_OUTLET_HEARTBEAT_MS") or "").strip().lower()
        heartbeat: float | None = base.heartbeat_s
        if hb_raw in ("0", "off", "false", "no"):
            heartbeat = None
        elif hb_raw:
            heartbeat = _env_ms(src, "SIMPLELAY_OUTLET_HEARTBEAT_MS")
        return cls(stale_s=stale if stale is not None else base.stale_s, ring_size=base.ring_size,
                   reply_timeout_s=base.reply_timeout_s, heartbeat_s=heartbeat, max_lag_s=base.max_lag_s)


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
    ) -> None:
        self._transport = transport
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
        self.started_at_s = clock()

    # ── 수명 ─────────────────────────────────────────────────────────────────

    def start(self) -> "OutletLink":
        reader = threading.Thread(target=self._read_loop, daemon=True, name="outlet-reader")
        self._threads.append(reader)
        reader.start()
        if self.config.heartbeat_s is not None:
            hb = threading.Thread(target=self._heartbeat_loop, daemon=True, name="outlet-heartbeat")
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
            self._transport.write_line(json.dumps(body, separators=(",", ":")))

    def _heartbeat_loop(self) -> None:
        assert self.config.heartbeat_s is not None
        while not self._stop.wait(self.config.heartbeat_s):
            try:
                self._write({"id": next(self._ids), "cmd": "ping"})  # 응답은 기다리지 않는다
            except Exception:  # noqa: BLE001 - heartbeat 실패가 읽기를 죽이지 않게
                log.debug("outlet heartbeat write failed", exc_info=True)

    def _read_loop(self) -> None:
        while not self._stop.is_set():
            try:
                line = self._transport.read_line(0.1)
            except Exception:  # noqa: BLE001 - 포트 오류는 끊김(stale)으로 드러난다
                log.exception("outlet read failed")
                if self._stop.wait(0.5):
                    return
                continue
            if line is None:
                continue
            doc = parse_outlet_line(line)
            if doc is None:
                continue
            self.handle_doc(doc)

    def handle_doc(self, doc: dict) -> None:
        """받은 문서 하나를 처리한다(읽기 스레드, 또는 시험에서 직접)."""
        event = doc.get("event")
        if event == "power":
            self._on_power(doc)
            return
        if isinstance(event, str):
            if event == "ready":
                self.last_ready = doc
            elif event == "fault":
                self.last_fault = doc
                log.error("outlet module fault: %s", doc.get("reason"))
            elif event == "estop":
                self.estop_events.append(doc)
                log.warning("outlet module E-STOP (source=%s) — appliance relay opened by the module",
                            doc.get("source"))
            for listener in list(self._listeners):
                try:
                    listener(doc)
                except Exception:  # noqa: BLE001 - 듣는 쪽 오류가 읽기를 멈추지 않게
                    log.exception("outlet listener failed for %s", event)
            return
        req_id = doc.get("id")
        if isinstance(req_id, int) and not isinstance(req_id, bool):
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
        t_ms, watts = parsed
        now = self._clock()
        with self._cond:
            if self._anchor_s is None or self._last_t_ms is None or t_ms <= self._last_t_ms:
                # 첫 샘플 또는 모듈 재시작(시계가 되돌아감) — 다시 맞춘다. 시각은 계속 늘어나야 한다.
                anchor = now - t_ms / 1000.0
                if self._last_t_s is not None and anchor + t_ms / 1000.0 <= self._last_t_s:
                    anchor = self._last_t_s + 1e-3 - t_ms / 1000.0
                self._anchor_s = anchor
            t_s = self._anchor_s + t_ms / 1000.0
            seq = doc.get("seq")
            relay = doc.get("relay")
            item = OutletPower(
                index=self._next_index,
                t_s=t_s,
                watts=watts,
                t_ms=t_ms,
                seq=seq if isinstance(seq, int) and not isinstance(seq, bool) else None,
                irms_a=_num(doc.get("irms_a")),
                vrms_est=_num(doc.get("vrms_est")),
                relay=relay if isinstance(relay, str) else None,
                received_s=now,
            )
            self._next_index += 1
            self._ring.append(item)
            self._last_t_ms = t_ms
            self._last_t_s = t_s
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
