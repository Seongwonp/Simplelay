"""L3 동작 확인 어댑터 — 전력 파형 판정기(rpi/verifier/power.py)를 컨트롤러에 꽂는다.

``ClosedLoopController(operation=PowerOperationVerifier(sensor))``로 쓰면, 시퀀스를
다 넣은 뒤 소비 전력이 실제로 올라가는지 확인하고, 확인되지 않으면 컨트롤러가
자동 재입력 없이 안전 정지한다(layered.py 정책).

센서는 ``PowerSensor`` 프로토콜이면 무엇이든 된다. 실물 CT(ADS1115) 샘플링
드라이버는 하드웨어 도착 후 붙인다 -- 지금은 리허설·테스트용 MockPowerSensor만 있다.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from rpi.verifier.power import PowerConfig, PowerSensor, PowerSignatureDetector

from .layered import OperationVerifier
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
        self._since_s: float | None = None
        self._stop_check: Callable[[], bool] | None = None

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
        detector = PowerSignatureDetector(self._config)
        first = self._sensor.read()
        detector.feed(first)
        last = first
        for _ in range(self._max_polls):
            if last.t_s - first.t_s >= self._config.baseline_window_s:
                break
            self._sleep(self._poll_interval_s)
            last = self._sensor.read()
            detector.feed(last)
        self._detector = detector
        self._since_s = last.t_s

    def verify_operation(self, buttons: tuple[str, ...]) -> LayerOutcome:
        detector = self._detector
        since_s = self._since_s
        if detector is None or since_s is None:
            # begin_observation 없이 불린 경우(옛 배선·단독 호출). 조작 전
            # 샘플이 없어 기준선을 만들 수 없다는 사실은 판정기가 사유로 말한다.
            detector = PowerSignatureDetector(self._config)
            first = self._sensor.read()
            detector.feed(first)
            since_s = first.t_s
        try:
            return self._poll_until_verdict(detector, since_s)
        finally:
            # 다음 실행이 지난 관측을 물려받지 않게 비운다.
            self._detector = None
            self._since_s = None

    def _poll_until_verdict(
        self, detector: PowerSignatureDetector, since_s: float
    ) -> LayerOutcome:
        last_t = since_s
        for _ in range(self._max_polls):
            if self._stop_check is not None and self._stop_check():
                return LayerOutcome(
                    VerificationLayer.OPERATION,
                    False,
                    "정지 요청으로 동작 확인을 중단함",
                )
            verdict = detector.verify_started(since_s=since_s)
            if verdict.confirmed or verdict.detail != _PENDING_DETAIL:
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
