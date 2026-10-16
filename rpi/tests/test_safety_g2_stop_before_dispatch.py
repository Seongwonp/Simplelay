"""G2(안전 계약 적용 보고 2026-10-15 §2) — 접수 뒤·보내기 전에 온 정지가 사라지지 않는다(UART 경로).

수리 전: RPi5는 정지를 받으면 abort를 보내고 실행별 정지 기록만 세웠다. 실행 스레드는 그 기록을 보지 않고 execute를
보냈고, RPi4는 아직 쉬는 중이라 abort를 버렸다 → 정지 뒤 버튼을 **전부 누르고 '성공'**(보고서 재현).

수리 뒤:
1. RPi5 실행 스레드가 실행 대상에 넘기기 직전에 이번 실행의 정지 기록을 본다 — 있으면 보내지 않고 ``stopped``·
   수신 ``not_dispatched``로 이력·보호자 알림·완료 이벤트를 남긴다.
2. 그 확인 뒤·execute 줄을 쓰기 전에 온 정지도 RPi4 링크(ActClientController)가 이벤트 루프 안에서 다시 본다
   (확인과 줄 쓰기 사이에 await가 없다).

RPi4·RPi5는 실제 구현(ActExecutor·ActClient)을 메모리 파이프로 잇는다. 모션은 모의(MockGrblClient) — **실물 미검증.**
경쟁은 실행 대상 훅에서 정지를 불러 결정적으로 만든다.
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest

from rpi.api import SimpleLayService
from rpi.commands import ApprovedCommand, Command, CommandStatus, Receipt
from rpi.controller import ClosedLoopController, ExecutionStatus
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.models import ExecutionOutcome, outcome_of
from rpi.intent import RuleBasedIntentResolver
from rpi.services.act_client import ActClient
from rpi.services.act_client_controller import ActClientController, start_background_loop
from rpi.services.care_events import CareEventStore
from rpi.services.history import InMemoryJobHistory, Termination
from rpi.intent.mock import FixedClock
from rpi.verifier import MockVerifier
from rpi4.services.act_executor import ActExecutor

from datetime import datetime, timezone

BUTTONS = ("b1", "b2", "b3")


class _TapWriter:
    """쓴 줄을 상대 reader로 넘기고, 보낸 프레임을 기록한다."""

    def __init__(self, peer: asyncio.StreamReader) -> None:
        self._peer = peer
        self.docs: list[dict] = []

    def write(self, data: bytes) -> None:
        self.docs.extend(json.loads(x) for x in data.splitlines() if x.strip())
        self._peer.feed_data(data)

    async def drain(self) -> None:
        pass


class _StopAt(ActClientController):
    """정지를 **특정 순간**에 부른다 — ``arm``: 서비스가 실행 대상을 고른 직후(정지 기록 확인 전),
    ``execute``: 서비스가 실행 대상에 넘긴 직후·줄을 쓰기 전(서비스 확인 뒤의 창)."""

    def __init__(self, loop, client, when: str) -> None:
        super().__init__(loop, client)
        self.when = when
        self.service: SimpleLayService | None = None
        self.fired = False

    def _fire(self, at: str) -> None:
        if self.when == at and not self.fired:
            self.fired = True
            assert self.service is not None
            self.service.emergency_stop()

    def arm_execute_target(self, appliance_id: str) -> None:
        super().arm_execute_target(appliance_id)
        self._fire("arm")

    def execute(self, buttons, targets=None, *, button_behaviors=None):
        self._fire("execute")
        return super().execute(buttons, targets, button_behaviors=button_behaviors)


@pytest.fixture
def link():
    loop, _thread = start_background_loop()
    made = {}

    async def build():
        rpi4_reader, rpi5_reader = asyncio.StreamReader(), asyncio.StreamReader()
        hub_writer = _TapWriter(rpi4_reader)  # RPi5 → RPi4
        act_writer = _TapWriter(rpi5_reader)  # RPi4 → RPi5
        grbl = MockGrblClient()
        controller = ClosedLoopController(grbl, MockVerifier([True] * 30), MockAlertSink(), MockSafetyController())
        executor = ActExecutor(rpi4_reader, act_writer, controller)
        client = ActClient(rpi5_reader, hub_writer)
        await client.start()
        task = asyncio.ensure_future(executor.run())
        made.update(grbl=grbl, executor=executor, client=client, task=task, hub=hub_writer)

    asyncio.run_coroutine_threadsafe(build(), loop).result(5)
    deadline = time.monotonic() + 3
    while made["client"].estop_latched is None and time.monotonic() < deadline:
        time.sleep(0.01)
    assert made["client"].act_info.get("execute_protocol") == 2
    made["loop"] = loop
    yield made

    async def teardown():
        made["task"].cancel()
        await made["client"].stop()

    asyncio.run_coroutine_threadsafe(teardown(), loop).result(5)
    loop.call_soon_threadsafe(loop.stop)


def _service(link, when):
    controller = _StopAt(link["loop"], link["client"], when)
    history, care, events = InMemoryJobHistory(), CareEventStore(FixedClock(datetime(2026, 10, 15, 12, tzinfo=timezone.utc))), []
    service = SimpleLayService(
        RuleBasedIntentResolver({"테스트": BUTTONS}), controller,
        history_store=history, care_events=care, job_listeners=(events.append,),
    )
    controller.service = service
    return service, controller, history, care, events


def _wait_done(service, job_id):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        snap = service.status()
        if not snap.running and snap.last_job_id == job_id:
            return snap
        time.sleep(0.01)
    raise AssertionError("job did not finish")


def _executes(link):
    return [d for d in link["hub"].docs if d.get("type") == "execute"]


@pytest.mark.parametrize("when", ["arm", "execute"])
def test_stop_after_accept_before_dispatch_sends_nothing_over_uart(link, when):
    service, controller, history, care, events = _service(link, when)

    job_id = service.submit_purpose("테스트")
    snap = _wait_done(service, job_id)

    assert controller.fired
    # 정지는 나갔다(RPi4는 쉬는 중이라 멈출 것이 없었다).
    assert any(d.get("type") == "abort" for d in link["hub"].docs)
    # 보내지 않았다 — RPi4로 execute 줄이 가지 않았고 아무 버튼도 누르지 않았다.
    assert _executes(link) == []
    assert link["grbl"].commands == []
    # 결과: 정지·수신 not_dispatched — '성공'이 아니다.
    assert snap.last_result.status is ExecutionStatus.SAFETY_STOPPED
    assert outcome_of(snap.last_result) is ExecutionOutcome.STOPPED
    assert snap.last_receipt == "not_dispatched"
    # 이력·보호자 알림·완료 이벤트는 다른 정지된 실행과 같이 남는다.
    entry = history.recent()[0]
    assert entry.job_id == job_id
    assert entry.termination is Termination.STOPPED_BY_USER
    assert entry.receipt == "not_dispatched" and entry.outcome == "stopped"
    assert [e.kind for e in care.recent()] == ["emergency_stop"]
    assert len(events) == 1
    assert events[0].status == "safety_stopped" and events[0].receipt is Receipt.NOT_DISPATCHED


def test_approved_card_stop_before_dispatch_is_stopped_not_dispatched(link):
    """승인 카드(명령 경로)도 같은 실행 함수를 지난다 — 단계 시작 확인 뒤에 온 정지."""
    service, controller, history, care, events = _service(link, "arm")
    now = datetime(2026, 10, 15, 12, tzinfo=timezone.utc)
    approved = (ApprovedCommand(Command.physical("microwave", BUTTONS), "card-1", now, "전자레인지 b1 → b2 → b3"),)

    record = service.execute_approved(approved)

    assert controller.fired
    assert _executes(link) == [] and link["grbl"].commands == []
    (result,) = record.results
    assert result.status is CommandStatus.STOPPED
    assert result.receipt is Receipt.NOT_DISPATCHED
    assert result.stop_requested is True
    assert "보내지 않았어요" in result.detail
    assert history.recent()[0].receipt == "not_dispatched"
    assert [e.kind for e in care.recent()] == ["emergency_stop"]
    assert events and events[-1].receipt is Receipt.NOT_DISPATCHED


def test_idle_stop_before_a_run_does_not_poison_the_next_uart_run(link):
    """쉬는 중 정지는 다음 실행을 막지 않는다 — 실행 시작이 RPi4 링크의 정지 표시도 지운다."""
    service, controller, history, _care, _events = _service(link, "never")

    service.emergency_stop()  # 실행 중인 작업 없음
    job_id = service.submit_purpose("테스트")
    snap = _wait_done(service, job_id)

    assert snap.last_result.status is ExecutionStatus.SUCCEEDED
    assert len(_executes(link)) == 1
    assert len(link["grbl"].commands) == len(BUTTONS)
