"""프로필 판정으로 실행 전 거절 · 세탁기 원격 시작 조건 (2026-10-13, 단계 3, SDK 없이).

실행기(``ThinqController``)는 보내기 전에 기기 프로필을 읽어
- 그 속성이 프로필에 있는가, 쓰기 모드인가, 그 값이 쓰기 값 목록에 있는가
- (세탁기) 원격 제어가 켜져 있는가
를 보고, 하나라도 아니면 **보내지 않는다**(failed / not_dispatched / 사람 말 이유).
모두 모의 클라이언트다 -- 실제 클라우드·실가전 아님.
"""

from __future__ import annotations

from rpi.commands import Command, CommandStatus, Confirmation, Receipt
from rpi.services.thinq import (
    MOCK_PURIFIER_ID,
    MOCK_WASHER_ID,
    MockThinqClient,
    ThinqController,
    ThinqMode,
    air_purifier_binding,
    washer_binding,
)
from rpi.services.thinq.profiles_sample import air_purifier_profile, washer_profile


def _controller(client=None, *, washer=False):
    client = client or MockThinqClient()
    bindings = {"air_purifier": air_purifier_binding(MOCK_PURIFIER_ID),
                "thinq_washer": washer_binding(MOCK_WASHER_ID)}
    ctrl = ThinqController(client, bindings.get, mode=ThinqMode.MOCK, confirm_seconds=0.05,
                           poll_interval=0.0, sleep=lambda s: None)
    return ctrl, client


def _job(mode):
    return Command.thinq("air_purifier", "set_job_mode", {"job_mode": mode})


def _wash(op):
    return Command.thinq("thinq_washer", "set_operation", {"operation": op})


def _not_sent(result):
    return (result.status is CommandStatus.FAILED and result.receipt is Receipt.NOT_DISPATCHED
            and result.confirmation is Confirmation.NONE)


# ── 프로필 판정 ────────────────────────────────────────────────────────────


def test_value_missing_from_profile_write_list_is_refused_before_sending():
    ctrl, client = _controller()
    client.set_profile(MOCK_PURIFIER_ID, air_purifier_profile(job_modes_w=("CLEAN", "SLEEP")))
    result = ctrl.execute_command(_job("SILENT"))
    assert _not_sent(result)
    assert result.detail == "이 가전은 운전 모드 저소음을 쓸 수 없어요. 그래서 보내지 않았어요."
    assert client.controls == []
    # 프로필이 허용하는 값은 보낸다.
    assert ctrl.execute_command(_job("SLEEP")).status is CommandStatus.SUCCEEDED


def test_property_missing_from_profile_is_refused():
    ctrl, client = _controller()
    profile = air_purifier_profile()
    del profile["property"]["airFlow"]
    client.set_profile(MOCK_PURIFIER_ID, profile)
    result = ctrl.execute_command(Command.thinq("air_purifier", "set_wind_strength",
                                                {"wind_strength": "HIGH"}))
    assert _not_sent(result) and "바람 세기" in result.detail and "없어" in result.detail
    assert client.controls == []


def test_read_only_property_is_refused():
    ctrl, client = _controller()
    profile = air_purifier_profile()
    profile["property"]["operation"]["airPurifierOperationMode"]["mode"] = ["r"]
    client.set_profile(MOCK_PURIFIER_ID, profile)
    result = ctrl.execute_command(Command.thinq("air_purifier", "set_power", {"power": "POWER_ON"}))
    assert _not_sent(result) and "쓸 수 없" in result.detail
    assert client.controls == []


def test_preferred_wind_key_from_profile_is_used_in_payload():
    """SDK처럼 airFlow에 windStrengthDetail이 있으면 그 키로 보낸다."""
    ctrl, client = _controller()
    client.set_profile(MOCK_PURIFIER_ID, air_purifier_profile(wind_key="windStrengthDetail"))
    result = ctrl.execute_command(Command.thinq("air_purifier", "set_wind_strength",
                                                {"wind_strength": "HIGH"}))
    assert result.status is CommandStatus.SUCCEEDED
    assert client.controls == [(MOCK_PURIFIER_ID, {"airFlow": {"windStrengthDetail": "HIGH"}})]


def test_profile_unreadable_means_not_sent():
    ctrl, client = _controller()
    client.set_online(False)
    result = ctrl.execute_command(_job("SLEEP"))
    assert _not_sent(result) and client.controls == []


def test_cloud_rejection_detail_is_human_reason():
    ctrl, client = _controller()
    client.fail_next_control("reject")
    result = ctrl.execute_command(_job("SLEEP"))
    assert result.status is CommandStatus.FAILED and result.receipt is Receipt.ACCEPTED
    assert "모드" in result.detail and "2305" not in result.detail  # 코드는 화면에 내지 않는다(10/17)


def test_profile_support_lists_what_the_model_allows():
    ctrl, client = _controller()
    client.set_profile(MOCK_PURIFIER_ID, air_purifier_profile(job_modes_w=("CLEAN",)))
    support = ctrl.profile_support("air_purifier")
    assert support["set_job_mode"]["allowed"] == ["CLEAN"]
    assert support["set_wind_strength"]["allowed"] == ["LOW", "MID", "HIGH", "AUTO"]
    assert support["set_wind_strength"]["property"] == "windStrength"


# ── 세탁기: 시작·일시정지와 원격 시작 조건 ──────────────────────────────────


def test_washer_start_refused_when_remote_control_is_off():
    ctrl, client = _controller()
    client.set_remote_control(False)
    result = ctrl.execute_command(_wash("START"))
    assert _not_sent(result)
    assert "원격" in result.detail
    assert client.controls == []
    readiness = ctrl.readiness("thinq_washer")
    assert readiness.state == "needs_setup" and not readiness.can_execute
    assert any("원격" in r for r in readiness.reasons)


def test_washer_start_and_pause_confirmed_by_run_state():
    ctrl, client = _controller()
    client.set_remote_control(True)
    client.inject_event("wash_complete")  # 모의 세탁기는 '진행 중'으로 시작한다 -- 끝난 상태에서 시작
    assert ctrl.readiness("thinq_washer").can_execute
    started = ctrl.execute_command(_wash("START"))
    assert started.status is CommandStatus.SUCCEEDED
    assert started.confirmation is Confirmation.STATE_CONFIRMED
    assert client.controls[-1] == (MOCK_WASHER_ID, {
        "location": {"locationName": "MAIN"}, "operation": {"washerOperationMode": "START"}})
    paused = ctrl.execute_command(_wash("STOP"))
    assert paused.status is CommandStatus.SUCCEEDED
    assert client.get_status(MOCK_WASHER_ID)["runState"]["currentState"] == "PAUSE"


def test_washer_start_while_already_running_is_not_sent():
    # 2026-10-14: 이미 진행 중이면 시작을 보내지 않는다(already_at_target) — 시작했다고 말하지 않는다.
    ctrl, client = _controller()
    client.set_remote_control(True)
    client.inject_event("wash_start")
    sent = len(client.controls)
    result = ctrl.execute_command(_wash("START"))
    assert result.status is CommandStatus.SUCCEEDED and result.receipt is Receipt.NOT_DISPATCHED
    assert result.confirmation is Confirmation.ALREADY_AT_TARGET
    assert result.detail == "이미 운전 시작으로 설정돼 있어요. 그래서 보내지 않았어요."
    assert len(client.controls) == sent


def test_washer_value_not_in_profile_is_refused():
    ctrl, client = _controller()
    client.set_remote_control(True)
    client.set_profile(MOCK_WASHER_ID, washer_profile(operation_w=("STOP", "POWER_OFF")))
    result = ctrl.execute_command(_wash("START"))
    assert _not_sent(result) and "쓸 수 없어요" in result.detail
    assert client.controls == []
