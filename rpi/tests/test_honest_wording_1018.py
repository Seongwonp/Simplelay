"""화면이 실제 확인 수준보다 앞서 말하지 않는다(심사위원 시각 평가 10/18 §3-5 — 정직성 예외).

- 가열 종료 감지(CT 전력이 떨어짐)는 조리 완료가 아닐 수 있다 — 자동 규칙 이름이 '데우기가 끝나면'처럼 다 데운 것으로
  단정하지 않는다. 멈춘 것이 근거다.
- 연습(모의) 구성에서 작은 팔·전기 플러그가 실제로 '준비됐다'·'연결돼 있다'고 하지 않는다 — 연습이라는 것을 제목에서 말한다.
"""

from __future__ import annotations

from rpi.scenarios import catalog
from rpi.services.connections import plug_item, press_item


def test_heat_done_rule_name_does_not_claim_the_cooking_finished():
    name = catalog.scenario_name("cook_done_air")
    assert name == "전자레인지가 멈추면 공기청정기 세게"
    for claim in ("끝나면", "다 데우", "완료"):
        assert claim not in name


def test_every_heat_complete_scenario_name_avoids_finish_claims():
    for d in catalog.KNOWN_SCENARIOS:
        if d.trigger.event == "heat_complete":
            assert "끝나면" not in d.name and "완료" not in d.name, d.name


def test_practice_press_item_does_not_say_the_arm_is_ready():
    item = press_item("mock")
    assert item.source == "mock" and item.state == "ok"
    assert "준비됐어요" not in item.title
    assert "연습" in item.title


def test_practice_plug_item_does_not_say_the_plug_is_connected():
    item = plug_item("mock")
    assert item.source == "mock" and item.state == "ok"
    assert "연결돼 있어요" not in item.title
    assert "연습" in item.title


def test_real_items_keep_their_titles():
    assert press_item("uart", "ok").title == "작은 팔이 연결돼 있어요"
    assert plug_item("off").title == "전기 플러그가 아직 없어요"
