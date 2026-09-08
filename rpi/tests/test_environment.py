"""온습도 기반 선제 제안 — 제안기·서비스 통합."""

from datetime import datetime, time, timedelta, timezone

from rpi.intent import (
    InMemoryUsageLog,
    PatternConfig,
    PatternDetector,
    ProactiveSuggestionService,
    RuleBasedIntentResolver,
    TimeBand,
)
from rpi.intent.environment import ComfortThresholds, EnvironmentalSuggester
from rpi.intent.mock import FixedClock, MockPurposeExecutor
from rpi.intent.suppression import InMemorySuppressionStore

KST = timezone(timedelta(hours=9))


def _svc(reading, store=None, executor=None):
    # 오후 3시 — 아침 밴드 밖이라 패턴 후보는 없고, 환경 제안만 검증된다.
    clock = FixedClock(datetime(2026, 7, 23, 15, 0, tzinfo=KST))
    detector = PatternDetector(
        InMemoryUsageLog(()),
        clock,
        PatternConfig(
            minimum_occurrences=3,
            time_bands=(TimeBand("아침", time(6, 0), time(10, 0)),),
        ),
    )
    return ProactiveSuggestionService(
        detector,
        clock,
        executor or MockPurposeExecutor(),
        intent_resolver=RuleBasedIntentResolver(),
        suppression_store=store,
        environmental=EnvironmentalSuggester(lambda: reading),
    )


# ── 제안기 ────────────────────────────────────────────────────────────────


def test_hot_yields_candidate():
    c = EnvironmentalSuggester(lambda: (30.0, 55.0)).candidate()
    assert c is not None
    assert c.purpose == "에어컨 켜줘"
    assert "30" in c.reason and "더워요" in c.reason


def test_humid_yields_candidate():
    assert EnvironmentalSuggester(lambda: (25.0, 75.0)).candidate() is not None


def test_comfortable_no_candidate():
    assert EnvironmentalSuggester(lambda: (24.0, 50.0)).candidate() is None


def test_no_sensor_no_candidate():
    assert EnvironmentalSuggester(lambda: (None, None)).candidate() is None


def test_custom_thresholds():
    s = EnvironmentalSuggester(
        lambda: (26.0, 50.0),
        ComfortThresholds(temperature_c=25.0, humidity_pct=90.0),
    )
    assert s.candidate() is not None


# ── 서비스 통합 ──────────────────────────────────────────────────────────


def test_service_creates_env_suggestion_when_hot():
    created = _svc((30.0, 55.0)).create_suggestions()
    assert len(created) == 1
    s = created[0]
    assert s.purpose == "에어컨 켜줘"
    assert s.time_band == "환경"
    assert s.steps == ("전원", "냉방")
    assert "더워요" in s.reason


def test_service_no_env_when_comfortable():
    assert _svc((24.0, 50.0)).create_suggestions() == ()


def test_env_suggestion_dedups():
    svc = _svc((30.0, 55.0))
    first = svc.create_suggestions()
    second = svc.create_suggestions()
    assert len(first) == 1 and len(second) == 1
    assert first[0].suggestion_id == second[0].suggestion_id


def test_env_suggestion_respects_mute():
    store = InMemorySuppressionStore()
    store.mute("에어컨 켜줘")
    assert _svc((30.0, 55.0), store).create_suggestions() == ()


# ── 대상 가전 결합 ────────────────────────────────────────────────────────


def test_env_suggestion_carries_target_appliance():
    (suggestion,) = _svc((30.0, 55.0)).create_suggestions()
    assert suggestion.appliance_id == "aircon"


def test_approve_executes_on_the_suggested_appliance():
    """화면이 보여준 대상과 실제 실행 대상이 같아야 한다.

    예전에는 승인이 purpose만 넘겨서, 전자레인지를 고른 상태로 냉방 제안을
    승인하면 화면과 실행 대상이 어긋날 수 있었다.
    """
    executor = MockPurposeExecutor()
    svc = _svc((30.0, 55.0), executor=executor)
    (suggestion,) = svc.create_suggestions()

    svc.approve(suggestion.suggestion_id)

    assert executor.purposes == ["에어컨 켜줘"]
    assert executor.appliance_ids == ["aircon"]
