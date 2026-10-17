"""이미 목표값(2026-10-14 보드 날 발견 3): 공기청정기가 이미 강풍인데 강풍으로 제어하면 보내지 않는다.

확인한 사실만큼 네 경우를 가른다(제어 요청 횟수와 문장을 함께 본다):

- 보내기 전부터 목표값 → 제어 요청 0회, ``succeeded``·``not_dispatched``·``already_at_target``,
  "이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요."
- 보내기 전 다른 값 → 1회, 재조회 목표값 → ``state_confirmed``, "강풍으로 바꿨어요."
- 보내기 전 조회 실패·값 없음 → 최대 1회, 재조회 목표값 → ``state_confirmed_unknown_before``,
  "강풍으로 설정된 것을 확인했어요."('바꿨어요' 금지 — 원래 강풍이었을 수 있다)
- 보낸 뒤 상태 확인 실패 → 1회, 추가 전송 0회, ``unconfirmed``, "설정이 바뀌었는지 확인하지 못했어요."

'이미 목표값'도 정지·전송 직전 재판정·전송권 확인을 모두 지난 뒤에만 나온다. 꺼진 규칙이면 성공이 아니라 차단 기록이다.
보내지 않으므로 전송권은 '전송 개시'로 표시하지 않는다(``will_send=False``).
"""

from __future__ import annotations

import threading
import time

import pytest
from fastapi.testclient import TestClient

from rpi.commands import Command, CommandResult, CommandStatus, Confirmation, Receipt
from rpi.controller.models import ExecutionMode
from rpi.services.thinq import MOCK_PURIFIER_ID, MockThinqClient
from rpi.services.thinq.client import ThinqClientError, ThinqCommandRejected, ThinqTransportError
from rpi.services.thinq.wording import already_sentence, changed_sentence, dispatch_of
from rpi.tests.test_thinq_u1 import HIGH, _controller

ALREADY = "이미 바람 세기 강으로 설정돼 있어요. 그래서 보내지 않았어요."
CHANGED = "바람 세기 강으로 바꿨어요."
TARGET_SEEN = "바람 세기 강으로 설정된 것을 확인했어요."
UNCONFIRMED = "설정이 바뀌었는지 몰라요."

# ── 값 객체 ─────────────────────────────────────────────────────────────


def _result(status, receipt, confirmation, command=HIGH, **kw):
    return CommandResult(command, status, receipt, confirmation, ExecutionMode.MOCK, **kw)


def test_already_at_target_is_a_success_without_dispatch():
    out = _result(CommandStatus.SUCCEEDED, Receipt.NOT_DISPATCHED, Confirmation.ALREADY_AT_TARGET)
    assert out.confirmation.value == "already_at_target"
    # 가전 상태를 바꾼 것을 본 것이 아니다 — '상태 변경 확인'으로 세지 않는다.
    assert not out.confirmation.confirms_appliance
    assert out.confirmation.reached_target


def test_already_at_target_only_pairs_with_succeeded_and_not_dispatched():
    for status, receipt in ((CommandStatus.SUCCEEDED, Receipt.ACCEPTED),
                            (CommandStatus.UNCONFIRMED, Receipt.UNKNOWN),
                            (CommandStatus.FAILED, Receipt.NOT_DISPATCHED),
                            (CommandStatus.STOPPED, Receipt.NOT_DISPATCHED)):
        with pytest.raises(ValueError):
            _result(status, receipt, Confirmation.ALREADY_AT_TARGET)
    # 보내지 않은 결과의 성공은 '이미 목표값'일 때뿐이다.
    with pytest.raises(ValueError):
        _result(CommandStatus.SUCCEEDED, Receipt.NOT_DISPATCHED, Confirmation.STATE_CONFIRMED)
    # 물리 경로는 가전 상태를 조회하지 않는다.
    with pytest.raises(ValueError):
        _result(CommandStatus.SUCCEEDED, Receipt.NOT_DISPATCHED, Confirmation.ALREADY_AT_TARGET,
                command=Command.physical("microwave", ["시작"]))


def test_target_seen_with_unknown_before_needs_an_accepted_send():
    out = _result(CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED_UNKNOWN_BEFORE)
    assert out.confirmation.reached_target and not out.confirmation.confirms_appliance
    with pytest.raises(ValueError):
        _result(CommandStatus.SUCCEEDED, Receipt.NOT_DISPATCHED, Confirmation.STATE_CONFIRMED_UNKNOWN_BEFORE)
    with pytest.raises(ValueError):
        _result(CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED_UNKNOWN_BEFORE)
    with pytest.raises(ValueError):
        _result(CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED_UNKNOWN_BEFORE,
                command=Command.physical("microwave", ["시작"]))


def test_dispatch_field_separates_sent_from_state_only():
    assert dispatch_of("not_dispatched", "already_at_target") == "state_only"
    assert dispatch_of("accepted", "state_confirmed") == "sent"
    assert dispatch_of("accepted", "none") == "sent"
    assert dispatch_of("not_dispatched", "none") == "not_sent"
    assert dispatch_of("unknown", "none") == "unknown"


def test_other_property_names_its_setting():
    from rpi.services.thinq import air_purifier_binding

    cap = air_purifier_binding(MOCK_PURIFIER_ID).capability("set_job_mode")
    assert changed_sentence(cap.setting_phrase("CLEAN")) == "운전 모드 청정으로 바꿨어요."
    assert already_sentence(cap.setting_phrase("SLEEP")).startswith("이미 운전 모드 수면으로 설정돼 있어요.")


# ── ThinQ 실행기: 네 경우 ─────────────────────────────────────────────────


def test_already_high_sends_nothing_and_says_so():
    ctrl, client = _controller()
    first = ctrl.execute_command(HIGH)
    assert first.confirmation is Confirmation.STATE_CONFIRMED
    again = ctrl.execute_command(HIGH)
    assert len(client.controls) == 1  # 두 번째는 제어 요청 0회
    assert (again.status, again.receipt, again.confirmation) == (
        CommandStatus.SUCCEEDED, Receipt.NOT_DISPATCHED, Confirmation.ALREADY_AT_TARGET)
    assert again.detail == ALREADY
    assert again.accepted_at is None and again.confirmed_at is not None


def test_different_value_before_is_changed_with_one_control():
    ctrl, client = _controller()  # 모의 공기청정기는 약풍으로 시작
    result = ctrl.execute_command(HIGH)
    assert len(client.controls) == 1
    assert (result.status, result.receipt, result.confirmation) == (
        CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED)
    assert result.detail == CHANGED


def test_unconfirmed_after_send_has_no_additional_control():
    ctrl, client = _controller()
    client.drop_state_updates = True
    result = ctrl.execute_command(HIGH)
    assert len(client.controls) == 1  # 추가 전송 0회
    assert result.status is CommandStatus.UNCONFIRMED and result.confirmation is Confirmation.NONE
    assert UNCONFIRMED in result.detail and "바꿨" not in result.detail


def test_unknown_current_value_sends_once_and_says_target_seen():
    class NoAirFlowFirst(MockThinqClient):
        """첫 조회에서만 풍량 칸이 없다(값 모름) — 보내기 전 판정을 못 한다."""

        def __init__(self):
            super().__init__()
            self.reads = 0

        def get_status(self, device_id):
            state = super().get_status(device_id)
            self.reads += 1
            if self.reads == 1:
                state.pop("airFlow", None)
            return state

    client = NoAirFlowFirst()
    client._state[MOCK_PURIFIER_ID]["airFlow"]["windStrength"] = "HIGH"  # 실제로는 이미 강풍이지만 조회가 모름
    ctrl, _ = _controller(client)
    result = ctrl.execute_command(HIGH)
    assert len(client.controls) == 1
    assert result.receipt is Receipt.ACCEPTED
    assert result.confirmation is Confirmation.STATE_CONFIRMED_UNKNOWN_BEFORE
    assert result.detail == TARGET_SEEN  # '바꿨어요' 아님 — 원래 강풍이었을 수 있다


def test_pre_read_failure_sends_at_most_once_and_says_target_seen():
    ctrl, client = _controller()
    ctrl.execute_command(HIGH)  # 이미 강풍
    original = client.get_status
    reads = []

    def first_read_fails(device_id):
        reads.append(1)
        if len(reads) == 1:
            raise ThinqTransportError("boom")
        return original(device_id)

    client.get_status = first_read_fails
    result = ctrl.execute_command(HIGH)
    assert len(client.controls) == 2  # 조회 실패로 1회만 보냈다
    assert result.confirmation is Confirmation.STATE_CONFIRMED_UNKNOWN_BEFORE
    assert result.detail == TARGET_SEEN


def test_pre_read_and_reread_failure_is_unconfirmed_without_additional_control():
    ctrl, client = _controller()

    def broken(device_id):
        raise ThinqTransportError("boom")

    client.get_status = broken
    result = ctrl.execute_command(HIGH)
    assert len(client.controls) == 1  # 최대 1회, 추가 전송 0회
    assert result.status is CommandStatus.UNCONFIRMED and result.confirmation is Confirmation.NONE
    assert UNCONFIRMED in result.detail


@pytest.mark.parametrize("error", [
    ThinqCommandRejected("1218", "invalid token", name="INVALID_TOKEN"),
    ThinqCommandRejected("1314", "not allowed", name="NOT_ALLOWED_API_AGAIN"),
    ThinqClientError("cloud said no", code="1306", name="EXCEEDED_API_CALLS"),
])
def test_cloud_refused_pre_read_does_not_send(error):
    """사전 조회를 클라우드가 코드로 거절(인증·권한·한도)했으면 값을 몰라도 보내지 않는다 -- 보낼 근거가 없다."""
    ctrl, client = _controller()

    def refused(device_id):
        raise error

    client.get_status = refused
    result = ctrl.execute_command(HIGH)
    assert client.controls == []  # 제어 요청 0회
    assert result.receipt is Receipt.NOT_DISPATCHED and result.status is CommandStatus.FAILED
    assert "보내지 않았어요" in result.detail


def test_pre_read_failure_on_remote_gated_washer_still_does_not_send():
    from rpi.tests.test_thinq_profile_gate import _controller as washer_controller
    from rpi.tests.test_thinq_profile_gate import _wash

    ctrl, client = washer_controller()
    client.set_remote_control(True)

    def broken(device_id):
        raise ThinqClientError("boom")

    client.get_status = broken
    result = ctrl.execute_command(_wash("START"))
    assert result.receipt is Receipt.NOT_DISPATCHED and client.controls == []


# ── 정지·재판정·전송권이 먼저 ────────────────────────────────────────────────


def test_stop_before_dispatch_wins_over_already():
    ctrl, client = _controller()
    ctrl.execute_command(HIGH)
    original = client.get_status

    def stop_while_reading(device_id):
        state = original(device_id)
        ctrl.request_stop()
        return state

    client.get_status = stop_while_reading
    result = ctrl.execute_command(HIGH)
    assert result.status is CommandStatus.STOPPED and result.receipt is Receipt.NOT_DISPATCHED
    assert len(client.controls) == 1


def test_guard_and_send_right_come_first_and_already_is_not_marked_as_sending():
    ctrl, client = _controller()
    ctrl.execute_command(HIGH)
    calls = []

    def blocking_guard(binding):
        raise RuntimeError("자동 실행이 꺼져 보내지 않았어요")

    blocked = ctrl.execute_command(HIGH, dispatch_guard=blocking_guard)
    assert blocked.status is CommandStatus.FAILED and blocked.detail == "자동 실행이 꺼져 보내지 않았어요"
    assert blocked.confirmation is Confirmation.NONE

    def guard(binding):
        calls.append("guard")
        return lambda will_send=True: calls.append(("commit", will_send))

    result = ctrl.execute_command(HIGH, dispatch_guard=guard)
    assert result.confirmation is Confirmation.ALREADY_AT_TARGET
    # 전송권 확인은 거치되(철회·꺼짐이 먼저면 걸림) 보내지 않으므로 '전송 개시'로 표시하지 않는다.
    assert calls == ["guard", ("commit", False)]

    def revoked(binding):
        def commit(will_send=True):
            raise RuntimeError("자동 실행이 꺼져 보내지 않았어요")
        return commit

    after_revoke = ctrl.execute_command(HIGH, dispatch_guard=revoked)
    assert after_revoke.status is CommandStatus.FAILED and after_revoke.receipt is Receipt.NOT_DISPATCHED
    assert after_revoke.confirmation is Confirmation.NONE  # 이미 목표값이어도 성공으로 남기지 않는다
    assert len(client.controls) == 1


# ── 모의 클라우드 끝-끝(공식 SDK) ─────────────────────────────────────────

thinq_sdk = pytest.importorskip("thinqconnect")

from rpi.tests.test_auto_rule_e2e import _allow, _env, _set_low, _wait_run  # noqa: E402
from rpi.tests.test_cook_done_card import _cards, _inject, _reset, _wait_done  # noqa: E402
from rpi.tools.fake_thinq_cloud import FakeThinqCloud  # noqa: E402


@pytest.fixture()
def cloud():
    fake = FakeThinqCloud()
    fake.start()
    yield fake
    fake.stop()


def test_auto_rule_on_already_high_purifier_sends_no_control(monkeypatch, tmp_path, cloud):
    from rpi.api import deps
    from rpi.tests.test_auto_rules import _frame

    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        device = cloud.device_id("air_purifier")
        _allow(api)  # 이번 실행 → 강풍, 다음부터 자동으로
        assert cloud.state(device)["airFlow"]["windStrength"] == "HIGH"
        before = len(cloud.controls())

        frame = _frame()
        deps.receive_appliance_done(dict(frame))  # 반복 시연: 이미 강풍인데 다시 조리 완료
        run = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("status"))
        time.sleep(0.3)
        assert len(cloud.controls()) == before  # 제어 요청 0회
        assert (run["status"], run["receipt"], run["confirmation"], run["dispatch"], run["execution_mode"]) == (
            "succeeded", "not_dispatched", "already_at_target", "state_only", "mock")
        notices = " / ".join(run["notices"])
        assert ("공기청정기(모의 클라우드)는 이미 바람 세기 강으로 설정돼 있어요. 그래서 보내지 않았어요."
                " 연습이라 실제 가전은 그대로예요.") in notices  # 연습 표시 유지
        assert "바꿨어요" not in notices and "확인하지 못했어요" not in notices
        assert "보내지 못했어요" not in notices
        assert "보냈어요" not in run["reason"]

        auto = api.get("/status").json()["last_auto_run"]
        assert (auto["status"], auto["confirmation"], auto["dispatch"], auto["value_phrase"]) == (
            "succeeded", "already_at_target", "state_only", "바람 세기 강")
        history = api.get("/history").json()[0]
        assert (history["outcome"], history["confirmation"], history["receipt"], history["dispatch"]) == (
            "success", "already_at_target", "not_dispatched", "state_only")
        care = " / ".join(e["message"] for e in api.get("/care-events").json())
        assert "확인하지 못했어요" not in care and "실행되지 않았어요" not in care

        # 같은 사건 1회: 처리 완료로 남아 다시 받아도 실행하지 않는다.
        deps.receive_appliance_done(dict(frame))
        _wait_run(api, lambda r: r["outcome"] == "duplicate")
        time.sleep(0.3)
        assert len(cloud.controls()) == before

        # 약풍으로 되돌린 뒤 새 사건은 보내고 재조회로 '바꿨어요'(자동 실행 제어 요청 1회).
        _set_low(api)
        deps.receive_appliance_done(_frame())
        changed = _wait_run(api, lambda r: r["outcome"] == "sent" and r.get("confirmation") == "state_confirmed")
        assert "공기청정기(모의 클라우드)를 바람 세기 강으로 바꿨어요." in " / ".join(changed["notices"])
        assert changed["dispatch"] == "sent"
        assert len(cloud.controls()) == before + 2  # 약풍 되돌리기 1 + 자동 실행 1
        assert cloud.state(device)["airFlow"]["windStrength"] == "HIGH"
    finally:
        _reset()


def test_approved_card_on_already_high_purifier_sends_no_control(monkeypatch, tmp_path, cloud):
    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        device = cloud.device_id("air_purifier")
        _inject(api, inputs=("power",))
        first = _cards(api)[0]
        res = api.post(f"/suggestions/{first['id']}/approve")
        assert res.status_code == 200, res.text
        done = _wait_done(api, res.json()["job_id"], timeout=10)
        assert done["last_confirmation"] == "state_confirmed" and done["last_detail"] == CHANGED
        before = len(cloud.controls())

        _inject(api, inputs=("power",))  # 같은 카드를 다시 승인(이번만 실행)
        second = _cards(api)[0]
        res = api.post(f"/suggestions/{second['id']}/approve")
        assert res.status_code == 200, res.text
        status = _wait_done(api, res.json()["job_id"], timeout=10)
        assert len(cloud.controls()) == before  # 제어 요청 0회
        assert (status["last_outcome"], status["last_receipt"], status["last_confirmation"]) == (
            "success", "not_dispatched", "already_at_target")
        assert status["last_detail"] == ALREADY
        assert status["last_execution_mode"] == "mock"
        assert api.get("/history").json()[0]["dispatch"] == "state_only"
        assert cloud.state(device)["airFlow"]["windStrength"] == "HIGH"
    finally:
        _reset()


def test_disabled_rule_with_already_high_purifier_is_recorded_as_blocked(monkeypatch, tmp_path, cloud):
    """꺼진 규칙 + 이미 목표값 → 성공이 아니라 차단 기록(제어 요청 0회). 판단 뒤 상태 조회 중에 사용자가 끈 경우."""
    from rpi.api import deps
    from rpi.services.thinq import sdk_client
    from rpi.tests.test_auto_rules import _frame

    _env(monkeypatch, tmp_path, cloud)
    _reset()
    from rpi.main import app

    try:
        api = TestClient(app)
        _allow(api)  # 강풍
        rule = api.get("/routines/auto-rules").json()[0]
        before = len(cloud.controls())
        armed, done = threading.Event(), threading.Event()
        original = sdk_client.SdkThinqClient.get_status

        def read_then_disable(client, device_id):
            state = original(client, device_id)
            if armed.is_set() and not done.is_set():
                done.set()
                res = api.post(f"/routines/auto-rules/{rule['id']}/enable", json={"enabled": False})
                assert res.status_code == 200, res.text
            return state

        monkeypatch.setattr(sdk_client.SdkThinqClient, "get_status", read_then_disable)
        armed.set()
        deps.receive_appliance_done(_frame())
        run = _wait_run(api, lambda r: r.get("job_id") and r.get("status"))
        assert done.is_set()
        assert (run["outcome"], run["status"], run["confirmation"], run["dispatch"]) == (
            "blocked", "failed", "none", "not_sent")
        assert "꺼져" in run["reason"]
        notices = " / ".join(run["notices"])
        assert "이미" not in notices and "바꿨어요" not in notices
        time.sleep(0.3)
        assert len(cloud.controls()) == before
        assert api.get("/history").json()[0]["outcome"] != "success"
    finally:
        _reset()
