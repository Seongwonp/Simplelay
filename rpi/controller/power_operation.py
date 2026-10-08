"""L3 동작 확인 어댑터 — 전력 파형 판정기(rpi/verifier/power.py)를 컨트롤러에 꽂는다.

``ClosedLoopController(operation=PowerOperationVerifier(sensor))``로 쓰면, 시퀀스를
다 넣은 뒤 소비 전력이 실제로 올라가는지 확인하고, 확인되지 않으면 컨트롤러가
자동 재입력 없이 안전 정지한다(layered.py 정책).

센서는 ``PowerSensor`` 프로토콜이면 무엇이든 된다. 실물 입력은 ESP32 콘센트 모듈의 줄 단위
JSON 전력 스트림(`rpi/verifier/outlet.py` `SerialPowerSensor`, 2026-10-05 — **실물 미검증**,
가짜 출력으로만 시험)이고, 리허설·테스트용으로 MockPowerSensor가 있다.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from rpi.verifier.power import (
    L3Verdict,
    OperationPhase,
    PowerConfig,
    PowerSensor,
    PowerSignatureDetector,
)

from .layered import OPERATION_STOPPED_DETAIL, OperationVerifier
from .models import LayerOutcome, VerificationLayer

_PENDING_DETAIL = "판정 대기"


class PowerOperationVerifier(OperationVerifier):
    """샘플을 읽어 판정이 날 때까지 기다린다 -- 상한이 있다.

    ``max_polls``를 두는 이유: 센서가 멈춰 같은 샘플만 돌려주면 판정기의
    시간이 흐르지 않아 시작 제한시간에 영원히 닿지 않는다. 그때는 '확인
    못 함'으로 끝내야 한다 -- 확인 못 한 것을 통과시키지 않는다.
    """

    def __init__(
        self,
        sensor: PowerSensor,
        config: PowerConfig | None = None,
        *,
        poll_interval_s: float = 0.1,
        max_polls: int = 200,
        sleep: Callable[[float], None] | None = None,
    ) -> None:
        if max_polls < 1:
            raise ValueError("max_polls must be at least 1")
        self._sensor = sensor
        self._config = config or PowerConfig()
        self._poll_interval_s = poll_interval_s
        self._max_polls = max_polls
        self._sleep = sleep or time.sleep
        # 누르기 전에 잡아 둔 기준선 관측(begin_observation). 없으면 조작
        # 이전 샘플이 하나도 없다는 뜻이라, 판정기가 '기준선 없음'이라고 말한다.
        self._detector: PowerSignatureDetector | None = None
        # 판정 기준 시각. 누름을 알려 오면(note_press) 마지막 단계의 첫 누름
        # 직전 시각, 아니면 기준선 관측이 끝난 시각(옛 배선).
        self._since_s: float | None = None
        # 마지막 단계의 첫 누름 직전에 전력이 이미 올라가 있었나.
        self._up_before_final_step = False
        self._stop_check: Callable[[], bool] | None = None
        #: 마지막 verify_operation의 판정기 결과(기준선·최대 전력). 잔여 전류 꼬리 측정이
        #: 사용 전 기준선으로 쓴다. 판정이 없었으면 None.
        self.last_verdict: L3Verdict | None = None

    def set_stop_check(self, should_stop: Callable[[], bool]) -> None:
        self._stop_check = should_stop

    def begin_observation(self) -> None:
        """첫 누름 전에 기준선 구간을 채운다.

        판정기의 기준선은 **상승 직전 대기 샘플의 중앙값**이다. 누른 뒤부터
        읽기 시작하면 그 구간이 통째로 비어, 실제로 가전이 돌기 시작해도
        '기준선 없음'으로 실패한다. L3는 자동 재시도가 없는 층이라 이 오판정은
        곧바로 안전 정지와 사람 호출로 이어진다.

        대기 시간은 기준선 창(``baseline_window_s``)까지다. 센서가 시각을
        진전시키지 못하면 폴링 상한에서 끊고, 모은 만큼만 기준선으로 쓴다.
        """
        retain = getattr(self._sensor, "retain_observation", None)
        if callable(retain):
            retain(False)
        detector = PowerSignatureDetector(self._config)
        first = self._sensor.read()
        detector.feed(first)
        last = first
        for _ in range(self._max_polls):
            if last.t_s - first.t_s >= self._config.baseline_window_s:
                break
            # 기준선을 모으는 동안에도 정지 요청을 본다 -- 여기서 기다리면
            # 아직 누르기 전인데도 정지 처리가 그만큼 늦어진다.
            if self._stop_check is not None and self._stop_check():
                break
            self._sleep(self._poll_interval_s)
            last = self._sensor.read()
            detector.feed(last)
        self._detector = detector
        self._since_s = last.t_s
        self._up_before_final_step = False
        if callable(retain):
            retain(True)

    def note_press(self, button: str, press_number: int) -> None:
        """누르기 직전 샘플을 하나 읽어 판정기에 이어 넣는다.

        - 기준선: 기구가 이동·누르는 동안에는 샘플이 비는데, 누르기 직전 샘플이
          있어야 그 직후 오른 전력을 '상승'으로 볼 수 있다.
          모션 어댑터는 자동 원점·XY 이동을 끝낸 뒤 Z 명령 직전에 이 훅을 부른다.
          L3 시작 제한시간은 이 시각 기준이며, L1 전류 max_window_s(30초)와 별개다.
        - 기준 시각: 단계의 **첫** 누름에서만 옮긴다. 첫 누름이 실제로 들어가
          전력이 오르는 중에 L1이 재시도해도, 그 상승은 이 단계의 결과다.
        - 이미 동작 중: 단계의 첫 누름 직전인데 전력이 벌써 오르고 있으면, 뒤에
          확인되는 동작은 이번 조작의 결과로 볼 수 없다. 단계가 바뀔 때마다 다시
          판단하므로 결국 마지막 단계의 상태가 남는다.
        """
        detector = self._detector
        if detector is None:
            detector = PowerSignatureDetector(self._config)
            self._detector = detector
        pending = getattr(self._sensor, "pending_observation", None)
        samples = pending() if callable(pending) else []
        if not samples:
            samples = [self._sensor.read()]
        for sample in samples:
            detector.feed(sample)
        if press_number == 1:
            self._since_s = sample.t_s
            self._up_before_final_step = detector.phase is not OperationPhase.IDLE

    def verify_operation(self, buttons: tuple[str, ...]) -> LayerOutcome:
        detector = self._detector
        since_s = self._since_s
        self.last_verdict = None
        try:
            if self._up_before_final_step:
                return LayerOutcome(
                    VerificationLayer.OPERATION,
                    False,
                    "마지막 단계를 누르기 전부터 전력이 이미 올라가 있어 "
                    "이번 조작의 결과로 볼 수 없음",
                )
            # 주의: 컨트롤러 없이 단독으로 부르면(note_press 없음) 기준 시각은
            # 관측이 끝난 시각이라, 그 뒤 누르는 데 걸린 시간이 제한시간에 들어간다.
            # 실행 경로는 ClosedLoopController가 누를 때마다 note_press를 부른다.
            if detector is None or since_s is None:
                # begin_observation 없이 불린 경우(옛 배선·단독 호출). 조작 전
                # 샘플이 없어 기준선을 만들 수 없다는 사실은 판정기가 사유로 말한다.
                detector = PowerSignatureDetector(self._config)
                first = self._sensor.read()
                detector.feed(first)
                since_s = first.t_s
            return self._poll_until_verdict(detector, since_s)
        finally:
            retain = getattr(self._sensor, "retain_observation", None)
            if callable(retain):
                retain(False)
            # 다음 실행이 지난 관측을 물려받지 않게 비운다.
            self._detector = None
            self._since_s = None
            self._up_before_final_step = False

    def _poll_until_verdict(
        self, detector: PowerSignatureDetector, since_s: float
    ) -> LayerOutcome:
        last_t = since_s
        for _ in range(self._max_polls):
            if self._stop_check is not None and self._stop_check():
                return LayerOutcome(
                    VerificationLayer.OPERATION,
                    False,
                    OPERATION_STOPPED_DETAIL,
                )
            verdict = detector.verify_started(since_s=since_s)
            if verdict.confirmed or verdict.detail != _PENDING_DETAIL:
                self.last_verdict = verdict
                return LayerOutcome(
                    VerificationLayer.OPERATION, verdict.confirmed, verdict.detail
                )
            self._sleep(self._poll_interval_s)
            sample = self._sensor.read()
            detector.feed(sample)
            last_t = max(last_t, sample.t_s)
        return LayerOutcome(
            VerificationLayer.OPERATION,
            False,
            f"전력 샘플이 판정 시간({last_t - since_s:.1f}초) 안에 끝나지 않아 "
            "동작을 확인하지 못함",
        )


# ── L3 배선 모드(SIMPLELAY_L3_MODE) ─────────────────────────────────────────
#
# off(기본)  L3 검증기 없음 -- 결과의 operation은 None(판정기 없음).
# mock       MockPowerSensor 합성 파형으로 판정한다. 결과는 ``mock=True``라 통과해도
#            확인 수준을 operation_confirmed로 올리지 않는다(실제 가열 근거 아님).
#            SIMPLELAY_L3_MOCK_OUTCOME=confirmed(기본) | unconfirmed.
# real       ESP32 콘센트 모듈의 전력 스트림으로 판정한다(SIMPLELAY_OUTLET_PORT·_BAUD, 2026-10-05).
#            포트가 없으면 **시작을 거절한다** -- 있는 척하지 않는다. 포트가 ``fake``면 가짜 출력
#            (rpi/tools/fake_outlet.py)이라 판정은 ``mock=True``로 표시한다.

L3_MODES = ("off", "mock", "real")
L3_MOCK_OUTCOMES = ("confirmed", "unconfirmed")

REAL_L3_UNAVAILABLE = (
    "SIMPLELAY_L3_MODE=real: 콘센트 모듈(ESP32 CT 전력) 연결 설정이 아직 없습니다 — "
    "SIMPLELAY_OUTLET_PORT와 SIMPLELAY_OUTLET_BAUD를 주세요(리허설은 SIMPLELAY_OUTLET_PORT=fake). "
    "모듈이 없으면 off 또는 mock으로 실행하세요"
)
REAL_L3_NOT_WIRED = (
    "SIMPLELAY_L3_MODE=real: SIMPLELAY_OUTLET_PORT는 있는데 콘센트 모듈 링크가 배선되지 않았습니다 "
    "(호출하는 쪽이 OutletLink를 넘겨야 합니다)"
)

_FAKE_OUTLET_PREFIX = "모의 콘센트(가짜 출력) — "


class OutletOperationVerifier(PowerOperationVerifier):
    """콘센트 모듈 전력 스트림으로 L3를 판정한다 -- **실물 미검증**.

    판정 규칙은 `PowerOperationVerifier` 그대로이고 입력만 `SerialPowerSensor`다. 링크가 가짜 출력
    (``link.mock``)이면 결과를 ``mock=True``로 표시해 실제 동작 근거로 올리지 않는다.
    ``on_sequence_done``은 시퀀스를 다 넣은 직후(판정 대기 전) 부른다 -- 가짜 출력 리허설이 그 순간
    합성 가전을 돌리는 데만 쓴다. 실물에서는 None이다.
    """

    def __init__(self, link, config: PowerConfig | None = None, *,
                 on_sequence_done: Callable[[], None] | None = None, **kwargs) -> None:
        super().__init__(link.sensor(), config, **kwargs)
        self.link = link
        self.mock = bool(getattr(link, "mock", False))
        self.source = "mock" if self.mock else "real"
        self._on_sequence_done = on_sequence_done

    def verify_operation(self, buttons: tuple[str, ...]) -> LayerOutcome:
        if self._on_sequence_done is not None:
            self._on_sequence_done()
        verdict = super().verify_operation(buttons)
        if not self.mock or verdict.detail == OPERATION_STOPPED_DETAIL:
            return verdict
        return LayerOutcome(verdict.layer, verdict.passed, _FAKE_OUTLET_PREFIX + verdict.detail, mock=True)

_MOCK_PREFIX = "모의 전력 센서 — "


class _SwitchablePowerSensor:
    """대기 전력을 흘리다가 ``start()`` 뒤로는 MockPowerSensor(합성 전자레인지 파형)를 읽는다.

    시각은 가상(10 Hz 한 칸씩)이라 실제로 기다리지 않는다. 합성 입력이다 -- 실측이 아니다.
    """

    def __init__(self, *, idle_w: float = 3.0, run_w: float = 1200.0, hz: float = 10.0) -> None:
        self._idle_w = idle_w
        self._run_w = run_w
        self._hz = hz
        self._t = 0.0
        self._running = None

    def start(self) -> None:
        from rpi.verifier.power import MockPowerSensor, PowerSample, microwave_profile

        t0 = self._t
        profile = microwave_profile(idle_w=self._idle_w, run_w=self._run_w, run_s=30.0,
                                    hz=self._hz, start_at_s=0.0, tail_s=0.0)
        self._running = MockPowerSensor([PowerSample(t0 + s.t_s, s.watts) for s in profile])

    def read(self):
        from rpi.verifier.power import PowerSample

        if self._running is not None:
            return self._running.read()
        sample = PowerSample(self._t, self._idle_w)
        self._t += 1.0 / self._hz
        return sample


class MockPowerOperationVerifier(OperationVerifier):
    """리허설용 L3 -- 실행마다 새 합성 센서로 ``PowerOperationVerifier``를 돌린다.

    ``outcome="confirmed"``면 시퀀스를 다 넣은 뒤 합성 파형이 올라가고(판정기가 실제로
    '시작 확정'을 낸다), ``"unconfirmed"``면 대기 전력만 흘러 시작 제한시간에 '확인 못 함'이
    난다. 판정 규칙은 실물과 같은 ``PowerSignatureDetector``이고 입력만 합성이다.
    결과는 ``mock=True``로 표시한다.
    """

    def __init__(self, outcome: str = "confirmed", config: PowerConfig | None = None) -> None:
        if outcome not in L3_MOCK_OUTCOMES:
            raise ValueError(f"L3 mock outcome must be one of {L3_MOCK_OUTCOMES}: {outcome!r}")
        self.outcome = outcome
        self._config = config
        self._stop_check: Callable[[], bool] | None = None
        self._sensor: _SwitchablePowerSensor | None = None
        self._inner: PowerOperationVerifier | None = None

    def set_stop_check(self, should_stop: Callable[[], bool]) -> None:
        self._stop_check = should_stop

    def begin_observation(self) -> None:
        self._sensor = _SwitchablePowerSensor()
        self._inner = PowerOperationVerifier(self._sensor, self._config, sleep=lambda _s: None)
        if self._stop_check is not None:
            self._inner.set_stop_check(self._stop_check)
        self._inner.begin_observation()

    def note_press(self, button: str, press_number: int) -> None:
        if self._inner is None:
            self.begin_observation()
        self._inner.note_press(button, press_number)

    def verify_operation(self, buttons: tuple[str, ...]) -> LayerOutcome:
        if self._inner is None:
            self.begin_observation()
        if self.outcome == "confirmed":
            self._sensor.start()
        try:
            verdict = self._inner.verify_operation(buttons)
        finally:
            self._inner = None
            self._sensor = None
        if verdict.detail == OPERATION_STOPPED_DETAIL:
            return verdict  # 정지 사유는 컨트롤러가 그대로 알아봐야 한다
        return LayerOutcome(verdict.layer, verdict.passed, _MOCK_PREFIX + verdict.detail, mock=True)


def operation_verifier_from_env(env=None, *, outlet=None,
                                on_sequence_done: Callable[[], None] | None = None,
                                config: PowerConfig | None = None) -> OperationVerifier | None:
    """``SIMPLELAY_L3_MODE``로 L3 검증기를 고른다. 모르는 값은 시작을 거절한다.

    real은 콘센트 모듈 링크(``outlet``, `rpi.verifier.outlet.OutletLink`)가 있어야 한다.
    ``SIMPLELAY_OUTLET_PORT``가 없으면 `REAL_L3_UNAVAILABLE`로 거절한다(종전과 같다).
    """
    import os

    env = os.environ if env is None else env
    mode = (env.get("SIMPLELAY_L3_MODE", "off") or "off").strip().lower() or "off"
    if mode not in L3_MODES:
        raise RuntimeError(f"unknown SIMPLELAY_L3_MODE={mode!r} ({' | '.join(L3_MODES)})")
    if mode == "off":
        return None
    if mode == "real":
        port = (env.get("SIMPLELAY_OUTLET_PORT") or "").strip()
        if not port:
            raise RuntimeError(REAL_L3_UNAVAILABLE)
        if outlet is None:
            raise RuntimeError(REAL_L3_NOT_WIRED)
        return OutletOperationVerifier(outlet, config, on_sequence_done=on_sequence_done)
    outcome = (env.get("SIMPLELAY_L3_MOCK_OUTCOME", "confirmed") or "confirmed").strip().lower()
    if outcome not in L3_MOCK_OUTCOMES:
        raise RuntimeError(
            f"unknown SIMPLELAY_L3_MOCK_OUTCOME={outcome!r} ({' | '.join(L3_MOCK_OUTCOMES)})"
        )
    return MockPowerOperationVerifier(outcome)
