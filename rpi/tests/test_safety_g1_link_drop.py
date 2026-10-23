"""G1(안전 계약 적용 보고 2026-10-15 §2) — 승인 카드·루틴·시나리오의 물리 단계에서 링크가 끊기면 결과를 남긴다.

수리 전: ``_run_physical_step``이 실행 대상 예외를 잡지 않아 ``_run_plan_job``이 로그만 남기고 끝났다 — 결과·이력·보호자
알림·완료 이벤트가 없고, ``/status``에는 이 job 번호에 **직전 실행의 결과**가 붙었다(보고서 재현).
직접 경로(``/execute``)는 같은 끊김을 '완료하지 못했어요'·재시도 소진으로 단정했다(G5 문구 — RPi4가 다 눌렀을 수 있다).

수리 뒤: 끊김은 '눌렸는지 모름'이다 — 수신 ``unknown``·확인 없음·상태 ``unconfirmed``, 문장 "연결이 끊겨 눌렸는지 확인하지
못했어요 — 가전을 직접 봐 주세요(자동으로 다시 누르지 않아요)". 이력·보호자 알림·완료 이벤트를 남기고, ``/status``의
``last_*``는 **이 job**의 것이다. 남은 단계는 보내지 않고 자동으로 다시 누르지 않는다.

실행 대상은 가짜(링크 끊김을 예외로 흉내) — **실물 미검증.**
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone

from rpi.api import SimpleLayService
from rpi.api.router import command_status_fields
from rpi.commands import ApprovedCommand, CommandStatus, Confirmation, Receipt
from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus
from rpi.intent import RuleBasedIntentResolver
from rpi.intent.mock import FixedClock
from rpi.routines import RoutineRunner, RoutineStore, RunStatus, build_routine, compile_commands
from rpi.services.act_client import ActLinkTimeoutError
from rpi.services.appliance_registry import ApplianceRegistry
from rpi.services.care_events import CareEventStore
from rpi.services.history import InMemoryJobHistory, Termination

NOW = datetime(2026, 10, 15, 19, tzinfo=timezone(timedelta(hours=9)))
DETAIL = "연결이 끊겨 버튼이 눌렸는지 확인하지 못했어요. 가전을 봐 주세요."
HEAT = {"kind": "press_sequence", "appliance_id": "microwave", "buttons": ["BT-08", "시작"]}
INDUCTION = {"kind": "press_sequence", "appliance_id": "induction", "buttons": ["전원"]}


class _LinkDrops:
    """``fail_on``번째 execute에서 RPi4 응답이 끊긴다(ActLinkTimeoutError). 나머지는 다 눌렀다고 답한다."""

    def __init__(self, *fail_on: int) -> None:
        self.fail_on = set(fail_on)
        self.calls: list[tuple[str, ...]] = []

    def execute(self, buttons, targets=None):
        self.calls.append(tuple(buttons))
        if len(self.calls) in self.fail_on:
            raise ActLinkTimeoutError("no response for sequence_id='x' within 9.0s")
        return ExecutionResult(ExecutionStatus.SUCCEEDED,
                               tuple(ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons))


def _service(controller):
    history, care, events = InMemoryJobHistory(), CareEventStore(FixedClock(NOW)), []
    service = SimpleLayService(RuleBasedIntentResolver(), controller, clock=FixedClock(NOW),
                               history_store=history, care_events=care, job_listeners=(events.append,))
    return service, history, care, events


def _wait_done(service, job_id):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        snap = service.status()
        if not snap.running and snap.last_job_id == job_id:
            return snap
        time.sleep(0.01)
    raise AssertionError("job did not finish")


def _approved(*steps):
    registry = ApplianceRegistry()
    routine = RoutineStore().save(build_routine(
        {"name": "저녁 데우기", "steps": list(steps), "trigger": {"kind": "manual"}}, routine_id="rt-g1", now=NOW))
    commands = compile_commands(routine, registry)
    return routine, tuple(ApprovedCommand(c, "card-g1", NOW, "요약", NOW + timedelta(minutes=15)) for c in commands)


def _assert_unconfirmed_status(snap, job_id):
    assert snap.last_job_id == job_id
    # 직전 실행(성공)의 결과가 이 job에 붙지 않는다.
    assert snap.last_result is not None and snap.last_result.status is not ExecutionStatus.SUCCEEDED
    fields = command_status_fields(snap)
    assert fields["last_status"] == "unconfirmed" and fields["last_outcome"] == "unconfirmed"
    assert fields["last_receipt"] == "unknown" and fields["last_confirmation"] == "none"
    assert fields["last_detail"] == DETAIL


def _assert_care(care):
    newest = care.recent()[0]
    assert newest.kind == "execution_failed"
    assert "눌렸는지 확인하지 못했어요" in newest.message and "다시 누르지 않아요" in newest.message
    assert "완료하지 못했어요" not in newest.message
    assert "9.0s" not in newest.message  # 내부 예외 문구 비노출


def test_approved_card_link_drop_mid_step_is_unconfirmed_and_recorded():
    controller = _LinkDrops(2)
    service, history, care, events = _service(controller)
    service.execute_buttons(("BT-08", "시작"))  # 직전 실행 — 성공
    _, approved = _approved(HEAT)

    job_id = service.submit_approved(approved)
    snap = _wait_done(service, job_id)

    _assert_unconfirmed_status(snap, job_id)
    record = service.last_run()
    assert record is not None and record.job_id == job_id
    (result,) = record.results
    assert result.status is CommandStatus.UNCONFIRMED
    assert result.receipt is Receipt.UNKNOWN and result.confirmation is Confirmation.NONE
    assert result.detail == DETAIL
    entry = history.recent()[0]
    assert entry.job_id == job_id
    assert (entry.outcome, entry.receipt, entry.detail) == ("unconfirmed", "unknown", DETAIL)
    assert entry.termination is Termination.UNKNOWN
    _assert_care(care)
    finished = [e for e in events if e.job_id == job_id]
    assert len(finished) == 1
    assert finished[0].status == "unconfirmed" and finished[0].receipt is Receipt.UNKNOWN
    assert len(controller.calls) == 2  # 자동으로 다시 누르지 않았다


def test_routine_link_drop_stops_without_sending_the_rest():
    controller = _LinkDrops(1)
    service, history, care, _events = _service(controller)
    routine, approved = _approved(HEAT, INDUCTION)
    store = RoutineStore()
    store.save(routine)
    runner = RoutineRunner(store, service, FixedClock(NOW), care, poll_seconds=0, sleep=lambda s: None)

    run = runner.execute_approved(approved, scenario_id=routine.scenario_key())

    # 인덕션 단계는 보내지 않았다 · 끊긴 단계를 다시 누르지 않았다.
    assert controller.calls == [tuple(approved[0].command.buttons)]
    assert approved[1].command.target_id == "induction"
    assert run.status is RunStatus.UNCONFIRMED
    assert run.steps[0]["status"] == "unconfirmed" and run.steps[0]["detail"] == DETAIL
    assert run.steps[1]["status"] == "failed"
    _assert_unconfirmed_status(service.status(), run.job_ids[0])
    assert history.recent()[0].outcome == "unconfirmed"
    assert any(e.kind == "execution_failed" and "눌렸는지" in e.message for e in care.recent())


def test_direct_path_link_drop_says_unconfirmed_not_failed():
    """직접 경로(G5 문구): 동작은 종전 그대로(예외 → 이력·보호자 알림), 분류·문장만 '미확인'."""
    controller = _LinkDrops(2)
    service, history, care, events = _service(controller)
    service.execute_buttons(("BT-08", "시작"))

    job_id = service.submit_buttons(("BT-08", "시작"))
    snap = _wait_done(service, job_id)

    _assert_unconfirmed_status(snap, job_id)
    entry = history.recent()[0]
    assert (entry.outcome, entry.receipt, entry.detail) == ("unconfirmed", "unknown", DETAIL)
    assert entry.termination is Termination.UNKNOWN  # '다시 눌러도 확인 못 함'(재시도 소진)이 아니다
    _assert_care(care)
    assert len(controller.calls) == 2


def test_ambient_tip_says_press_unknown_for_a_physical_link_drop():
    """키오스크 대기 화면의 '확인이 필요한 일' — 물리 끊김은 '바뀌었는지'가 아니라 '눌렸는지'를 모른다."""
    from rpi.api.ambient_router import _attention
    from rpi.services.alert_store import DangerAlertStore

    controller = _LinkDrops(1)
    service, _history, care, _events = _service(controller)
    job_id = service.submit_buttons(("BT-08", "시작"))
    _wait_done(service, job_id)

    items = _attention(service, ApplianceRegistry(), DangerAlertStore(FixedClock(NOW)))
    assert [i.text for i in items if i.kind == "appliance"] == ["가전 버튼이 눌렸는지 확인하지 못했어요. 가전을 봐 주세요."]
