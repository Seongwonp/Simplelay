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

    def verify_operation(self, buttons: tuple[str, ...]) -> LayerOutcome:
        detector = PowerSignatureDetector(self._config)
        first = self._sensor.read()
        detector.feed(first)
        since_s = first.t_s
        last_t = first.t_s
        for _ in range(self._max_polls):
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
