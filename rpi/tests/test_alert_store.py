"""DangerAlertStore tests — pure in-memory state, no hardware/HTTP."""

from datetime import datetime, timezone

from rpi.intent.mock import FixedClock
from rpi.services import AlertEvent, DangerAlertStore


def _clock(when: datetime = datetime(2026, 8, 17, 12, 0, tzinfo=timezone.utc)) -> FixedClock:
    return FixedClock(when)


def test_initial_state_is_inactive():
    store = DangerAlertStore(_clock())
    state = store.current()
    assert state.active is False
    assert state.kind is None
    assert state.updated_at is None


def test_record_raised_event_updates_state():
    clock = _clock()
    store = DangerAlertStore(clock)

    store.record(AlertEvent(kind="danger_sound", raised=True, band_energy_ratio=0.8, mean_period_seconds=0.4))

    state = store.current()
    assert state.active is True
    assert state.kind == "danger_sound"
    assert state.band_energy_ratio == 0.8
    assert state.mean_period_seconds == 0.4
    assert state.updated_at == clock.now()


def test_record_cleared_event_deactivates():
    store = DangerAlertStore(_clock())
    store.record(AlertEvent(kind="danger_sound", raised=True))

    store.record(AlertEvent(kind="danger_sound", raised=False))

    assert store.current().active is False


def test_updated_at_tracks_clock_at_time_of_record():
    clock = _clock(datetime(2026, 8, 17, 9, 0, tzinfo=timezone.utc))
    store = DangerAlertStore(clock)
    store.record(AlertEvent(kind="danger_sound", raised=True))
    assert store.current().updated_at == datetime(2026, 8, 17, 9, 0, tzinfo=timezone.utc)

    clock.set(datetime(2026, 8, 17, 9, 5, tzinfo=timezone.utc))
    store.record(AlertEvent(kind="danger_sound", raised=False))
    assert store.current().updated_at == datetime(2026, 8, 17, 9, 5, tzinfo=timezone.utc)


def test_only_the_latest_state_is_kept_not_a_history():
    store = DangerAlertStore(_clock())
    store.record(AlertEvent(kind="danger_sound", raised=True, band_energy_ratio=0.7))
    store.record(AlertEvent(kind="danger_sound", raised=True, band_energy_ratio=0.9))

    assert store.current().band_energy_ratio == 0.9
