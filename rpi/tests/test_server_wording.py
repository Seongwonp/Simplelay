"""키오스크·폰이 그대로 보이는 서버·RPi4 문장 — 용어표(2026-10-15 키오스크 문구 개선 계획 §1·§6).

허브 → SimpleLay 본체, 누름 장치 → 작은 팔(장치는 '작은 팔 장치'), 콘센트 모듈·플러그 → 가전 콘센트 장치,
비상정지가 걸려 있어요 → 비상 버튼이 눌려 있어요, 보관 위치 → 제자리. 내부 말(실행기·이쪽 센서·구동부·
RPi4)도 화면 문장에 내지 않는다. 문장만 고정한다 — 판정·코드 값은 다른 시험이 지킨다.
"""

from __future__ import annotations

import re

import pytest

from rpi.api.service import ACT_LINK_DOWN_REASON, ESTOP_LATCHED_REASON, ESTOP_UNKNOWN_REASON
from rpi.api.service_commands import THINQ_ESTOP_REASON
from rpi.routines.runner import ESTOP_STOP_DETAIL
from rpi.services.connections import network_item, plug_item, press_item
from rpi.services.readiness import ReadinessCheck, _DEFAULT_REASON
from rpi.verifier.outlet import POWER_LOST_DETAIL
from rpi4.services import stop_hold
from rpi4.services.act_executor import (
    ESTOP_LATCHED_DETAIL,
    ESTOP_REASON_DETAIL,
    POWER_LOST_LATCH_DETAIL,
)

#: 화면 문장에 남으면 안 되는 옛 말·내부 말.
OLD_WORDS = re.compile(
    r"허브|누름 장치|콘센트 모듈|플러그|비상정지가 걸려|보관 위치|실행기|이쪽 센서|구동부|RPi4|좌표|"
    r"정지됨|미확인|다시 연결하기"
)


def _connection_texts() -> list[str]:
    items = [network_item(i, n) for i in ("up", "down", "unknown") for n in ("ok", "failed", "unknown")]
    items += [press_item(m, link) for m in ("", "simulator", "uart")
              for link in ("ok", "down", "no_reply", "error", "never")]
    items += [plug_item(mode) for mode in ("off", "mock", "real", "")]
    items += [plug_item("off", "weak"), plug_item("off", "lost")]
    return [text for item in items for text in (item.title, item.message, *item.fixes)]


def _hold_texts() -> list[str]:
    return [
        stop_hold.DETAIL_STOPPED, stop_hold.DETAIL_STOPPED_MOCK, stop_hold.DETAIL_STOPPED_LATE,
        stop_hold.DETAIL_UNCONFIRMED.format(n=2), stop_hold.DETAIL_DRIVE_FAULT, stop_hold.DETAIL_DRIVE_STOPPED,
        *stop_hold.PARK_DETAILS.values(),
    ]


def _estop_texts() -> list[str]:
    return [
        *ESTOP_REASON_DETAIL.values(), ESTOP_LATCHED_DETAIL, POWER_LOST_LATCH_DETAIL, POWER_LOST_DETAIL,
        ESTOP_LATCHED_REASON, ESTOP_UNKNOWN_REASON, ACT_LINK_DOWN_REASON, THINQ_ESTOP_REASON, ESTOP_STOP_DETAIL,
    ]


@pytest.mark.parametrize("texts", [_connection_texts, _hold_texts, _estop_texts], ids=lambda f: f.__name__)
def test_user_sentences_use_the_kiosk_glossary(texts):
    offenders = [text for text in texts() if OLD_WORDS.search(text)]
    assert offenders == []


def test_connection_items_name_the_parts_by_the_glossary():
    assert plug_item("off", "weak").title == "가전 콘센트 장치 연결이 약해요"
    assert press_item("uart", "no_reply").title == "작은 팔 장치가 답하지 않아요"
    assert "SimpleLay 본체" in network_item("down").message
    assert "'다시 확인하기'" in network_item("up", "failed").fixes[-1]


def test_estop_sentences_say_the_red_button_is_pressed():
    assert ESTOP_LATCHED_REASON.startswith("비상 버튼이 눌려 있어요")
    assert ESTOP_LATCHED_DETAIL.startswith("비상 버튼이 눌려 있어요")
    assert ESTOP_REASON_DETAIL["estop_button_pressed"].startswith("빨간 비상 버튼이 아직 눌려 있어요")
    assert "가전 콘센트 장치" in ESTOP_REASON_DETAIL["outlet_unreachable"]


def test_reboot_latch_sentence_is_shared_and_keeps_the_marker_the_server_reads():
    """RPi5 ``estop_block_reason``·키오스크가 '다시 켜져'로 재부팅 걸림을 가른다 — 두 보드의 문장이 같아야 한다."""
    assert POWER_LOST_DETAIL == POWER_LOST_LATCH_DETAIL
    assert "다시 켜져" in POWER_LOST_DETAIL and "가전 콘센트 장치" in POWER_LOST_DETAIL


def test_hold_sentences_name_who_moved_and_say_home_position():
    assert stop_hold.PARK_DETAILS["stop_confirmed"] == "가전이 멈춰 작은 팔이 제자리로 돌아갔어요"
    assert "작은 팔" in stop_hold.DETAIL_UNCONFIRMED and "확인하지 못했어요" in stop_hold.DETAIL_UNCONFIRMED
    # 가전이 멈췄다고 말하는 문장은 전력 하강으로 확인한 때(stopped)뿐이다.
    assert stop_hold.DETAIL_STOPPED.startswith("가전이 멈춘 것을 확인했어요")


def test_readiness_calibration_reason_says_button_place():
    assert _DEFAULT_REASON[ReadinessCheck.CALIBRATION] == "버튼 자리를 아직 맞추지 않았어요"
