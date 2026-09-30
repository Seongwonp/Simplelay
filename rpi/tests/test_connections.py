"""연결 상태 세 가지 — 판정 규칙과 사용자 말 문구(UI 확정 §1-5)."""

import re

import pytest

from rpi.services.connections import (
    STATES,
    network_item,
    plug_item,
    press_item,
    press_link_from_frames,
    read_interface_state,
)

# 부품·개발 용어가 화면 문구에 새지 않게 한다.
JARGON = re.compile(
    r"RPi|라즈베리|ESP|UART|시리얼|노드|콘센트 모듈|CT|L3|MCU|Arduino|아두이노|모듈|API|mock|sysfs|링크",
    re.IGNORECASE,
)


def _all_items():
    items = [
        network_item("up"),
        network_item("down"),
        network_item("unknown"),
        network_item("up", "failed"),
    ]
    items += [press_item(m, link) for m in ("", "simulator", "uart") for link in ("ok", "no_reply", "error", "never")]
    items += [plug_item(mode) for mode in ("off", "mock", "real", "")]
    items += [plug_item("off", "weak"), plug_item("off", "lost")]
    return items


@pytest.mark.parametrize("item", _all_items(), ids=lambda i: f"{i.id}-{i.state}")
def test_user_text_has_no_component_jargon(item):
    assert item.state in STATES
    for text in (item.title, item.message, *item.fixes):
        assert not JARGON.search(text), text
        assert text.endswith(("요", "요.")), text


def test_non_ok_items_say_what_is_lost_and_how_to_fix():
    for item in _all_items():
        if item.state in ("warn", "error"):
            assert item.fixes, item
            assert any(w in item.message for w in ("수 없", "않", "늦", "못", "실패")), item


def test_plug_weak_example_text():
    item = plug_item("off", "weak")
    assert item.to_dict() == {
        "id": "plug",
        "state": "warn",
        "title": "플러그 연결이 약해요",
        "message": "가전이 끝났는지 알려 주는 플러그와 연결이 약해요. 끝났다는 알림이 늦거나 오지 않을 수 있어요.",
        "fixes": [
            "플러그가 콘센트에 끝까지 꽂혀 있는지 확인해 주세요.",
            "플러그를 허브와 가까운 콘센트로 옮겨 주세요.",
            "그래도 안 되면 플러그를 뽑았다가 10초 뒤 다시 꽂아 주세요.",
        ],
        "source": "real",
    }


@pytest.mark.parametrize(
    "mode, state, source",
    [("off", "not_installed", "none"), ("", "not_installed", "none"), ("mock", "ok", "mock"), ("real", "unknown", "real")],
)
def test_plug_by_l3_mode(mode, state, source):
    item = plug_item(mode)
    assert (item.state, item.source) == (state, source)


@pytest.mark.parametrize("mode", ["", "local", "mock", "simulator"])
def test_press_is_practice_unit_outside_uart(mode):
    item = press_item(mode, "no_reply")
    assert (item.state, item.source) == ("ok", "mock")


@pytest.mark.parametrize(
    "link, state",
    [("ok", "ok"), ("no_reply", "error"), ("error", "warn"), ("never", "unknown")],
)
def test_press_uart_states(link, state):
    assert press_item("uart", link).state == state


def test_network_states():
    assert network_item("up").state == "ok"
    assert network_item("unknown").state == "ok"  # 응답했다는 것 자체가 연결의 근거
    assert network_item("down").state == "error"
    assert network_item("up", "failed").state == "warn"
    assert network_item("down", "failed").state == "error"


# ── 판정 입력 ────────────────────────────────────────────────────────────────

S = 1_000_000_000


def _frame(direction, type_, t_s):
    return {"kind": "frame", "direction": direction, "type": type_, "t_monotonic_ns": int(t_s * S)}


def test_press_link_never_without_frames():
    assert press_link_from_frames([], 10 * S) == "never"
    assert press_link_from_frames([{"kind": "session_start"}], 10 * S) == "never"


def test_press_link_ok_after_reply():
    frames = [_frame("hub_to_act", "execute", 1), _frame("act_to_hub", "result", 5)]
    assert press_link_from_frames(frames, 500 * S) == "ok"


def test_press_link_pending_within_timeout_is_not_error():
    frames = [_frame("act_to_hub", "result", 1), _frame("hub_to_act", "execute", 10)]
    assert press_link_from_frames(frames, 30 * S, reply_timeout_s=60) == "ok"


def test_press_link_no_reply_after_timeout():
    frames = [_frame("act_to_hub", "result", 1), _frame("hub_to_act", "execute", 10)]
    assert press_link_from_frames(frames, 100 * S, reply_timeout_s=60) == "no_reply"
    assert press_link_from_frames(frames[1:], 100 * S, reply_timeout_s=60) == "no_reply"


def test_press_link_error_frame():
    frames = [_frame("hub_to_act", "execute", 1), _frame("act_to_hub", "error", 2)]
    assert press_link_from_frames(frames, 5 * S) == "error"


def test_interface_state_from_sysfs(tmp_path):
    for name, state in (("lo", "unknown"), ("eth0", "down"), ("wlan0", "up")):
        (tmp_path / name).mkdir()
        (tmp_path / name / "operstate").write_text(state + "\n", encoding="ascii")
    assert read_interface_state(tmp_path) == "up"
    (tmp_path / "wlan0" / "operstate").write_text("down\n", encoding="ascii")
    assert read_interface_state(tmp_path) == "down"


def test_interface_state_unknown_without_sysfs(tmp_path):
    assert read_interface_state(tmp_path / "missing") == "unknown"
    (tmp_path / "lo").mkdir()
    assert read_interface_state(tmp_path) == "unknown"
