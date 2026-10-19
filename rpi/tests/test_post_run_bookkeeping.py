"""누름이 끝난 뒤의 기록 고장이 실행 결과를 '연결이 끊겨 눌렸는지 몰라요'로 바꾸지 않는다(2026-10-19 검토 MED).

실행 대상(컨트롤러)은 성공을 돌려줬는데 그 뒤 사용 기록(학습 로그 DB 등) 쓰기가 예외를 올리면, 예전에는 예외가 실행 스레드
위로 올라가 ``_record_unconfirmed_physical``(링크 끊김·눌렸는지 모름·보호자 알림)로 남았다. 기록 고장은 로그로만 남기고
실제 결과를 그대로 보고한다. 컨트롤러 자체의 예외만 '눌렸는지 모름'이다.
"""

from __future__ import annotations

import time

from rpi.api.service import SimpleLayService
from rpi.controller import ExecutionMode, ExecutionResult, ExecutionStatus
from rpi.intent.rules import RuleBasedIntentResolver


class _Controller:
    execution_mode = ExecutionMode.MOCK

    def __init__(self, raise_exc: bool = False):
        self.calls = []
        self.raise_exc = raise_exc

    def execute(self, buttons):
        self.calls.append(buttons)
        if self.raise_exc:
            raise RuntimeError("link lost")
        return ExecutionResult(ExecutionStatus.SUCCEEDED, ())


class _BrokenUsageLog:
    def append(self, record) -> None:
        raise OSError("disk full")

    def records(self):
        return ()


class _Care:
    def __init__(self):
        self.events = []

    def append(self, kind, message, purpose=None):
        self.events.append((kind, message))


def _service(controller, care=None):
    return SimpleLayService(RuleBasedIntentResolver(), controller, usage_log=_BrokenUsageLog(),
                            care_events=care)


def _wait_idle(service, timeout=5.0):
    deadline = time.monotonic() + timeout
    while service.status().running:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    return service.status()


def test_sync_run_reports_success_when_usage_log_fails():
    controller = _Controller()
    result = _service(controller).execute_purpose("밥 데워줘", "microwave")
    assert result.status is ExecutionStatus.SUCCEEDED
    assert len(controller.calls) == 1


def test_background_run_is_not_recorded_as_link_lost_when_usage_log_fails():
    care = _Care()
    controller = _Controller()
    service = _service(controller, care)
    service.submit_purpose("밥 데워줘", "microwave")
    status = _wait_idle(service)
    assert status.last_result.status is ExecutionStatus.SUCCEEDED
    assert status.last_receipt != "unknown", status
    assert status.last_command_status != "unconfirmed", status
    assert not any("끊겨" in message for _, message in care.events), care.events


def test_controller_exception_is_still_unconfirmed():
    care = _Care()
    service = _service(_Controller(raise_exc=True), care)
    service.submit_purpose("밥 데워줘", "microwave")
    status = _wait_idle(service)
    assert status.last_receipt == "unknown", status
    assert any("끊겨" in message for _, message in care.events), care.events
