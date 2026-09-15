"""L1~L3 단계별 실행 검증 — 층마다 다른 복구 정책의 계약.

L1(눌렀는가)은 기존 ``rpi.verifier.Verifier``가 버튼마다 판정한다. 이 모듈은
그 위에 두 층을 더한다.

- L2 ``AcceptanceVerifier``: 누른 직후 가전이 입력을 받아들였는가
  (조작음·표시 변화). 실패하면 같은 입력을 정해진 횟수만큼 다시 넣는다.
- L3 ``OperationVerifier``: 시퀀스를 다 넣은 뒤 가전이 실제로 동작하는가
  (소비 전력 상승 등). 실패하면 **자동으로 다시 누르지 않는다** -- 이미 일부
  설정이 들어간 가전에 입력이 겹칠 수 있어서, 멈추고 사람에게 넘긴다.

두 검증기는 선택이다. 주지 않으면 컨트롤러는 L1만 쓰는 종전 동작과 같다
(센서가 없는 가전·하드웨어 도착 전 구성). 판정 임계값은 각 구현(예:
``rpi/verifier/power.py``)의 몫이고 여기서는 정책만 정한다.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from collections import deque
from collections.abc import Iterable

from .models import LayerOutcome, VerificationLayer

#: L2 불수용 시 같은 입력을 다시 넣는 횟수. 한 번이면 타이밍 문제는 대개
#: 풀리고, 그 이상은 잠금·모드 문제라 누를수록 상태만 어긋난다.
DEFAULT_ACCEPTANCE_REINPUTS = 1


class AcceptanceVerifier(ABC):
    """L2 — 가전이 방금 입력을 받아들였나."""

    @abstractmethod
    def verify_acceptance(self, button: str) -> LayerOutcome:
        """``layer``는 반드시 ACCEPTANCE여야 한다."""


class OperationVerifier(ABC):
    """L3 — 시퀀스를 넣은 뒤 가전이 실제로 동작하나."""

    @abstractmethod
    def verify_operation(self, buttons: tuple[str, ...]) -> LayerOutcome:
        """``layer``는 반드시 OPERATION이어야 한다."""


def _outcome(item: LayerOutcome | bool, layer: VerificationLayer) -> LayerOutcome:
    if isinstance(item, LayerOutcome):
        return item
    return LayerOutcome(layer, bool(item), "injected mock outcome")


class MockAcceptanceVerifier(AcceptanceVerifier):
    """주입한 결과를 순서대로 돌려준다 -- 실제 센서를 읽지 않는다."""

    def __init__(self, outcomes: Iterable[LayerOutcome | bool]) -> None:
        self._outcomes = deque(
            _outcome(o, VerificationLayer.ACCEPTANCE) for o in outcomes
        )
        self.calls: list[str] = []

    def verify_acceptance(self, button: str) -> LayerOutcome:
        self.calls.append(button)
        if not self._outcomes:
            raise RuntimeError("MockAcceptanceVerifier scenario has no outcome left")
        return self._outcomes.popleft()


class MockOperationVerifier(OperationVerifier):
    """주입한 결과를 순서대로 돌려준다 -- 실제 센서를 읽지 않는다."""

    def __init__(self, outcomes: Iterable[LayerOutcome | bool]) -> None:
        self._outcomes = deque(
            _outcome(o, VerificationLayer.OPERATION) for o in outcomes
        )
        self.calls: list[tuple[str, ...]] = []

    def verify_operation(self, buttons: tuple[str, ...]) -> LayerOutcome:
        self.calls.append(tuple(buttons))
        if not self._outcomes:
            raise RuntimeError("MockOperationVerifier scenario has no outcome left")
        return self._outcomes.popleft()
