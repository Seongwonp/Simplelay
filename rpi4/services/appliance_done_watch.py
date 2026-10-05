"""세탁 끝 관찰(RPi4) — 콘센트 모듈 CT 전력 하강 + 마이크 종료음을 융합해 RPi5에 알린다(2026-10-06, 결정 D2).

**실물 미검증** — 가짜 콘센트 모듈(`rpi/tools/fake_outlet.py`)과 합성 음으로만 시험했다. 기준값은 전부 측정 필요
(`SIMPLELAY_CYCLE_*`·`SIMPLELAY_BEEP_*`·`SIMPLELAY_DONE_FUSION_*`).

설정 ``SIMPLELAY_DONE_WATCH=<가전 ID>:<입력>[,<입력>][;<가전 ID>:…]`` — 입력은 ``outlet``(CT 전력 → power)·``mic``
(종료음 → beep). 예: ``washer:outlet,mic;microwave:outlet``. 2026-10-06 두 번째 CT로 **가전마다 CT 채널 하나**를 읽는다
(채널은 ``SIMPLELAY_OUTLET_CHANNELS``, `rpi.verifier.outlet.parse_outlet_channels`). 마이크는 하나라 ``mic``은 한 가전만.
가전마다 끝 이벤트 이름이 다르다(`done_event_for`: 세탁기 wash_complete · 전자레인지 heat_complete). 비우면 끈다.

- `ApplianceDoneWatch`: 사이클 끝 검출기(`rpi/verifier/cycle_end.py`)·종료음 검출기(`end_beep.py`)·융합
  (`done_fusion.py`)을 묶는다. 알릴 것이 생기면 ``emit(frame)``으로 ``{"type":"appliance_done",…}``를 넘긴다.
- `PowerCycleFeeder`: 배경 스레드 하나가 콘센트 모듈 전력 스트림을 계속 읽어 관찰에 넣는다. 끊기면(`PowerSensorStale`)
  대기 연속을 다시 세게 하고 잠깐 쉬었다 다시 읽는다. **릴레이 명령을 보내지 않는다** — 세탁기는 기동 전류가 커서
  릴레이로 끊지 않고 CT로 재기만 한다(사용자 결정 10/6).
- 종료음 프레임은 위험 소리 감지 루프(`DangerSoundMonitor`)가 같은 마이크 프레임을 나눠 준다(``frame_listeners``).
"""

from __future__ import annotations

import logging
import re
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

import numpy as np

from rpi.verifier.cycle_end import CycleEndConfig, CycleEndTracker
from rpi.verifier.done_fusion import ApplianceDoneFusion, DoneFusionConfig, done_event_for
from rpi.verifier.end_beep import EndBeepConfig, EndBeepDetector
from rpi.verifier.outlet import OutletLink, PowerSensorStale
from rpi.verifier.power import PowerSample

log = logging.getLogger(__name__)

_INPUT_NAMES = {"outlet": "power", "mic": "beep"}
_APPLIANCE_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")


@dataclass(frozen=True)
class DoneWatchSpec:
    appliance_id: str
    #: 융합 입력(power·beep 순서로 정렬).
    inputs: tuple[str, ...]


def parse_done_watches(raw: str | None) -> tuple[DoneWatchSpec, ...]:
    """``SIMPLELAY_DONE_WATCH`` 값(``;``로 가전 여럿)을 읽는다. 비면 빈 튜플, 잘못되면 RuntimeError(기동 거절).
    같은 가전 두 번·``mic``을 두 가전에 다는 것을 거절한다(마이크·종료음 검출기가 하나)."""
    text = (raw or "").strip()
    if not text:
        return ()
    specs: list[DoneWatchSpec] = []
    for part in text.split(";"):
        spec = parse_done_watch(part)
        if spec is None:
            raise RuntimeError(f"SIMPLELAY_DONE_WATCH에 빈 항목이 있습니다: {text!r}")
        if any(s.appliance_id == spec.appliance_id for s in specs):
            raise RuntimeError(f"SIMPLELAY_DONE_WATCH에 '{spec.appliance_id}'가 두 번 있습니다: {text!r}")
        specs.append(spec)
    if sum("beep" in s.inputs for s in specs) > 1:
        raise RuntimeError("SIMPLELAY_DONE_WATCH에서 mic(종료음)은 한 가전에만 달 수 있습니다(마이크 하나)")
    return tuple(specs)


def parse_done_watch(raw: str | None) -> DoneWatchSpec | None:
    """가전 하나(``<가전 ID>:outlet[,mic]``)를 읽는다. 비면 None, 잘못되면 RuntimeError(기동 거절)."""
    text = (raw or "").strip()
    if not text:
        return None
    if ";" in text:
        raise RuntimeError("가전 여럿은 parse_done_watches로 읽습니다")
    appliance, sep, rest = text.partition(":")
    appliance = appliance.strip()
    if not sep or not _APPLIANCE_ID.fullmatch(appliance):
        raise RuntimeError(f"SIMPLELAY_DONE_WATCH 형식은 '<가전 ID>:outlet[,mic]'입니다: {text!r}")
    names = [part.strip() for part in rest.split(",") if part.strip()]
    if not names or any(name not in _INPUT_NAMES for name in names):
        raise RuntimeError(f"SIMPLELAY_DONE_WATCH 입력은 outlet·mic 중에서 고릅니다: {text!r}")
    kinds = {_INPUT_NAMES[name] for name in names}
    return DoneWatchSpec(appliance, tuple(k for k in ("power", "beep") if k in kinds))


class ApplianceDoneWatch:
    """두 입력 검출기와 융합을 묶는다. ``feed_power``·``feed_audio``·``poll``은 어느 스레드에서 불러도 된다."""

    def __init__(
        self,
        spec: DoneWatchSpec,
        emit: Callable[[dict], None],
        *,
        cycle_config: CycleEndConfig | None = None,
        beep_config: EndBeepConfig | None = None,
        fusion_config: DoneFusionConfig | None = None,
        event: str | None = None,
        power_source: str = "real",
        beep_source: str = "real",
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.spec = spec
        #: 끝 이벤트 이름(없으면 가전별 기본 — 세탁기 wash_complete · 전자레인지 heat_complete).
        self.event = event or done_event_for(spec.appliance_id)
        self._emit = emit
        self._clock = clock
        self._lock = threading.Lock()
        self._cycle = CycleEndTracker(cycle_config)
        self._beep = EndBeepDetector(beep_config)
        self.fusion = ApplianceDoneFusion(spec.appliance_id, expected=spec.inputs,
                                          config=fusion_config, event=self.event)
        self.power_source = power_source
        self.beep_source = beep_source
        #: 보낸 프레임 수(상태 확인용).
        self.sent = 0

    @property
    def wants_power(self) -> bool:
        return "power" in self.spec.inputs

    @property
    def wants_beep(self) -> bool:
        return "beep" in self.spec.inputs

    def feed_power(self, sample: PowerSample) -> None:
        if not self.wants_power:
            return
        with self._lock:
            cycle = self._cycle.feed(sample)
            out = None
            if cycle is not None:
                log.info("%s cycle end (power): %s", self.spec.appliance_id, cycle.detail)
                out = self.fusion.note("power", at_s=cycle.standby_from_s, now_s=self._clock(),
                                       evidence=cycle.as_dict(), source=self.power_source)
            out = out or self.fusion.poll(self._clock())
        self._send(out)

    def note_power_gap(self) -> None:
        with self._lock:
            self._cycle.note_gap()

    def feed_audio(self, pcm: np.ndarray, t: float) -> None:
        if not self.wants_beep:
            return
        with self._lock:
            match = self._beep.process_frame(pcm, t)
            out = None
            if match is not None:
                log.info("washer end beep: %d beeps, period %.2fs", match.beeps, match.mean_period_s)
                out = self.fusion.note("beep", at_s=match.last_onset_s, now_s=self._clock(),
                                       evidence=match.as_dict(), source=self.beep_source)
            out = out or self.fusion.poll(self._clock())
        self._send(out)

    def poll(self) -> None:
        with self._lock:
            out = self.fusion.poll(self._clock())
        self._send(out)

    def _send(self, event) -> None:
        if event is None:
            return
        frame = event.to_frame(time.monotonic_ns())
        log.warning("appliance done → RPi5: %s %s inputs=%s source=%s", event.appliance_id, event.state,
                    ",".join(event.inputs), event.source)
        self.sent += 1
        try:
            self._emit(frame)
        except Exception:  # noqa: BLE001 - 보고 실패가 관찰 스레드를 죽이지 않게
            log.exception("appliance_done emit failed")


class PowerCycleFeeder:
    """콘센트 모듈 전력 스트림(CT 채널 하나) → 관찰. 릴레이·명령을 보내지 않는다(읽기만).

    ``link``는 `OutletLink`(채널 0) 또는 `OutletLink.channel(ch)` 보기다."""

    def __init__(self, link: OutletLink, watch: ApplianceDoneWatch, *, retry_s: float = 0.5) -> None:
        self._link = link
        #: 읽는 CT 채널(상태 확인·시험용).
        ch = getattr(link, "channel", 0)  # OutletLink.channel은 보기를 만드는 메서드 → 채널 0
        self.channel = ch if isinstance(ch, int) else 0
        self._watch = watch
        self._retry_s = retry_s
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name=f"appliance-done-power-{watch.spec.appliance_id}")

    def start(self) -> "PowerCycleFeeder":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()

    def join(self, timeout: float | None = None) -> bool:
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def _run(self) -> None:
        sensor = self._link.sensor()
        while not self._stop.is_set():
            try:
                sample = sensor.read()
            except PowerSensorStale as exc:
                log.warning("appliance done watch: power stream stale — %s", exc)
                self._watch.note_power_gap()
                self._watch.poll()
                if self._stop.wait(self._retry_s):
                    return
                sensor = self._link.sensor()
                continue
            except Exception:  # noqa: BLE001
                log.exception("appliance done watch: power read failed")
                if self._stop.wait(self._retry_s):
                    return
                continue
            self._watch.feed_power(sample)
