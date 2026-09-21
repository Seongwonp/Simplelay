"""제안 승인·거부 동시성 회귀 (교차 리뷰 #8).

승인은 워커 스레드(asyncio.to_thread), 거부·생성은 이벤트 루프 스레드에서
들어온다. 상태 확인과 전이가 원자적이지 않으면 "폰에서 거부했는데 키오스크
승인이 이를 되살려 물리 실행"이 가능했다 — 정확히 하나만 이겨야 한다.
"""

import threading
from datetime import datetime, time, timedelta, timezone

from rpi.intent import (
    InMemoryUsageLog,
    PatternConfig,
    PatternDetector,
    ProactiveSuggestionService,
    SuggestionAlreadyApprovedError,
    TimeBand,
    UnknownSuggestionError,
)
from rpi.intent.mock import FixedClock

KST = timezone(timedelta(hours=9))
EVENING = TimeBand("저녁", time(18, 0), time(22, 0))
RACE_ROUNDS = 50


class CountingSubmitExecutor:
    """submit_purpose 호출 횟수만 세는 executor — 물리 실행의 대역."""

    def __init__(self) -> None:
        self.submitted: list[str] = []
        self._lock = threading.Lock()

    def execute_purpose(
        self, purpose: str, appliance_id: str | None = None, **kwargs
    ) -> object:
        with self._lock:
            self.submitted.append(purpose)
        return "executed"

    def submit_purpose(
        self, purpose: str, appliance_id: str | None = None, **kwargs
    ) -> str:
        with self._lock:
            self.submitted.append(purpose)
            return f"job-{len(self.submitted)}"


def build_service(executor: CountingSubmitExecutor) -> ProactiveSuggestionService:
    clock = FixedClock(datetime(2026, 8, 23, 20, 0, tzinfo=KST))
    detector = PatternDetector(
        InMemoryUsageLog(),
        clock,
        PatternConfig(minimum_occurrences=3, time_bands=(EVENING,)),
    )
    return ProactiveSuggestionService(detector, clock, executor)


def test_concurrent_approve_and_reject_exactly_one_wins():
    executor = CountingSubmitExecutor()
    service = build_service(executor)

    for round_no in range(RACE_ROUNDS):
        suggestion = service.create_demo_suggestion(
            f"즉석밥 데워줘 {round_no}", appliance_id="microwave"
        )
        assert suggestion is not None
        barrier = threading.Barrier(2)
        outcomes: dict[str, bool] = {}

        def approve_side(sid: str = suggestion.suggestion_id) -> None:
            barrier.wait()
            try:
                service.approve_submit(sid)
                outcomes["approved"] = True
            except (UnknownSuggestionError, SuggestionAlreadyApprovedError):
                outcomes["approved"] = False

        def reject_side(sid: str = suggestion.suggestion_id) -> None:
            barrier.wait()
            try:
                service.reject(sid)
                outcomes["rejected"] = True
            except UnknownSuggestionError:
                outcomes["rejected"] = False

        threads = [
            threading.Thread(target=approve_side),
            threading.Thread(target=reject_side),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # 정확히 하나만 성공 — 둘 다 성공(거부됐는데 실행됨)도,
        # 둘 다 실패(제안 증발)도 결함이다.
        assert outcomes["approved"] != outcomes["rejected"], (
            f"round {round_no}: approved={outcomes['approved']} "
            f"rejected={outcomes['rejected']}"
        )
        # 거부가 이겼다면 이 라운드의 purpose는 제출 목록에 없어야 한다
        purpose = f"즉석밥 데워줘 {round_no}"
        count = executor.submitted.count(purpose)
        assert count == (1 if outcomes["approved"] else 0)


def test_concurrent_double_approve_executes_exactly_once():
    executor = CountingSubmitExecutor()
    service = build_service(executor)

    for round_no in range(RACE_ROUNDS):
        suggestion = service.create_demo_suggestion(
            f"저녁 준비 {round_no}", appliance_id="microwave"
        )
        assert suggestion is not None
        barrier = threading.Barrier(2)
        successes: list[bool] = []
        lock = threading.Lock()

        def approve_side(sid: str = suggestion.suggestion_id) -> None:
            barrier.wait()
            try:
                service.approve_submit(sid)
                ok = True
            except (UnknownSuggestionError, SuggestionAlreadyApprovedError):
                ok = False
            with lock:
                successes.append(ok)

        threads = [threading.Thread(target=approve_side) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # 폰과 키오스크가 동시에 승인해도 물리 실행은 1회
        assert successes.count(True) == 1, f"round {round_no}: {successes}"
        assert executor.submitted.count(f"저녁 준비 {round_no}") == 1
