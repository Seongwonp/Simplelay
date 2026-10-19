"""검토 2026-10-19: 승인 영수증이 **접수 중**에는 없었다 — 첫 승인이 승인을 소비하고 실행을 접수하는 동안 다시 보낸 승인은
409('이미 승인')만 받아 실행 번호를 알 수 없었다. 이제 접수 중 표시를 승인 소비와 같은 잠금 안에서 걸고, 다시 보낸 승인은
그것을 기다려 같은 실행 번호를 받는다(다시 실행하지 않음). 접수에 실패하면 표시를 거두고 카드는 다시 승인할 수 있다.
"""

from __future__ import annotations

import threading

from rpi.tests.test_suggestion_race import CountingSubmitExecutor, build_service


class _BlockingExecutor(CountingSubmitExecutor):
    def __init__(self) -> None:
        super().__init__()
        self.entered = threading.Event()
        self.release = threading.Event()
        self.fail_first: Exception | None = None

    def submit_purpose(self, purpose, appliance_id=None, **kwargs):
        self.entered.set()
        assert self.release.wait(timeout=5)
        if self.fail_first is not None:
            exc, self.fail_first = self.fail_first, None
            raise exc
        return super().submit_purpose(purpose, appliance_id, **kwargs)


def _run(fn, out: list) -> threading.Thread:
    def body() -> None:
        try:
            out.append(("ok", fn()))
        except Exception as exc:  # noqa: BLE001
            out.append(("err", exc))

    t = threading.Thread(target=body)
    t.start()
    return t


def test_duplicate_approve_during_admission_waits_and_gets_the_same_job():
    executor = _BlockingExecutor()
    service = build_service(executor)
    card = service.create_demo_suggestion("즉석밥 데워줘", appliance_id="microwave")
    results: list = []

    first = _run(lambda: service.approve_submit(card.suggestion_id), results)
    assert executor.entered.wait(timeout=5)
    second = _run(lambda: service.approve_submit(card.suggestion_id), results)
    second.join(timeout=0.2)
    assert second.is_alive(), "duplicate must wait for the first admission, not fail with 409"
    executor.release.set()
    first.join(timeout=5)
    second.join(timeout=5)

    assert [kind for kind, _ in results] == ["ok", "ok"], results
    assert results[0][1] == results[1][1]
    assert executor.submitted == ["즉석밥 데워줘"]
    assert service.accepted_job(card.suggestion_id) == results[0][1]


def test_failed_admission_releases_the_waiters_and_the_card_can_be_approved_again():
    executor = _BlockingExecutor()
    executor.fail_first = RuntimeError("다른 일을 하고 있어요")
    service = build_service(executor)
    card = service.create_demo_suggestion("즉석밥 데워줘", appliance_id="microwave")
    results: list = []

    first = _run(lambda: service.approve_submit(card.suggestion_id), results)
    assert executor.entered.wait(timeout=5)
    second = _run(lambda: service.approve_submit(card.suggestion_id), results)
    second.join(timeout=0.2)
    executor.release.set()
    first.join(timeout=5)
    second.join(timeout=5)

    assert [kind for kind, _ in results] == ["err", "err"], results
    assert all(isinstance(exc, RuntimeError) and "다른 일" in str(exc) for _, exc in results)
    assert service.accepted_job(card.suggestion_id) is None
    assert executor.submitted == []
    # 접수 중 표시가 남지 않았다 — 카드는 다시 승인할 수 있고 그때 새로 접수한다.
    job = service.approve_submit(card.suggestion_id)
    assert executor.submitted == ["즉석밥 데워줘"]
    assert service.approve_submit(card.suggestion_id) == job
