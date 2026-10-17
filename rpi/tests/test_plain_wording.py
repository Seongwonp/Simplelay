"""쉬운 말 회귀 시험(2026-10-17, docs/UI-개편안-2026-10-17.md §2·§3).

폰·키오스크에 그대로 나가는 서버 문장에 내부 이름('허브'·'모의'·'시연'·'ThinQ'·'CT'·'L3'·'작은 팔 장치')과
문장 잇기 기호('—'·'·'·괄호)가 다시 들어오지 않게 지킨다. 클라이언트가 글자 일치로 쓰는 낱말
('조리 완료가 아닐 수 있어요'·'다시 켜져'·'이미'+'보내지 않았어요')은 남아 있는지도 본다.
"""

from __future__ import annotations

import re

import pytest

from rpi.routines import auto_rules
from rpi.scenarios.catalog import COOK_DONE_AIR, DEFAULT_SCENARIOS
from rpi.services import connections
from rpi.services.air_quality import AirReading
from rpi.services.thinq import controller as thinq_controller
from rpi.services.thinq import wording
from rpi.verifier.outlet import POWER_LOST_DETAIL
from rpi4.services import act_executor

#: 사용자 문장에 나오면 안 되는 말(쉬운 말 사전 §3). '본체'·'작은 팔'·'콘센트'·'LG 가전'·'연습'으로 바꾼다.
BANNED_WORDS = ("허브", "모의", "시연", "ThinQ", "CT", "L3", "작은 팔 장치", "가전 콘센트 장치", "SimpleLay 본체",
                "상태 재조회", "변경 명령", "콘센트 전력")
#: 문장을 잇는 기호(말투 규칙 4).
BANNED_JOINERS = ("—", "--", " · ", "(", ")")


def _connection_sentences() -> list[str]:
    items = [connections.network_item(i, n) for i in ("up", "down", "unknown") for n in ("ok", "failed", "unknown")]
    items += [connections.press_item("mock")]
    items += [connections.press_item("uart", link) for link in ("ok", "down", "no_reply", "error", "never")]
    items += [connections.plug_item(mode) for mode in ("off", "mock", "real")]
    items += [connections.plug_item("real", link) for link in ("weak", "lost")]
    out: list[str] = []
    for item in items:
        out += [item.title, item.message, *item.fixes]
    return out


def _auto_rule_constants() -> list[str]:
    names = [n for n in dir(auto_rules) if re.fullmatch(r"[A-Z_]+_(REASON|NOTICE|CAVEAT|REFUSED)", n)]
    return [getattr(auto_rules, n) for n in names if isinstance(getattr(auto_rules, n), str)]


def _air_reasons() -> list[str]:
    return [AirReading(bad=((name, 42, level),), known=1, wind=None).reason()
            for name in ("초미세먼지", "미세먼지", "종합 공기질") for level in ("BAD", "VERY_BAD")]


SENTENCES = {
    "connections": _connection_sentences,
    "auto_rules": _auto_rule_constants,
    "scenario_reasons": lambda: [d.event_reason for d in DEFAULT_SCENARIOS if d.event_reason],
    "air_quality": _air_reasons,
    "thinq_wording": lambda: [wording.already_sentence("강풍"), wording.changed_sentence("강풍"),
                              wording.target_seen_sentence("강풍"), wording.UNCONFIRMED_SENTENCE,
                              thinq_controller.REMOTE_OFF_REASON, thinq_controller.REMOTE_UNKNOWN_REASON],
    "estop": lambda: [act_executor.ESTOP_LATCHED_DETAIL, act_executor.POWER_LOST_LATCH_DETAIL, POWER_LOST_DETAIL,
                      *act_executor.ESTOP_REASON_DETAIL.values()],
}


@pytest.mark.parametrize("group", sorted(SENTENCES))
def test_user_sentences_use_plain_words(group):
    for text in SENTENCES[group]():
        for word in BANNED_WORDS:
            assert word not in text, f"{group}: '{word}' in {text!r}"
        for joiner in BANNED_JOINERS:
            assert joiner not in text, f"{group}: '{joiner}' in {text!r}"
        assert not re.search(r"\d+\s*(ms|mA|dB)|\d+초 (전|늦게)", text), f"{group}: 숫자·단위 in {text!r}"


def test_client_matched_words_stay():
    # 키오스크 kAlwaysShownCaveats — 가열 종료를 '조리 완료'로 단정하지 않는 줄을 늘 보인다.
    assert "조리 완료가 아닐 수 있어요" in COOK_DONE_AIR.event_reason
    # 키오스크 estop.dart·서버 estop_block_reason이 '다시 켜져'로 전원 꺼짐 걸림을 가른다.
    assert "다시 켜져" in act_executor.POWER_LOST_LATCH_DETAIL
    assert "다시 켜져" in POWER_LOST_DETAIL
    # 폰·키오스크 command_result.dart가 ThinQ 결과를 이 낱말로 가른다.
    already = wording.already_sentence("강풍")
    assert "이미" in already and "보내지 않았어요" in already
    assert "설정된 것을 확인" in wording.target_seen_sentence("강풍")
    assert "바꿨어요" in wording.changed_sentence("강풍")


# ── 10/18 쉬운 말 2차: 자동 실행 규칙 문장·누름 결과·루틴 진행·LG 오류·연습 장치 ─────────────────────────────

#: 2차에서 더 막는 말 — 설정표 말('풍량'), 화살표, 내부 이름·검증 층·재시도 횟수, '단계'(→ '할 일').
BANNED_WORDS_2 = ("풍량", "→", "PAT", "API", "SIMPLELAY_", "L1", "L2", "L3", "재시도", "정지 요청", "단계",
                  "전원 켜기", "전원 끄기", "누름 장치", "클라우드", "프로필")


def _rule(event="heat_complete", action="set_wind_strength", value="HIGH", **kw):
    from rpi.routines.auto_rules import AutoRule

    return AutoRule("r1", "s1", "mw", event, "air", "k", "DEVICE_AIR_PURIFIER", action, "arg", value, **kw)


class _FakeRuleEngine:
    """조건·동작 문장만 만드는 가짜(이름표·LG 가전 기능표)."""

    def __init__(self, bound=True):
        from types import SimpleNamespace

        from rpi.services.thinq.bindings import AIR_PURIFIER_CAPABILITIES

        caps = {c.action: c for c in AIR_PURIFIER_CAPABILITIES}
        self._bound = SimpleNamespace(thinq=SimpleNamespace(capability=caps.__getitem__)) if bound else None

    def _name(self, appliance_id):
        return {"mw": "전자레인지", "air": "공기청정기"}[appliance_id]

    def _appliance(self, _appliance_id):
        return self._bound


def _rule_texts() -> list[str]:
    from rpi.routines.auto_rules import CONDITION_KIND_TIME, AutoRuleEngine

    out = []
    for bound in (True, False):
        engine = _FakeRuleEngine(bound)
        for value in ("HIGH", "MID", "LOW", "AUTO"):
            out.append(AutoRuleEngine.action_text(engine, _rule(action="set_wind_strength", value=value)))
        for value in ("POWER_ON", "POWER_OFF"):
            out.append(AutoRuleEngine.action_text(engine, _rule(action="set_power", value=value)))
        for value in ("CLEAN", "SLEEP"):
            out.append(AutoRuleEngine.action_text(engine, _rule(action="set_job_mode", value=value)))
    engine = _FakeRuleEngine()
    out.append(AutoRuleEngine.condition_text(engine, _rule()))
    for days, at in (((0, 1, 2, 3, 4, 5, 6), "22:00"), ((0, 1, 2, 3, 4), "07:30"), ((5, 6), "12:00"),
                     ((0, 2), "00:05")):
        out.append(AutoRuleEngine.condition_text(engine, _rule(
            event="time", condition_kind=CONDITION_KIND_TIME, condition_days=days, condition_time=at)))
    return out


def _physical_details() -> list[str]:
    from rpi.commands import Command, command_result_from_execution
    from rpi.controller.models import (ButtonResult, ButtonStatus, ExecutionMode, ExecutionOutcome,
                                       ExecutionResult, ExecutionStatus, LayerOutcome, VerificationLayer)
    from rpi.services.aggregate_result import synthesize_execution_result
    from rpi.verifier import VerificationResult

    first = ButtonResult("즉석밥", ButtonStatus.SUCCEEDED, 1, VerificationResult(True, 0.9))
    ok = ButtonResult("시작", ButtonStatus.SUCCEEDED, 1, VerificationResult(True, 0.9))
    bad = ButtonResult("시작", ButtonStatus.FAILED, 3, VerificationResult(False, 0.2),
                       failed_layer=VerificationLayer.ACCEPTANCE)
    op_fail = LayerOutcome(VerificationLayer.OPERATION, False, "전력 변화 없음")
    results = [
        ExecutionResult(ExecutionStatus.SUCCEEDED, (first, ok)),
        ExecutionResult(ExecutionStatus.SUCCEEDED, (first, ok),
                        operation=LayerOutcome(VerificationLayer.OPERATION, True, "전력 상승")),
        ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (first, ok), failed_layer=VerificationLayer.OPERATION,
                        operation=op_fail),
        ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (first, ok)),
        ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (first, bad), failed_layer=VerificationLayer.ACCEPTANCE),
        ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (first,)),
        ExecutionResult(ExecutionStatus.SAFETY_STOPPED, ()),
        ExecutionResult(ExecutionStatus.FAILED, ()),
        synthesize_execution_result(["즉석밥", "시작"], True, 0),
        synthesize_execution_result(["즉석밥", "시작"], False, 2),
        synthesize_execution_result(["즉석밥", "시작"], False, 0, outcome=ExecutionOutcome.STOPPED),
        synthesize_execution_result(["즉석밥", "시작"], False, 2, outcome=ExecutionOutcome.SAFETY_STOP),
    ]
    command = Command.physical("microwave", ["즉석밥", "시작"])
    return [command_result_from_execution(command, r, execution_mode=ExecutionMode.REAL, stopped_by_user=stop).detail
            for r in results for stop in (False, True)]


def _runner_sentences() -> list[str]:
    from rpi.routines import runner

    return [runner.START_ONLY_DETAIL, runner.PROBABLE_DETAIL, runner.ESTOP_STOP_DETAIL, runner.ALL_STOP_DETAIL,
            runner.ROUTINE_STOP_DETAIL, runner.WAIT_STOPPED_DETAIL, runner.INJECTED_NOTE, runner.MOCK_INPUT_NOTE]


def _second_round(group: str) -> list[str]:
    from rpi.api import router
    from rpi.controller.models import PRESS_UNCONFIRMED_DETAIL
    from rpi.scenarios.catalog import V2_SCENARIOS
    from rpi.services.thinq.errors import API_ERROR_REASONS, error_from_api

    return {
        "auto_rule_texts": _rule_texts,
        "physical_detail": _physical_details,
        "press_unconfirmed": lambda: [PRESS_UNCONFIRMED_DETAIL],
        "routine_runner": _runner_sentences,
        "lg_errors": lambda: [*API_ERROR_REASONS.values(), error_from_api("9999", None).reason],
        "rehearsal": lambda: [router._REHEARSAL_ESTOP_DETAIL, router._UART_REHEARSAL_ESTOP_DETAIL,
                              router._REHEARSAL_DONE_DETAIL],
        "scenario_names": lambda: [d.name for d in (*DEFAULT_SCENARIOS, *V2_SCENARIOS)],
    }[group]()


@pytest.mark.parametrize("group", ["auto_rule_texts", "physical_detail", "press_unconfirmed", "routine_runner",
                                   "lg_errors", "rehearsal", "scenario_names"])
def test_second_round_sentences_use_plain_words(group):
    texts = _second_round(group)
    assert texts
    for text in texts:
        for word in (*BANNED_WORDS, *BANNED_WORDS_2):
            assert word not in text, f"{group}: '{word}' in {text!r}"
        for joiner in BANNED_JOINERS:
            assert joiner not in text, f"{group}: '{joiner}' in {text!r}"
        assert not re.search(r"\d{1,2}:\d{2}", text), f"{group}: 시각 표기 in {text!r}"


def test_rule_fragments_read_as_one_sentence():
    """폰은 '언제'와 '무엇을'을 따로 보이거나 이어 붙인다 — 조각만으로도, 이어 읽어도 자연스럽게."""
    from rpi.routines.auto_rules import CONDITION_KIND_TIME, AutoRuleEngine, spoken_time

    engine = _FakeRuleEngine()
    assert AutoRuleEngine.condition_text(engine, _rule()) == "전자레인지가 데우기를 멈추면"
    assert AutoRuleEngine.action_text(engine, _rule()) == "공기청정기 바람을 세게 해요"
    night = _rule(event="time", action="set_power", value="POWER_ON", condition_kind=CONDITION_KIND_TIME,
                  condition_days=tuple(range(7)), condition_time="22:00")
    assert AutoRuleEngine.condition_text(engine, night) == "매일 밤 10시에"
    assert AutoRuleEngine.action_text(engine, night) == "공기청정기를 켜요"
    morning = _rule(event="time", action="set_power", value="POWER_OFF", condition_kind=CONDITION_KIND_TIME,
                    condition_days=(0, 1, 2, 3, 4), condition_time="07:30")
    assert AutoRuleEngine.condition_text(engine, morning) == "평일 아침 7시 30분에"
    assert AutoRuleEngine.action_text(engine, morning) == "공기청정기를 꺼요"
    assert [spoken_time(t) for t in ("00:00", "05:00", "12:00", "13:05", "18:00", "21:00", "bad")] == [
        "밤 12시", "새벽 5시", "낮 12시", "낮 1시 5분", "저녁 6시", "밤 9시", "bad"]


def test_old_user_off_reason_shows_the_new_sentence():
    from rpi.routines.auto_rules import USER_OFF_REASON, display_reason

    assert USER_OFF_REASON == "자동 실행을 꺼 두셨어요."
    assert display_reason("직접 자동 실행을 껐어요.") == USER_OFF_REASON


def test_probable_end_is_decided_by_value_not_by_wording():
    """입력 하나뿐인 끝(probable)을 문장 글자로 가르지 않는다 — 문장을 바꿔도 단계 상태가 그대로여야 한다."""
    import inspect

    from rpi.routines import runner

    assert "startswith(PROBABLE_DETAIL)" not in inspect.getsource(runner.RoutineRunner)


def test_client_matched_words_stay_after_second_round():
    """폰·키오스크가 글자로 가르는 값은 2차에서도 그대로(rpi_api_service·kiosk_api_service의 409 '승인' 등)."""
    from rpi.routines.auto_rules import AutoRuleEngine

    rule = _rule()

    class _Purpose(_FakeRuleEngine):
        def _routine(self, _routine_id):
            return None

        action_text = AutoRuleEngine.action_text

    # 폰 display_status.dart가 '자동 실행 · '로 출처를 가른다.
    assert AutoRuleEngine._run_purpose(_Purpose(), rule).startswith("자동 실행 · ")
