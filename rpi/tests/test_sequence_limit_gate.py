"""실행 상한은 비동기 실행의 합류점(`_submit`)에서 검사한다.

동기 실행(`_execute_via_resolver`)만 해석 결과의 개수·바이트 상한을 다시
검사하고 있었다. 실제 HTTP 경로인 `/execute`와 제안 승인은
`submit_purpose → _submit`으로 내려가 검사를 지나치지 않았다. LLM 해석을
켠 구성에서 모델이 폭주하면 상한 없는 물리 실행이 된다.

진입점마다 검사를 붙이면 진입점이 늘 때 같은 구멍이 다시 생긴다(R1과 같은
교훈) — 모든 비동기 실행이 지나는 한 곳에서 거절한다.

거절했을 때의 기준은 하나다: **mock 컨트롤러 호출 0, 실행 상태 남지 않음.**
"""

from datetime import datetime, timedelta, timezone

import pytest

from rpi.api import SimpleLayService
from rpi.api.schemas import MAX_BUTTON_LABEL_LEN, MAX_BUTTONS_PER_RUN
from rpi.controller import ClosedLoopController
from rpi.controller.mock import (
    MockAlertSink,
    MockGrblClient,
    MockRetryWaiter,
    MockSafetyController,
)
from rpi.intent import ProactiveSuggestionService, RuleBasedIntentResolver
from rpi.intent.mock import FixedClock, MockLlmClient
from rpi.intent.rules import UnknownIntentError
from rpi.verifier import MockVerifier

KST = timezone(timedelta(hours=9))
_NOW = datetime(2026, 7, 23, 19, 0, tzinfo=KST)

_TOO_MANY = ["시작"] * (MAX_BUTTONS_PER_RUN + 1)
# 개수는 상한 안이지만 바이트 예산을 넘는다. 40자 한글 20개는 예산 안에
# 들어오도록 설계됐으므로(schemas 주석), 요청 스키마의 라벨 길이 검사를
# 거치지 않는 해석 결과 — 상한보다 긴 라벨 — 로 넘긴다.
_LONG_LABEL = "가" * (MAX_BUTTON_LABEL_LEN + 10)
_TOO_LARGE = [_LONG_LABEL] * MAX_BUTTONS_PER_RUN


class _FixedResolver:
    """해석 결과를 그대로 돌려주는 대역 — 폭주한 LLM 해석의 자리."""

    def __init__(self, buttons: list[str]) -> None:
        self._buttons = buttons

    def resolve(self, purpose: str) -> list[str]:  # noqa: ARG002
        return list(self._buttons)


def _service(buttons: list[str]):
    grbl = MockGrblClient()
    llm_sequence = ", ".join(f'"{b}"' for b in buttons)
    service = SimpleLayService(
        _FixedResolver(buttons),
        ClosedLoopController(
            grbl,
            MockVerifier(outcomes=[True] * 200),
            MockAlertSink(),
            MockSafetyController(),
            retry_waiter=MockRetryWaiter(),
        ),
        clock=FixedClock(_NOW),
        llm_client=MockLlmClient(
            {"즉석밥 데워줘": '{"sequence": [' + llm_sequence + "]}"}
        ),
    )
    return service, grbl


_ENTRY_POINTS = [
    pytest.param(lambda s: s.submit_purpose("즉석밥 데워줘"), id="submit_purpose"),
    pytest.param(
        # 요청 스키마를 거치지 않는 호출자(내부 경로)도 같은 상한을 받는다
        lambda s: s.submit_buttons(tuple(s._intent.resolve("-"))),  # noqa: SLF001
        id="submit_buttons",
    ),
    pytest.param(
        lambda s: s.submit_purpose_for_appliance(
            "즉석밥 데워줘", frozenset({"시작", _LONG_LABEL})
        ),
        id="submit_purpose_for_appliance",
    ),
    pytest.param(
        lambda s: s.execute_buttons(tuple(s._intent.resolve("-"))),  # noqa: SLF001
        id="execute_buttons",
    ),
]


@pytest.mark.parametrize("buttons", [_TOO_MANY, _TOO_LARGE], ids=["count", "bytes"])
@pytest.mark.parametrize("call", _ENTRY_POINTS)
def test_oversized_sequence_is_refused_before_any_motion(call, buttons):
    service, grbl = _service(buttons)

    with pytest.raises(UnknownIntentError):
        call(service)

    assert grbl.commands == []
    # 거절 뒤 제어권·실행 상태가 남으면 다음 실행이 영구히 409가 된다
    assert service.status().running is False


def test_refusal_does_not_leak_control_to_the_next_run():
    service, grbl = _service(_TOO_MANY)

    with pytest.raises(UnknownIntentError):
        service.submit_purpose("즉석밥 데워줘")

    service.execute_buttons(("시작",))
    assert [c.button for c in grbl.commands] == ["시작"]


def test_sequence_at_the_limit_is_still_accepted():
    """상한 자체가 정상 경로를 막으면 안 된다."""
    service, grbl = _service(["시작"] * MAX_BUTTONS_PER_RUN)

    service.execute_buttons(tuple(["시작"] * MAX_BUTTONS_PER_RUN))

    assert len(grbl.commands) == MAX_BUTTONS_PER_RUN


# ── 제안 승인 — `approve_submit → submit_purpose`로 같은 합류점을 지난다 ──


class _NullDetector:
    def candidates(self):
        return ()


def test_oversized_suggestion_approval_is_refused_and_stays_pending():
    service, grbl = _service(_TOO_MANY)
    svc = ProactiveSuggestionService(
        _NullDetector(),
        FixedClock(_NOW),
        service,
        intent_resolver=RuleBasedIntentResolver(),
    )
    # 대상 없는 제안은 B10 게이트가 먼저 막는다 — 상한 검사를 보려면 대상이 있어야 한다
    suggestion = svc.create_demo_suggestion("즉석밥 데워줘", appliance_id="microwave")
    assert suggestion is not None

    with pytest.raises(UnknownIntentError):
        svc.approve_submit(suggestion.suggestion_id)

    assert grbl.commands == []
    # 제출 자체가 거절됐으므로 1회용 승인 게이트는 소비되지 않는다
    assert [s.suggestion_id for s in svc.pending()] == [suggestion.suggestion_id]
