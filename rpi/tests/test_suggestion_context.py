from datetime import timedelta
from types import SimpleNamespace

import pytest

from rpi.intent.environment import EnvironmentalCandidate, EnvironmentalSuggester
from rpi.intent.rules import RuleBasedIntentResolver
from rpi.intent.suggestions import UnknownSuggestionError
from rpi.services.presence import PresenceStore
from rpi.tests.test_completed_actions import setup
from rpi.tests.test_learning_evidence import NOW


def environment_setup():
    readings = [30.0, 55.0]
    env = EnvironmentalSuggester(lambda: tuple(readings))
    service, executor, controller, clock, log = setup(
        now=NOW.replace(hour=15), environmental=env)
    return service, executor, controller, clock, readings


def test_departure_retires_existing_pattern_and_return_creates_new_id():
    service, _, controller, clock, _ = setup()
    presence = PresenceStore(clock)
    presence.set_present(True, 'test')
    service._presence_gate = presence.allows_suggestions
    old, = service.create_suggestions()
    presence.set_present(False, 'test')
    assert service.pending() == ()
    with pytest.raises(UnknownSuggestionError):
        service.approve(old.suggestion_id)
    presence.set_present(True, 'test')
    new, = service.create_suggestions()
    assert new.suggestion_id != old.suggestion_id
    assert controller.calls == []


def test_unknown_presence_retains_existing_optional_gate_policy():
    service, _, _, clock, _ = setup()
    presence = PresenceStore(clock)
    service._presence_gate = presence.allows_suggestions
    assert len(service.create_suggestions()) == 1
    presence.set_present(False, 'test')
    assert service.create_suggestions() == ()
    clock.set(clock.now()+timedelta(seconds=61))
    assert len(service.create_suggestions()) == 1


@pytest.mark.parametrize('reading', [(24, 50), (None, None), (float('nan'), None), (float('inf'), -1)])
def test_environment_loss_retires_pending_and_cannot_be_approved(reading):
    service, _, controller, _, readings = environment_setup()
    old, = service.create_suggestions()
    readings[:] = reading
    with pytest.raises(UnknownSuggestionError):
        service.approve_submit(old.suggestion_id)
    assert service.pending() == ()
    assert controller.calls == []


def test_reason_changes_without_resetting_card_lifetime_or_id():
    service, _, _, clock, readings = environment_setup()
    old, = service.create_suggestions()
    clock.set(clock.now()+timedelta(minutes=1))
    readings[:] = [31, 75]
    current, = service.pending()
    assert '31' in current.reason and '75' in current.reason
    assert current.suggestion_id == old.suggestion_id
    assert current.created_at == old.created_at
    assert current.expires_at == old.expires_at


def test_recovery_does_not_resurrect_withdrawn_environment_card():
    service, _, _, _, readings = environment_setup()
    old, = service.create_suggestions()
    readings[:] = [24, 50]
    assert service.pending() == ()
    readings[:] = [30, 55]
    new, = service.create_suggestions()
    assert new.suggestion_id != old.suggestion_id
    with pytest.raises(UnknownSuggestionError):
        service.approve(old.suggestion_id)


def test_changed_target_never_reuses_old_environment_card():
    service, _, _, _, _ = environment_setup()
    old, = service.create_suggestions()
    service._environmental = SimpleNamespace(candidate=lambda: EnvironmentalCandidate(
        '에어컨 켜줘', '지금 더워요', 'other-aircon'))
    assert service.pending() == ()
    new, = service.create_suggestions()
    assert new.appliance_id == 'other-aircon'
    assert new.suggestion_id != old.suggestion_id


def test_presence_change_during_preview_prevents_creation():
    service, _, _, _, _ = setup()
    present = [True]
    service._presence_gate = lambda: present[0]
    class Preview(RuleBasedIntentResolver):
        def resolve(self, purpose):
            present[0] = False
            return super().resolve(purpose)
    service._intent_resolver = Preview()
    assert service.create_suggestions() == ()


def test_cooling_during_preview_prevents_creation():
    service, _, _, _, readings = environment_setup()
    class Preview(RuleBasedIntentResolver):
        def resolve(self, purpose):
            readings[:] = [24, 50]
            return super().resolve(purpose)
    service._intent_resolver = Preview()
    assert service.create_suggestions() == ()


@pytest.mark.parametrize('asynchronous', [False, True])
def test_presence_changes_during_resolution_are_blocked_at_start(asynchronous):
    service, executor, controller, _, _ = setup()
    present = [True]
    service._presence_gate = lambda: present[0]
    old, = service.create_suggestions()
    class Resolver(RuleBasedIntentResolver):
        def resolve(self, purpose):
            present[0] = False
            return super().resolve(purpose)
    executor._intent = Resolver()
    approve = service.approve_submit if asynchronous else service.approve
    with pytest.raises(UnknownSuggestionError):
        approve(old.suggestion_id)
    present[0] = True
    assert service.pending() == ()
    assert controller.calls == []


@pytest.mark.parametrize('asynchronous', [False, True])
def test_environment_changes_during_resolution_are_blocked_at_start(asynchronous):
    service, executor, controller, _, readings = environment_setup()
    old, = service.create_suggestions()
    class Resolver(RuleBasedIntentResolver):
        def resolve(self, purpose):
            readings[:] = [24, 50]
            service.pending()  # another polling request observes the change
            return super().resolve(purpose)
    executor._intent = Resolver()
    approve = service.approve_submit if asynchronous else service.approve
    with pytest.raises(UnknownSuggestionError):
        approve(old.suggestion_id)
    readings[:] = [30, 55]
    assert service.pending() == ()
    assert controller.calls == []


def test_slow_resolution_cannot_use_old_sensor_snapshot():
    service, executor, controller, clock, _ = environment_setup()
    old, = service.create_suggestions()
    class Resolver(RuleBasedIntentResolver):
        def resolve(self, purpose):
            clock.set(clock.now()+timedelta(seconds=15))
            return super().resolve(purpose)
    executor._intent = Resolver()
    with pytest.raises(UnknownSuggestionError):
        service.approve_submit(old.suggestion_id)
    assert controller.calls == []
    assert service.pending() == ()


def test_sensor_io_never_runs_inside_suggestion_or_execution_locks():
    service, executor, _, _, _ = environment_setup()
    calls = []
    def read():
        assert not service._state_lock.locked()
        assert not executor._lock.locked()
        calls.append(True)
        return (30, 55)
    service._environmental = EnvironmentalSuggester(read)
    old, = service.create_suggestions()
    service.pending()
    service.approve(old.suggestion_id)
    assert len(calls) == 4  # create before/after preview, pending, pre-claim


def test_sensor_exception_retires_only_environment_not_habit():
    service, _, _, _, _ = setup(environmental=EnvironmentalSuggester(lambda: (30, 55)))
    assert len(service.create_suggestions()) == 2
    def broken():
        raise OSError('sensor offline')
    service._environmental = EnvironmentalSuggester(broken)
    remaining, = service.pending()
    assert remaining.time_band != '환경'


def test_demo_remains_explicitly_exempt_from_presence_and_environment():
    service, _, controller, _, readings = environment_setup()
    service._presence_gate = lambda: False
    readings[:] = [None, None]
    card = service.create_demo_suggestion('에어컨 켜줘', appliance_id='aircon')
    assert service.pending() == (card,)
    service.approve(card.suggestion_id)
    assert len(controller.calls) == 1


@pytest.mark.parametrize('reading', [(None, float('nan')), (None, float('inf')), (None, 101), (None, -1), (True, False)])
def test_invalid_readings_do_not_create_environment_evidence(reading):
    assert EnvironmentalSuggester(lambda: reading).candidate() is None


def test_humidity_only_reason_does_not_claim_high_temperature():
    candidate = EnvironmentalSuggester(lambda: (24, 75)).candidate()
    assert '습해요' in candidate.reason
    assert '더워요' not in candidate.reason


def test_absence_observed_during_dnd_does_not_resurrect_old_card():
    service, _, _, _, _ = setup()
    present = [True]
    service._presence_gate = lambda: present[0]
    old, = service.create_suggestions()
    service.set_dnd_for(10)
    present[0] = False
    assert service.pending() == ()
    present[0] = True
    service.clear_dnd()
    assert service.pending() == ()
    with pytest.raises(UnknownSuggestionError):
        service.approve(old.suggestion_id)


def test_environment_preview_departure_does_not_return_earlier_pattern_card():
    service, _, _, _, _ = setup(environmental=EnvironmentalSuggester(lambda: (30, 55)))
    present = [True]
    service._presence_gate = lambda: present[0]
    class Preview(RuleBasedIntentResolver):
        def resolve(self, purpose):
            if purpose == '에어컨 켜줘':
                present[0] = False
            return super().resolve(purpose)
    service._intent_resolver = Preview()
    assert service.create_suggestions() == ()
    assert service.pending() == ()
