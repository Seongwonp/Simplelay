from rpi.controller import ExecutionProgress, ExecutionProgressTracker
from rpi.verifier import VerificationResult


def make_progress(button="시작", attempt=1, completed=0):
    return ExecutionProgress(
        button=button,
        attempt=attempt,
        completed_steps=completed,
        verification=VerificationResult(pressed=True, confidence=0.9),
    )


def test_starts_empty():
    tracker = ExecutionProgressTracker()
    assert tracker.current() is None


def test_update_then_current_returns_latest():
    tracker = ExecutionProgressTracker()
    first = make_progress(attempt=1)
    second = make_progress(attempt=2)

    tracker.update(first)
    assert tracker.current() == first

    tracker.update(second)
    assert tracker.current() == second


def test_clear_resets_to_none():
    tracker = ExecutionProgressTracker()
    tracker.update(make_progress())

    tracker.clear()

    assert tracker.current() is None
