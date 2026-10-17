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

#: 사용자 문장에 나오면 안 되는 말(쉬운 말 사전 §3). '본체'·'작은 팔'·'전기 플러그'·'LG 가전'·'연습'으로 바꾼다.
#: 10/18 4차: '콘센트'(가족은 벽 콘센트로 읽음 → '전기 플러그')·'보냈어요'(기계 말 → '가전에 전했어요'·'멈추는 중이에요').
BANNED_WORDS = ("허브", "모의", "시연", "ThinQ", "CT", "L3", "작은 팔 장치", "가전 콘센트 장치", "SimpleLay 본체",
                "상태 재조회", "변경 명령", "콘센트 전력", "콘센트", "보냈어요")
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

    assert USER_OFF_REASON == "자동으로 하기를 꺼 두셨어요."
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


# ── 10/18 쉬운 말 4차: '콘센트' → '전기 플러그', '보냈어요' 계열 → 사람 말, '자동 실행' 표시 문장 → '자동으로 하기' ─────

#: 화면에 나가는 문장을 만드는 모듈 — 문자열 상수(문서 문자열 제외)를 훑는다. 로그·설치용 오류는 이 목록 밖이다.
_USER_TEXT_MODULES = (
    "rpi/services/connections.py", "rpi/routines/auto_rules.py", "rpi/services/quiet_hours.py",
    "rpi/routines/candidates.py", "rpi/routines/runner.py", "rpi/services/thinq/controller.py",
    "rpi/services/thinq/sdk_client.py", "rpi/services/thinq/errors.py", "rpi/services/thinq/wording.py",
    "rpi/api/service_commands.py", "rpi/api/service.py", "rpi/commands/physical.py", "rpi/scenarios/engine.py",
    "rpi/scenarios/catalog.py", "rpi/api/ambient_router.py", "rpi/services/stop_confirm.py",
    "rpi4/services/act_executor.py", "rpi4/services/stop_hold.py",
)
#: 기능 이름·출처 표시로 클라이언트가 글자 그대로 쓰는 값(mode_label·status_label·목적 머리·규칙 이름 기본값)과
#: 옛 저장 문장을 알아보는 표(보여 줄 때 지금 문장으로 바꾸는 열쇠).
_AUTO_NAME_ALLOWED = re.compile(
    r"^(자동 실행|자동 실행 · |자동 실행 켜짐|자동 실행 꺼짐|자동 실행을 |자동 실행이 )$"
    r"|^(허용하는 사이 정지가|허브가 갑자기|루틴이 바뀌어 자동 실행을 껐어요 —|루틴을 지워서 자동 실행을 껐어요$"
    r"|루틴이 꺼져 있어 자동 실행을 껐어요 —|직접 자동 실행을 껐어요|비상정지로 자동 실행을 껐어요 —|사용자가 자동 실행을 껐어요)"
    r"|^auto rules unreadable")


def _string_constants(path: str) -> list[tuple[int, str]]:
    import ast
    import pathlib

    root = pathlib.Path(__file__).resolve().parents[2]
    tree = ast.parse((root / path).read_text(encoding="utf-8"))
    docs = set()
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and body:
            first = body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                docs.add(id(first.value))
    return [(n.lineno, n.value) for n in ast.walk(tree)
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in docs]


@pytest.mark.parametrize("path", _USER_TEXT_MODULES)
def test_round4_no_wall_socket_or_machine_send_words(path):
    """가족은 '콘센트'를 벽 콘센트로 읽는다 — 우리 장치는 '전기 플러그'. '보냈어요'는 기계 말 — '가전에 전했어요'·
    '멈추는 중이에요'로. '보내지 않았어요'는 클라이언트가 '이미'와 함께 글자로 가르는 이미 목표값 문장에만 남긴다."""
    for line, text in _string_constants(path):
        assert "콘센트" not in text, f"{path}:{line} {text!r}"
        assert "보냈어요" not in text and "보냈지만" not in text, f"{path}:{line} {text!r}"
        if "보내지 않았어요" in text:
            # 이미 목표값 문장('이미 … 설정돼 있어요. 그래서 보내지 않았어요.')은 조각으로 나뉘어 있을 수 있다.
            assert "이미" in text or text.startswith(" 설정돼 있어요."), f"{path}:{line} {text!r}"


@pytest.mark.parametrize("path", _USER_TEXT_MODULES)
def test_round4_auto_name_in_sentences_is_plain(path):
    """'자동 실행'은 클라이언트 비교값·기능 이름(mode_label·status_label·'자동 실행 · ' 머리)에만. 문장은 '자동으로 하기'."""
    for line, text in _string_constants(path):
        if "자동 실행" in text:
            assert _AUTO_NAME_ALLOWED.search(text), f"{path}:{line} {text!r}"


def test_round4_plug_and_send_sentences():
    from rpi.routines import auto_rules
    from rpi.services import stop_confirm
    from rpi.services.quiet_hours import CARRIED_PAUSE_SCOPE_TEXT, SCOPE_TEXT, SKIP_REASON

    assert connections.plug_item("off", "weak").title == "전기 플러그 연결이 약해요"
    assert connections.plug_item("off").fixes == ("쓰려면 가전 전원선을 전기 플러그에 꽂고, 전기 플러그를 벽에 꽂아 주세요.",)
    assert POWER_LOST_DETAIL == act_executor.POWER_LOST_LATCH_DETAIL == (
        "전기 플러그가 다시 켜져서 가전 전원이 꺼졌어요. 해제하면 전원을 다시 켜요.")
    # 보낸 것까지만 안다 — 멈췄다고 하지 않는다(확인 수준 유지).
    assert stop_confirm.stop_sentence(stop_confirm.STOP_SENT) == "멈추는 중이에요. 멈췄는지 기계를 봐 주세요"
    assert auto_rules.ESTOP_REASON == "비상정지로 자동으로 하기를 껐어요."
    assert auto_rules.USER_OFF_REASON == "자동으로 하기를 꺼 두셨어요."
    assert SKIP_REASON == "조용한 시간이라 자동으로 하지 않았어요"
    # 조용한 시간에 건너뛴 것은 나중에 다시 하지 않는다는 사실은 그대로.
    assert "나중에 다시 하지 않아요" in SCOPE_TEXT and "자동 실행" not in CARRIED_PAUSE_SCOPE_TEXT


def test_round4_old_auto_reasons_show_the_new_name():
    from rpi.routines.auto_rules import ESTOP_REASON, USER_OFF_REASON, display_reason

    assert display_reason("자동 실행을 꺼 두셨어요.") == USER_OFF_REASON
    assert display_reason("비상정지로 자동 실행을 껐어요.") == ESTOP_REASON
    assert display_reason("공기청정기를 찾을 수 없어 자동 실행을 껐어요. 다시 허락해 주세요.") == (
        "공기청정기를 찾을 수 없어 자동으로 하기를 껐어요. 다시 허락해 주세요.")
    assert display_reason("직접 자동 실행을 껐어요.") == USER_OFF_REASON


@pytest.mark.parametrize("stored, shown", [
    ("강풍으로 바꿔줘", "바람을 세게 해줘"),
    ("약풍으로 바꿔줘", "바람을 약하게 해줘"),
    ("공기청정기 중풍으로 바꿔 줘", "공기청정기 바람을 중간으로 해 줘"),
    ("공기청정기를 강풍으로 바꿀까요?", "공기청정기 바람을 세게 할까요?"),
    ("공기청정기 바람 세기 약으로 바꿔줘", "공기청정기 바람을 약하게 해줘"),
    ("공기청정기 풍량 바꿔줘", "공기청정기 바람 세기 바꿔줘"),
    ("자동 실행 · 공기청정기 풍량 강으로", "자동 실행 · 공기청정기 바람을 세게 해요"),
    # 사람 명령문·루틴 이름·선풍기 버튼 이름('약풍')은 그대로.
    ("공기청정기 켜줘", "공기청정기 켜줘"),
    ("'강풍으로 바꿔줘' 루틴", "'강풍으로 바꿔줘' 루틴"),
    ("저녁 휴식 — 공기청정기를 켜고 선풍기를 약풍으로 켤까요?", "저녁 휴식 — 공기청정기를 켜고 선풍기를 약풍으로 켤까요?"),
])
def test_round4_history_shows_old_wind_words_plainly(stored, shown):
    from rpi.routines.auto_rules import display_purpose

    assert display_purpose(stored) == shown


def test_round4_client_matched_values_stay():
    """비교값은 그대로 — 폰·키오스크가 글자로 가른다."""
    from rpi.routines.auto_rules import ALREADY_REASON, AUTO_PURPOSE_PREFIX

    assert AUTO_PURPOSE_PREFIX == "자동 실행 · "
    assert "이미" in ALREADY_REASON and "보내지 않았어요" in ALREADY_REASON
    assert "다시 켜져" in POWER_LOST_DETAIL
