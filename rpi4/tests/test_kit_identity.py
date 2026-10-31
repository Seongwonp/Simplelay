"""세트 정체·보고와 CT가 허브가 알린 가전을 따라가는지."""

from __future__ import annotations

import json
from types import SimpleNamespace

import pytest

from rpi4.models.act_messages import ExecuteMsg, KitQueryMsg, parse_act_message
from rpi4.services.kit_identity import kit_reporter, load_kit_id
from rpi4.services.target_binding import TargetBinder, TargetRefused


def test_kit_id_is_generated_once_and_kept(tmp_path):
    env = {"SIMPLELAY_ACT_DATA_DIR": str(tmp_path)}
    first = load_kit_id(env)
    assert first.startswith("kit-") and load_kit_id(env) == first
    assert (tmp_path / "kit_id").read_text(encoding="ascii").strip() == first


def test_env_override_wins_and_bad_value_refused(tmp_path):
    assert load_kit_id({"SIMPLELAY_KIT_ID": "kit_table", "SIMPLELAY_ACT_DATA_DIR": str(tmp_path)}) == "kit_table"
    with pytest.raises(RuntimeError):
        load_kit_id({"SIMPLELAY_KIT_ID": "kit 1"})


def test_missing_data_dir_gives_a_stable_id_and_creates_nothing(tmp_path):
    env = {"SIMPLELAY_ACT_DATA_DIR": str(tmp_path / "none")}
    assert load_kit_id(env) == load_kit_id(env)
    assert not (tmp_path / "none").exists()


def _motion(*, homed, link=None, reconnect=False):
    return SimpleNamespace(homed=homed, needs_reconnect=reconnect, link_not_ready_reason=lambda: link)


def test_report_is_live_not_configured():
    outlet = SimpleNamespace(not_ready_reason=lambda: "콘센트가 응답하지 않아요")
    motion = _motion(homed=False)
    report = kit_reporter("kit-a", motion_kind="serial", outlet_kind="real", motion=motion, outlet=outlet,
                          estop_ignored=False)()
    assert report["motion_present"] is True and report["motion_homed"] is False
    assert report["outlet"] == "real" and report["outlet_present"] is False
    assert report["estop_button"] == "in_use"


def test_report_motion_lost_and_estop_ignored():
    report = kit_reporter("kit-a", motion_kind="serial", outlet_kind="real", motion=_motion(homed=True, link="끊김"),
                          outlet=SimpleNamespace(not_ready_reason=lambda: None), estop_ignored=True)()
    assert report["motion_present"] is False and report["outlet_present"] is True
    assert report["estop_button"] == "not_used"


def test_report_serial_without_client_never_claims_homed():
    report = kit_reporter("k", motion_kind="serial", outlet_kind="none", motion=None, outlet=None,
                          estop_ignored=False)()
    assert report["motion_present"] is False and report["motion_homed"] is None
    assert report["estop_button"] == "none"


def _execute(**extra):
    return json.dumps({"type": "execute", "sequence_id": "s", "buttons": ["전원"], "appliance_id": "custom_fan", **extra})


def test_execute_press_appliance_must_match_target():
    assert parse_act_message(_execute(press_appliance="custom_fan")).press_appliance == "custom_fan"
    assert parse_act_message(_execute(press_appliance="microwave")).press_appliance is None
    msg = parse_act_message(_execute())
    assert isinstance(msg, ExecuteMsg) and msg.press_appliance is None


def test_kit_query_parses():
    assert parse_act_message('{"type":"kit_query","request_id":"k1"}') == KitQueryMsg("k1")
    assert parse_act_message('{"type":"kit_query"}') is None


class _Channels:
    def __init__(self, mapping):
        self.by_appliance = mapping


def _binder(mapping=None):
    outlet = SimpleNamespace(channel=lambda ch: f"view{ch}")
    return TargetBinder(l3_mode="real", outlet=outlet, channels=_Channels(mapping or {}), press_appliance="microwave",
                        make_operation=lambda view, ch: (view, ch))


def test_ct_follows_hub_target_with_empty_channel_map():
    binder = _binder()
    with pytest.raises(TargetRefused):  # 옛 허브 — env 대상만 채널이 있다
        binder.bind("custom_fan")
    binder.set_press_target("custom_fan")
    assert binder.bind("custom_fan").ct_channel == 0


def test_ct_follows_hub_target_to_the_press_channel_in_a_map():
    binder = _binder({"microwave": 2, "washer": 1})
    binder.set_press_target("custom_fan")
    assert binder.channel_for("custom_fan") == 2
    assert binder.channel_for("washer") == 1  # 다른 콘센트 대응은 그대로


def test_changing_target_rebuilds_a_cached_binding():
    binder = TargetBinder(l3_mode="off", outlet=SimpleNamespace(channel=lambda ch: ch), channels=_Channels({}),
                          press_appliance="microwave")
    assert binder.bind("custom_fan").ct_channel is None
    binder.set_press_target("custom_fan")
    assert binder.bind("custom_fan").ct_channel == 0
