"""콘센트 모듈(ESP32 CT·릴레이)을 실행기에 잇는 부품 — **실물 미검증**, 가짜 출력으로만 시험(2026-10-05).

- `PowerTailWatch`: L3가 동작 시작을 확인한 실행 뒤, 같은 전력 스트림을 따라가며 완료 판정 →
  잔여 전류 꼬리(피드백 ③)를 잰다. 끝나면 ``progress {phase:"power_tail", power_tail:{…}}`` 프레임과
  원시 기록기 ``power_tail`` 행으로 남긴다. **기록이지 판정이 아니다** — 결과로 아무것도 움직이지 않는다.
- `OutletTailHook`: 실행기(`ActExecutor`)의 ``after_result`` 훅. L3 확인 성공일 때만 관찰을 띄우고,
  새 실행·종료 때 이전 관찰을 멈춘다.
- `OutletRunProbe`: 정지 대기(`stop_hold.StopHoldSession`)의 가전 켜짐/꺼짐 확인. 최신 전력이
  ``off_max_w`` 넘으면 켜짐, 이하면 꺼짐, 스트림이 끊기면 모름(None) — 0 W로 대신하지 않는다.

임계값은 `rpi/verifier/power_tail.py` `TailConfig`(전부 측정 필요)를 함께 쓴다.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable
from typing import Any

from rpi.verifier.outlet import OutletLink, PowerSensorStale
from rpi.verifier.power_tail import PowerTailTracker, TailConfig, TailMetrics

log = logging.getLogger(__name__)


class PowerTailWatch:
    """배경 스레드 하나가 센서 뷰를 읽어 꼬리를 잰다. ``on_done(metrics)``을 한 번 부른다."""

    def __init__(
        self,
        sensor: Any,
        pre_baseline_w: float | None,
        on_done: Callable[[TailMetrics], None],
        *,
        config: TailConfig | None = None,
        source: str = "real",
    ) -> None:
        self._sensor = sensor
        self._tracker = PowerTailTracker(pre_baseline_w, config)
        self._on_done = on_done
        self._source = source
        self._stop = threading.Event()
        self.metrics: TailMetrics | None = None
        self._thread = threading.Thread(target=self._run, daemon=True, name="power-tail")

    def start(self) -> "PowerTailWatch":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()

    def join(self, timeout: float | None = None) -> bool:
        self._thread.join(timeout)
        return not self._thread.is_alive()

    def _run(self) -> None:
        status: str | None = None
        try:
            while not self._tracker.done:
                if self._stop.is_set():
                    status = "stopped"
                    break
                try:
                    sample = self._sensor.read()
                except PowerSensorStale as exc:
                    log.warning("power tail watch: sensor stale — %s", exc)
                    status = "stale"
                    break
                self._tracker.feed(sample)
        except Exception:  # noqa: BLE001 - 기록 경로 고장이 실행기를 죽이지 않게
            log.exception("power tail watch failed")
            status = "stale"
        self.metrics = self._tracker.metrics(None if self._tracker.done else status, source=self._source)
        try:
            self._on_done(self.metrics)
        except Exception:  # noqa: BLE001
            log.exception("power tail report failed")


class OutletTailHook:
    """`ActExecutor(after_result=…)`로 꽂는다. L3 판정기(`OutletOperationVerifier`)의 마지막 기준선을 쓴다."""

    def __init__(
        self,
        link: OutletLink,
        operation: Any,
        *,
        config: TailConfig | None = None,
        recorder: Any = None,
    ) -> None:
        self._link = link
        self._operation = operation
        self._config = config or TailConfig()
        self._recorder = recorder
        self.watch: PowerTailWatch | None = None

    def stop(self) -> None:
        watch = self.watch
        if watch is not None:
            watch.stop()

    def __call__(self, sequence_id: str, result: Any, emit: Callable[[dict], None]) -> None:
        self.stop()
        operation = getattr(result, "operation", None)
        if operation is None or not operation.passed:
            return  # 동작 시작이 확인되지 않은 실행에는 꼬리가 없다
        verdict = getattr(self._operation, "last_verdict", None)
        pre = getattr(verdict, "baseline_w", None)
        source = "mock" if getattr(self._link, "mock", False) else "real"

        def on_done(metrics: TailMetrics) -> None:
            doc = metrics.as_dict()
            log.info("power tail for %s: %s", sequence_id, metrics.detail)
            if self._recorder is not None:
                try:
                    self._recorder.record_power_tail(doc, note=f"sequence_id={sequence_id}")
                except Exception:  # noqa: BLE001
                    log.exception("recorder power_tail row failed")
            emit({"power_tail": doc, "operation_source": source})

        self.watch = PowerTailWatch(self._link.sensor(), pre, on_done, config=self._config,
                                    source=source).start()


class OutletRunProbe:
    """정지 대기용 켜짐/꺼짐 확인 — 콘센트 모듈 최신 전력. 끊기면 None(모름)."""

    def __init__(self, link: OutletLink, config: TailConfig | None = None) -> None:
        cfg = config or TailConfig()
        self._link = link
        self._off_max_w = cfg.off_max_w
        self._off_confirm_s = cfg.off_confirm_s
        self.source = "mock" if getattr(link, "mock", False) else "real"

    def start(self) -> None:
        return None

    def running(self) -> bool | None:
        """꺼짐은 ``off_confirm_s`` 동안 계속 ``off_max_w`` 이하일 때만 — 인버터 가전의 출력 주기
        하강 한 번으로 '끝남'이 되지 않게. 그 구간 기록이 모자라면 아직 켜짐으로 본다."""
        if self._link.is_stale():
            return None
        latest = self._link.latest()
        if latest is None:
            return None
        horizon = latest.t_s - self._off_confirm_s
        recent = self._link.samples_since(horizon - 1.0)
        if any(s.watts > self._off_max_w for s in recent if s.t_s >= horizon - 1e-6):
            return True
        # 꺼짐 구간이 off_confirm_s를 덮는지: 그 시작 시각 이전(또는 같은) 샘플이 있어야 한다.
        return not any(s.t_s <= horizon + 1e-6 for s in recent)

    def note_stop_presses(self, count: int) -> None:
        return None
