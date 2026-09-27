"""Execution provenance belongs to the job, never to its transport."""
from rpi.api import SimpleLayService
from rpi.controller import ClosedLoopController, ExecutionMode
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.intent import RuleBasedIntentResolver
from rpi.verifier import MockVerifier
from rpi.commands import Command, Confirmation, command_result_from_execution


def test_current_and_previous_modes_remain_bound_to_their_jobs():
    controller = ClosedLoopController(MockGrblClient(), MockVerifier([True]),
                                      MockAlertSink(), MockSafetyController())
    service = SimpleLayService(RuleBasedIntentResolver(), controller)
    service.execute_buttons(("start",))
    previous = service.status()
    assert previous.last_execution_mode is ExecutionMode.MOCK
    assert previous.execution_mode is ExecutionMode.UNKNOWN
    class Remote:
        execution_mode = ExecutionMode.UNKNOWN
    current_id = service._begin_run(1, Remote(), "other")
    try:
        snapshot = service.status()
        assert snapshot.job_id == current_id
        assert snapshot.last_job_id == previous.last_job_id
        assert snapshot.execution_mode is ExecutionMode.UNKNOWN
        assert snapshot.last_execution_mode is ExecutionMode.MOCK
    finally:
        service._end_run()


def test_real_closed_loop_mock_result_maps_without_becoming_real():
    controller = ClosedLoopController(MockGrblClient(), MockVerifier([True]),
                                      MockAlertSink(), MockSafetyController())
    result = controller.execute(["start"])
    mapped = command_result_from_execution(Command.physical("device", ["start"]),
                result, execution_mode=controller.execution_mode)
    assert mapped.execution_mode is ExecutionMode.MOCK
    assert mapped.confirmation is Confirmation.PRESS_CONFIRMED
    assert mapped.physical is result
