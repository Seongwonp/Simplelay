import pytest

from rpi.api import ServiceNotReadyError, SimpleLayService
from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import RuleBasedIntentResolver
from rpi.verifier import MockVerifier


def build_service(**kwargs) -> SimpleLayService:
    controller = ClosedLoopController(
        MockGrblClient(), MockVerifier([True, True, True]), MockAlertSink(), MockSafetyController()
    )
    return SimpleLayService(RuleBasedIntentResolver(), controller, **kwargs)


def test_default_construction_is_ready_immediately():
    service = build_service()

    assert service.status().ready is True
    result = service.execute_purpose("즉석밥 데워줘")
    assert result is not None


def test_not_started_ready_rejects_execution():
    service = build_service(start_ready=False)

    assert service.status().ready is False
    with pytest.raises(ServiceNotReadyError):
        service.execute_purpose("즉석밥 데워줘")


def test_mark_ready_allows_execution():
    service = build_service(start_ready=False)

    service.mark_ready()

    assert service.status().ready is True
    result = service.execute_purpose("즉석밥 데워줘")
    assert result is not None


def test_request_shutdown_rejects_new_purposes():
    service = build_service()
    service.execute_purpose("즉석밥 데워줘")  # completes normally before shutdown

    service.request_shutdown()

    assert service.status().ready is False
    with pytest.raises(ServiceNotReadyError):
        service.execute_purpose("즉석밥 데워줘")


def test_shutdown_does_not_clear_the_last_completed_result():
    service = build_service()
    result = service.execute_purpose("즉석밥 데워줘")

    service.request_shutdown()

    assert service.status().last_result is result
    assert service.status().running is False
