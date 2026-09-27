"""Command·CommandResult·ApprovedCommand 값 객체의 불변 조건 (U1-a)."""

from dataclasses import FrozenInstanceError
from datetime import datetime, timedelta, timezone

import pytest

from rpi.api.schemas import MAX_BUTTONS_PER_RUN
from rpi.commands import (
    PHYSICAL_PRESS_ACTION,
    ApprovedCommand,
    ArgumentError,
    Command,
    CommandResult,
    CommandStatus,
    Confirmation,
    ControlRoute,
    Receipt,
)
from rpi.controller.models import (
    ButtonResult,
    ButtonStatus,
    ExecutionMode,
    ExecutionResult,
    ExecutionStatus,
)

KST = timezone(timedelta(hours=9))
NOW = datetime(2026, 9, 27, 14, 0, tzinfo=KST)


# ── Command ──────────────────────────────────────────────────────────────────

def test_physical_command_wraps_button_sequence():
    cmd = Command.physical("microwave", ["즉석밥", "시작"])
    assert cmd.route is ControlRoute.PHYSICAL
    assert cmd.action == PHYSICAL_PRESS_ACTION
    assert cmd.buttons == ("즉석밥", "시작")
    assert cmd.args == ()
    assert len(cmd.fingerprint) == 64


def test_thinq_command_normalizes_args_into_sorted_tuple():
    cmd = Command.thinq("purifier", "fan_speed", {"level": 3, "auto": False})
    assert cmd.route is ControlRoute.THINQ
    assert cmd.args == (("auto", False), ("level", 3))
    assert cmd.buttons == ()
    copy = cmd.args_dict()
    copy["level"] = 99
    assert cmd.args_dict() == {"auto": False, "level": 3}


def test_command_is_frozen_including_fingerprint():
    cmd = Command.thinq("purifier", "power", {"on": True})
    with pytest.raises(FrozenInstanceError):
        cmd.action = "fan_speed"  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        cmd.fingerprint = "0" * 64  # type: ignore[misc]


def test_direct_construction_normalizes_mapping_args_too():
    a = Command("p", ControlRoute.THINQ, "set", {"y": 2, "x": 1}, ())
    b = Command.thinq("p", "set", [("x", 1), ("y", 2)])
    assert a == b and a.fingerprint == b.fingerprint


def test_same_content_compares_fingerprint_only():
    a = Command.thinq("purifier", "fan_speed", {"level": 3})
    b = Command.thinq("purifier", "fan_speed", {"level": 3})
    c = Command.thinq("purifier", "fan_speed", {"level": 4})
    assert a.same_content(b)
    assert not a.same_content(c)  # '풍량 약' 승인 후 '풍량 강' 실행 금지의 근거


def test_physical_command_rejects_args_and_wrong_action():
    with pytest.raises(ValueError, match="args"):
        Command("mw", ControlRoute.PHYSICAL, PHYSICAL_PRESS_ACTION, {"x": 1}, ("시작",))
    with pytest.raises(ValueError, match=PHYSICAL_PRESS_ACTION):
        Command("mw", ControlRoute.PHYSICAL, "fan_speed", (), ("시작",))


def test_thinq_command_rejects_buttons():
    with pytest.raises(ValueError, match="buttons"):
        Command("p", ControlRoute.THINQ, "power", (), ("시작",))


def test_physical_command_reuses_existing_sequence_limits():
    with pytest.raises(ValueError, match="at least one"):
        Command.physical("mw", [])
    with pytest.raises(ValueError, match="limit"):
        Command.physical("mw", ["시작"] * (MAX_BUTTONS_PER_RUN + 1))
    with pytest.raises(ValueError, match="label"):
        Command.physical("mw", ["시작", " "])
    with pytest.raises(ValueError, match="label"):
        Command.physical("mw", ["x" * 41])


@pytest.mark.parametrize("target", ["", " ", " mw", "mw ", "x" * 65])
def test_target_id_must_be_clean(target):
    with pytest.raises(ValueError, match="target_id"):
        Command.physical(target, ["시작"])


@pytest.mark.parametrize("action", ["", "Fan", "fan speed", "1x", "풍량"])
def test_action_name_rule(action):
    with pytest.raises(ValueError, match="action"):
        Command.thinq("p", action, {})


def test_invalid_args_surface_as_argument_error():
    with pytest.raises(ArgumentError):
        Command.thinq("p", "fan_speed", {"level": float("nan")})


def test_route_accepts_plain_string_and_coerces():
    cmd = Command("p", "thinq", "power", {}, ())
    assert cmd.route is ControlRoute.THINQ
    with pytest.raises(ValueError):
        Command("p", "cloud", "power", {}, ())


# ── Receipt / Confirmation 의미 ─────────────────────────────────────────────

def test_receipt_and_confirmation_are_separate_axes():
    assert {r.value for r in Receipt} == {"not_dispatched", "unknown", "accepted"}
    assert Confirmation.NONE.value == "none"
    assert not Confirmation.REPORTED.has_evidence  # 보고는 근거가 아니다
    assert Confirmation.PRESS_CONFIRMED.has_evidence
    # 결정 1: L1 눌림은 가전 쪽 사실이 아니다.
    assert not Confirmation.PRESS_CONFIRMED.confirms_appliance
    assert Confirmation.STATE_CONFIRMED.confirms_appliance
    assert Confirmation.OPERATION_CONFIRMED.confirms_appliance


def test_command_status_has_unconfirmed_as_its_own_value():
    assert CommandStatus.UNCONFIRMED.value == "unconfirmed"
    assert CommandStatus.UNCONFIRMED is not CommandStatus.FAILED


# ── CommandResult 조합 규칙 ──────────────────────────────────────────────────

PHYS = Command.physical("microwave", ["즉석밥", "시작"])
CLOUD = Command.thinq("purifier", "fan_speed", {"level": 3})


def _result(command, status, receipt, confirmation, **kw):
    return CommandResult(command, status, receipt, confirmation, ExecutionMode.MOCK, **kw)


def test_succeeded_requires_accepted_receipt_and_a_confirmation():
    _result(CLOUD, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED)
    _result(CLOUD, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.REPORTED)
    with pytest.raises(ValueError, match="succeeded"):
        _result(CLOUD, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.NONE)
    with pytest.raises(ValueError, match="succeeded"):
        _result(CLOUD, CommandStatus.SUCCEEDED, Receipt.UNKNOWN, Confirmation.STATE_CONFIRMED)


def test_state_observation_does_not_imply_receipt():
    # 가전 상태가 목표와 같은 것을 봤지만 내 명령이 접수됐는지는 모른다 --
    # 명령 전에 이미 그 상태였을 수 있다(9/27 S3 사례 4). 성공이 아니라 미확인.
    out = _result(CLOUD, CommandStatus.UNCONFIRMED, Receipt.UNKNOWN, Confirmation.STATE_CONFIRMED)
    assert out.receipt is Receipt.UNKNOWN and out.confirmation.confirms_appliance
    with pytest.raises(ValueError, match="unknown receipt"):
        _result(CLOUD, CommandStatus.FAILED, Receipt.UNKNOWN, Confirmation.STATE_CONFIRMED)


def test_unknown_receipt_is_only_unconfirmed():
    _result(CLOUD, CommandStatus.UNCONFIRMED, Receipt.UNKNOWN, Confirmation.NONE)
    for status in (CommandStatus.FAILED, CommandStatus.STOPPED, CommandStatus.SUCCEEDED):
        with pytest.raises(ValueError):
            _result(CLOUD, status, Receipt.UNKNOWN, Confirmation.NONE)


def test_not_dispatched_is_failed_or_stopped_only():
    _result(CLOUD, CommandStatus.STOPPED, Receipt.NOT_DISPATCHED, Confirmation.NONE)  # 미전송 취소
    _result(CLOUD, CommandStatus.FAILED, Receipt.NOT_DISPATCHED, Confirmation.NONE)   # 전송 전 실패
    with pytest.raises(ValueError, match="not_dispatched"):
        _result(CLOUD, CommandStatus.UNCONFIRMED, Receipt.NOT_DISPATCHED, Confirmation.NONE)


def test_accepted_and_confirmed_cannot_be_unconfirmed():
    _result(CLOUD, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, Confirmation.NONE)
    with pytest.raises(ValueError, match="unconfirmed"):
        _result(CLOUD, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED)


def test_timestamps_follow_receipt_and_confirmation():
    with pytest.raises(ValueError, match="accepted_at"):
        _result(CLOUD, CommandStatus.UNCONFIRMED, Receipt.UNKNOWN, Confirmation.NONE, accepted_at=NOW)
    with pytest.raises(ValueError, match="confirmed_at"):
        _result(CLOUD, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, Confirmation.NONE, confirmed_at=NOW)
    ok = _result(CLOUD, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED, Confirmation.NONE,
                 accepted_at=NOW, observed_at=NOW + timedelta(seconds=3))
    assert ok.accepted_at == NOW and ok.observed_at > ok.accepted_at
    naive = NOW.replace(tzinfo=None)
    for name in ("requested_at", "accepted_at", "confirmed_at", "observed_at"):
        with pytest.raises(ValueError, match="timezone"):
            _result(CLOUD, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED,
                    **{name: naive})


def test_route_specific_confirmations():
    with pytest.raises(ValueError, match="press_confirmed"):
        _result(PHYS, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED)
    with pytest.raises(ValueError, match="thinq"):
        _result(CLOUD, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.PRESS_CONFIRMED)
    with pytest.raises(ValueError, match="thinq"):
        _result(CLOUD, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.OPERATION_CONFIRMED)


def test_physical_evidence_only_on_physical_route():
    evidence = ExecutionResult(
        ExecutionStatus.SUCCEEDED,
        (ButtonResult("즉석밥", ButtonStatus.SUCCEEDED, 1, None),),
    )
    with pytest.raises(ValueError, match="physical"):
        _result(CLOUD, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.STATE_CONFIRMED,
                physical=evidence)
    ok = _result(PHYS, CommandStatus.SUCCEEDED, Receipt.ACCEPTED, Confirmation.REPORTED,
                 physical=evidence)
    assert ok.buttons == evidence.buttons
    assert ok.route is ControlRoute.PHYSICAL


def test_execution_mode_is_independent_of_confirmation():
    # 모의 서버도 상태 확인을 낼 수 있고, 실제 클라우드도 미확인일 수 있다(계약 §1).
    mock_confirmed = CommandResult(CLOUD, CommandStatus.SUCCEEDED, Receipt.ACCEPTED,
                                   Confirmation.STATE_CONFIRMED, ExecutionMode.MOCK)
    real_unconfirmed = CommandResult(CLOUD, CommandStatus.UNCONFIRMED, Receipt.ACCEPTED,
                                     Confirmation.NONE, ExecutionMode.REAL)
    assert mock_confirmed.execution_mode is ExecutionMode.MOCK
    assert real_unconfirmed.execution_mode is ExecutionMode.REAL


# ── ApprovedCommand ─────────────────────────────────────────────────────────

def test_approval_binds_to_command_content():
    approved = ApprovedCommand(CLOUD, "ap-1", NOW, "공기청정기 풍량 3")
    assert approved.matches(Command.thinq("purifier", "fan_speed", {"level": 3}))
    assert not approved.matches(Command.thinq("purifier", "fan_speed", {"level": 4}))


def test_approval_expiry_uses_server_clock():
    approved = ApprovedCommand(CLOUD, "ap-1", NOW, "요약", expires_at=NOW + timedelta(minutes=15))
    assert not approved.is_expired(NOW + timedelta(minutes=14))
    assert approved.is_expired(NOW + timedelta(minutes=15))
    with pytest.raises(ValueError, match="timezone"):
        approved.is_expired(NOW.replace(tzinfo=None))
    assert not ApprovedCommand(CLOUD, "ap-2", NOW, "요약").is_expired(NOW + timedelta(days=99))


@pytest.mark.parametrize("kw,match", [
    (dict(approval_id=" "), "approval_id"),
    (dict(shown_summary=""), "shown_summary"),
    (dict(shown_summary="x" * 121), "shown_summary"),
    (dict(approved_at=NOW.replace(tzinfo=None)), "approved_at"),
    (dict(expires_at=NOW), "expires_at"),
    (dict(expires_at=(NOW + timedelta(minutes=1)).replace(tzinfo=None)), "expires_at"),
])
def test_approval_invariants(kw, match):
    base = dict(command=CLOUD, approval_id="ap-1", approved_at=NOW, shown_summary="요약")
    base.update(kw)
    with pytest.raises(ValueError, match=match):
        ApprovedCommand(**base)
