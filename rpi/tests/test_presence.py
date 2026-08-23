"""공간 존재(presence) — TTL·허용 정책·자동 제안 게이팅 검증."""

from datetime import datetime, timedelta, timezone

from rpi.intent.clock import SystemClock
from rpi.intent.models import PatternCandidate
from rpi.intent.suggestions import ProactiveSuggestionService
from rpi.services.presence import PresenceStore


class FakeClock:
    def __init__(self):
        self._now = datetime(2026, 8, 23, 19, 0, tzinfo=timezone.utc)

    def now(self):
        return self._now

    def advance(self, seconds):
        self._now += timedelta(seconds=seconds)


class FakeDetector:
    def __init__(self, candidates=()):
        self._candidates = tuple(candidates)

    def candidates(self):
        return self._candidates


class NoopExecutor:
    def execute_purpose(self, purpose):
        raise AssertionError("not used")


def test_unknown_by_default_and_allows_suggestions():
    store = PresenceStore(SystemClock())
    assert store.current().present is None
    # 감지기가 없는 구성(기본)에서 제안은 정상 동작해야 한다
    assert store.allows_suggestions() is True


def test_set_and_read_presence():
    clock = FakeClock()
    store = PresenceStore(clock)

    store.set_present(False, "camera")

    state = store.current()
    assert state.present is False
    assert state.source == "camera"
    assert store.allows_suggestions() is False  # 명시적 부재만 보류


def test_ttl_expiry_returns_unknown_and_allows_again():
    clock = FakeClock()
    store = PresenceStore(clock, ttl_seconds=60)
    store.set_present(False, "camera")

    clock.advance(61)

    # 감지기 갱신 두절 — 마지막 '부재' 판정이 제안을 영구 차단하면 안 된다
    assert store.current().present is None
    assert store.allows_suggestions() is True


def _service(gate, candidates=(PatternCandidate("우유 데워줘", "저녁", 3),)):
    return ProactiveSuggestionService(
        FakeDetector(candidates), FakeClock(), NoopExecutor(),
        presence_gate=gate,
    )


def test_absent_presence_holds_automatic_suggestions():
    created = _service(gate=lambda: False).create_suggestions()
    assert created == ()


def test_present_or_no_gate_creates_suggestions():
    assert len(_service(gate=lambda: True).create_suggestions()) == 1
    assert len(_service(gate=None).create_suggestions()) == 1


def test_demo_trigger_bypasses_presence_gate():
    # 수동(데모) 트리거는 공간 게이트 대상이 아니다 — 시연 흐름 보장
    service = _service(gate=lambda: False)
    suggestion = service.create_demo_suggestion("우유 데워줘")
    assert suggestion is not None
    assert len(service.pending()) == 1
