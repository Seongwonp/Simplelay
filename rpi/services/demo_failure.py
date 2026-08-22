"""데모 실패 주입 — 결선 핵심 장면("일부러 실패시켜도 스스로 재시도")의 연출 장치.

실제 하드웨어에서 버튼을 빗맞게 만드는 것은 재현이 어렵고 운에 좌우된다.
``POST /demo/inject-failure``로 무장(arm)하면 다음 실행에서 지정한 버튼 슬롯의
검증이 지정 횟수만큼 강제 실패한다:

- attempts 1~2 (재시도 한도 3 미만): 실패 → 폐루프 보정 재시도 → 성공 장면
- attempts 3 이상: 재시도 소진 → 안전 정지 장면

verifier 래퍼라 mock/실센서 어느 쪽 위에도 끼울 수 있다. 1회용 — 소진되면
자동 해제되어 다음 실행은 정상 동작한다. 현재는 로컬(ClosedLoop) 경로에만
배선되어 있다: UART 모드는 검증이 RPi4에서 일어나므로 실기기 데모에서
쓰려면 rpi4/act_main.py에도 같은 래퍼 + 무장 채널(UART 메시지)이 필요하다.
"""

from __future__ import annotations

import threading
from dataclasses import dataclass

from rpi.verifier import VerificationResult, Verifier


@dataclass(frozen=True)
class FailurePlan:
    button_index: int
    attempts: int


class DemoFailureState:
    """API 레이어(무장)와 verifier 래퍼(소비)가 공유하는 스레드 안전 상태.

    슬롯 인덱스는 '검증에 성공한 버튼 수'로 센다 — 폐루프가 같은 버튼을
    재시도하면 verify가 같은 슬롯으로 반복 호출되므로, 성공했을 때만 다음
    슬롯으로 넘어가는 것이 시퀀스상 버튼 인덱스와 일치한다. arm() 시점에
    슬롯 카운터를 리셋한다(무장은 실행 직전에 하는 데모 절차 전제).
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._plan: FailurePlan | None = None
        self._slot = 0

    def arm(self, button_index: int, attempts: int) -> None:
        with self._lock:
            self._plan = FailurePlan(button_index, attempts)
            self._slot = 0

    def disarm(self) -> None:
        with self._lock:
            self._plan = None

    def current(self) -> FailurePlan | None:
        with self._lock:
            return self._plan

    def should_fail_current(self) -> bool:
        """현재 슬롯의 이번 검증을 실패시켜야 하면 True + 남은 횟수 차감."""
        with self._lock:
            plan = self._plan
            if plan is None or self._slot != plan.button_index:
                return False
            if plan.attempts <= 1:
                self._plan = None  # 소진 — 자동 해제(1회용)
            else:
                self._plan = FailurePlan(plan.button_index, plan.attempts - 1)
            return True

    def note_result(self, pressed: bool) -> None:
        with self._lock:
            if pressed:
                self._slot += 1


class FailureInjectionVerifier(Verifier):
    """실제 verifier 앞단에서 데모 실패를 끼워 넣는 래퍼."""

    def __init__(self, inner: Verifier, state: DemoFailureState) -> None:
        self._inner = inner
        self._state = state

    def verify(self, button: str) -> VerificationResult:
        if self._state.should_fail_current():
            result = VerificationResult(False, 0.0, f"데모 실패 주입: {button}")
            self._state.note_result(False)
            return result
        result = self._inner.verify(button)
        self._state.note_result(result.pressed)
        return result
