"""시나리오용 **모의** 물리 가전 실행기 (예: 저녁 휴식의 선풍기).

실물 선풍기 노드가 아직 없다. 시나리오의 물리 단계가 "승인 → 실행 → 결과 기록"을
끝까지 돌게 하되, 결과가 사실처럼 보이지 않게 한다:

- ``execution_mode``는 MOCK -- 이력·통계에서 실제와 섞이지 않는다.
- 버튼별 센서 판정(verification)이 없다 -- 결과 매핑이 ``reported``(보고만 받음)가
  되고, "센서로 눌림을 확인했어요"라고 말하지 않는다.
- ``mock_ready``는 **이 모의 실행기 자신의** 준비 선언이다. 실제 노드의 준비
  상태(4축)를 대신하지 않는다.
"""

from __future__ import annotations

import threading

from rpi.controller.models import (
    ButtonResult,
    ButtonStatus,
    ExecutionMode,
    ExecutionResult,
    ExecutionStatus,
)


class MockButtonController:
    execution_mode = ExecutionMode.MOCK
    mock_ready = True

    def __init__(self) -> None:
        self._stop = threading.Event()
        self.executed: list[tuple[str, ...]] = []

    def reset_stop(self) -> None:
        self._stop.clear()

    def request_stop(self) -> None:
        self._stop.set()
        return None  # 수신 확인 수단 없음 -> 미확인으로 집계된다

    def execute(self, buttons, targets=None) -> ExecutionResult:
        self.executed.append(tuple(buttons))
        results = []
        for label in buttons:
            if self._stop.is_set():
                return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, tuple(results))
            results.append(ButtonResult(label, ButtonStatus.SUCCEEDED, 1, None))
        return ExecutionResult(ExecutionStatus.SUCCEEDED, tuple(results))
