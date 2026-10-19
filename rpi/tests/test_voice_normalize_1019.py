"""음성 의도 해석 규칙 계층 보강(2026-10-19) — 말 다듬기·같은 뜻 사전·'혹시 이것?' 후보·못 알아들을 때 동작 목록.

기준은 `docs/음성-의도-해석-조사-2026-10-19.md` §5-2: **다른 동작으로 잘못 매칭 0건이 먼저**, 그다음 '모름' 비율.
조사 문서의 예시 20개(1~20) + 변형 30여 개. 기대값:

- ``("set_power", "POWER_ON")`` 같은 동작 — 일치(확인 카드 뒤 실행되는 기존 경로)
- ``("후보", 동작)`` — 일치는 없고 '혹시 이것?' 후보로만(실행 안 함)
- ``None`` — 모름(후보도 없음)

새 모듈은 시험 안에서 읽는다 — 고치기 전 코드에서 API 시험이 '실패'로 드러나게(수입 오류로 묻히지 않게).
"""

from __future__ import annotations

import time

import pytest

from rpi.tests.test_thinq_u1 import _wait_done, client, mock_mode  # noqa: F401 — 고정물 재사용

ON = ("set_power", "POWER_ON")
OFF = ("set_power", "POWER_OFF")
HIGH = ("set_wind_strength", "HIGH")
LOW = ("set_wind_strength", "LOW")
AUTO = ("set_wind_strength", "AUTO")
START = ("set_operation", "START")
PAUSE = ("set_operation", "STOP")

#: 사용자가 붙인 가전 이름(실제 등록 이름과 같은 모양 — '거실 공기청정기').
NAME = "거실 공기청정기"

AIR_CASES: tuple[tuple[str, object], ...] = (
    # ── 조사 문서 예시 20개 ──
    ("공기청정기 켜 줘", ON),
    ("공기 청정기 좀 켜줘", ON),
    ("공청기 켜", ON),
    ("공기청정기 켜 줄래", ON),
    ("공기청정기 틀어 줘", ON),
    ("공기청정기 켜주세요", ON),
    ("공기 청정기 꺼 줘", OFF),
    ("공청기 좀 꺼", OFF),
    ("공기청전기 켜 줘", ("후보", ON)),      # STT 한 글자
    ("공기정청기 켜줘", ("후보", ON)),        # 글자 뒤바뀜
    ("공기청정기 커 줘", None),               # 켜/꺼 어느 쪽인지 퍼지로 정하지 않는다
    ("공기청정기 바람 세게", HIGH),
    ("공기청정기 강풍으로 해줘", HIGH),
    ("공기청정기 바람 약하게 해 줘", LOW),
    ("청정기 켜", ON),
    ("켜 줘", None),                          # 가전 없음 — 짐작 금지
    ("공기청정기", None),                     # 동작 없음
    ("공기청정기 필터 갈아 줘", None),        # 목록 밖
    ("에어컨 켜 줘", None),                   # 등록 안 된 가전
    ("공기청정기 켜지 마", None),             # 부정
    # ── 변형 ──
    ("공기청정기를 켜 줘", ON),
    ("거실 공기청정기 켜 줘", ON),            # 사용자가 붙인 이름
    ("공기청정기 전원 켜", ON),
    ("공기청정기 켜요", ON),
    ("공기청정기 켜 줘!", ON),
    ("공기청정기 꺼 주세요", OFF),
    ("공기청정기 전원을 꺼 줘", OFF),
    ("공기정화기 꺼", OFF),
    ("공기청정기 끄기", OFF),
    ("바람 세게 해 줘", HIGH),
    ("공기청정기 강하게", HIGH),
    ("공기청정기 바람 최대로", HIGH),
    ("약풍으로 바꿔 주세요", LOW),
    ("바람 살살", LOW),
    ("공기청정기 자동으로 해 줘", AUTO),
    ("공기청정이 켜 줘", ("후보", ON)),       # STT 한 글자(이름)
    ("공기청정기 꺼 쥐", ("후보", OFF)),      # STT 한 글자(어미) — 동사 '꺼'는 그대로라 후보
    ("공기청정기 거 줘", None),               # STT 한 글자(동사) — 동사는 퍼지로 고치지 않는다
    ("공기청정기 겨 줘", None),
    ("공기청정기 안 켜도 돼", None),          # 부정
    ("공기청정기 끄지 마", None),             # 부정
    ("공기청정기 켜지 말고 꺼 줘", None),     # 부정이 섞임 — 고르지 않는다
    ("공기청정기 켜 꺼", None),               # 반대 뜻이 함께
    ("공기청정기 강풍 약풍", None),           # 반대 뜻이 함께
    ("공기청정기 바람 중간으로", None),       # '중'은 등록 동작이 아님
    ("공기청정기 수면 모드", None),           # 목록 밖
    ("날씨 알려 줘", None),                   # 목록 밖
)

WASHER_CASES: tuple[tuple[str, object], ...] = (
    ("세탁 시작해 줘", START),
    ("세탁 시작", START),
    ("세탁기 돌려 줘", START),
    ("빨래 시작해 주세요", START),
    ("세탁 일시정지 해 주세요", PAUSE),
    ("세탁기 시작하지 마", None),             # 부정
    ("세탁 정지", None),                      # 정지어가 아니고 등록 동작도 아님 — 일시정지로 짐작하지 않는다
    ("세탁 멈춰", None),
)

DEHUMIDIFIER_CASES: tuple[tuple[str, object], ...] = (
    ("제습기 틀어 줘", ON),
    ("제습기 꺼", OFF),
    ("제습기 켜지 마", None),
)


def _bindings():
    from rpi.services.thinq.bindings import air_purifier_binding, dehumidifier_binding, washer_binding

    return (
        (air_purifier_binding("dev-air"), AIR_CASES),
        (washer_binding("dev-washer"), WASHER_CASES),
        (dehumidifier_binding("dev-dehum"), DEHUMIDIFIER_CASES),
    )


def _interpret(binding, text):
    """한 문장 해석 결과를 기대값과 같은 모양으로 — 일치면 동작, 아니면 ('후보', 동작) 또는 None."""
    command = binding.command_for_purpose("ap", text, names=(NAME,))
    if command is not None:
        cap = binding.capability(command.action)
        return (command.action, command.args_dict()[cap.arg])
    hit = binding.suggestion_for(text, NAME, (NAME,))
    if hit is None:
        return None
    fn = next(f for f in binding.functions if f.purpose == hit[0])
    return ("후보", (fn.action, dict(fn.args)[binding.capability(fn.action).arg]))


def _all_cases():
    for binding, cases in _bindings():
        for text, expected in cases:
            yield binding, text, expected


def test_case_count_covers_the_research_set_plus_variants():
    assert len(AIR_CASES) >= 20 + 25
    assert sum(len(c) for _, c in _bindings()) >= 50


def test_no_utterance_is_matched_to_a_different_action():
    """잘못 받아들임 0건 — 일치든 후보든 기대와 다른 동작이 나오면 안 된다(가장 먼저 지킬 것)."""
    wrong = []
    for binding, text, expected in _all_cases():
        got = _interpret(binding, text)
        if got is None:
            continue
        got_action = got[1] if got[0] == "후보" else got
        exp_action = (expected[1] if isinstance(expected, tuple) and expected[0] == "후보" else expected)
        if exp_action is None or got_action != exp_action:
            wrong.append((text, expected, got))
    assert wrong == []


@pytest.mark.parametrize("binding_index, text, expected", [
    (i, text, expected)
    for i, cases in enumerate((AIR_CASES, WASHER_CASES, DEHUMIDIFIER_CASES))
    for text, expected in cases
])
def test_each_utterance_gives_the_expected_result(binding_index, text, expected):
    binding = _bindings()[binding_index][0]
    assert _interpret(binding, text) == expected


def test_unknown_ratio_and_latency_are_measured(capsys):
    """'모름' 비율과 문장당 지연을 실제로 잰다(보고용). 지연 상한은 넉넉히 — 부하 때 흔들리지 않게."""
    cases = list(_all_cases())
    unknown = sum(1 for b, t, _ in cases if _interpret(b, t) is None)
    suggested = sum(1 for b, t, _ in cases if (r := _interpret(b, t)) is not None and r[0] == "후보")
    rounds = 20
    start = time.perf_counter()
    for _ in range(rounds):
        for binding, text, _ in cases:
            _interpret(binding, text)
    per_ms = (time.perf_counter() - start) * 1000 / (rounds * len(cases))
    with capsys.disabled():
        print(f"\n[음성 해석 1019] 문장 {len(cases)}개 · 모름 {unknown}({unknown / len(cases):.0%}) · "
              f"후보 {suggested} · 문장당 {per_ms:.3f} ms")
    assert per_ms < 50


# ── 말 다듬기·사전 자체 ────────────────────────────────────────────────


def test_normalize_endings_fillers_and_aliases():
    from rpi.intent.normalize import normalize_utterance as n

    same = ["공기청정기 켜줘", "공기 청정기 켜 줘.", "공기청정기 좀 켜 주세요", "공청기 켜 줄래?",
            "공기정화기 켜요", "공기청정기를 켜", "공기청정기 틀어 줘", "공기청정기 한 번 켜 줘"]
    assert {n(s) for s in same} == {"공기청정기켜"}
    assert n("해동해줘") == n("해동 좀 해 주세요") == n("해동")
    assert n("공기청정기 꺼줘") != n("공기청정기 켜줘")


def test_lexicon_aliases_never_cross_opposite_sides():
    """사전의 별칭이 반대 뜻으로 넘어가지 않는다 — 별칭과 목적 문장의 쪽(켜/꺼, 강/약/자동, 시작/일시정지)이 같다."""
    from rpi.intent import voice_lexicon as lex
    from rpi.intent.normalize import _sides, normalize_utterance

    def compatible(a: str, b: str) -> bool:
        sa, sb = _sides(a), _sides(b)
        return all(sa[g] == sb[g] for g in sa.keys() & sb.keys())

    for lhs, rhs in lex.VERB_ALIASES:
        assert compatible(lhs, rhs), (lhs, rhs)
    checked = 0
    for table in (lex.PHRASE_ALIASES, lex.SETTING_VALUES):
        for per_device in table.values():
            for purpose, aliases in per_device.items():
                for alias in aliases:
                    assert compatible(normalize_utterance(alias), normalize_utterance(purpose)), (alias, purpose)
                    checked += 1
    assert checked > 30


def test_two_purposes_that_normalize_alike_are_not_chosen():
    """사전 실수로 두 동작이 같은 키가 되면 어느 쪽도 고르지 않는다(짐작 금지)."""
    from rpi.services.thinq.bindings import AIR_PURIFIER_CAPABILITIES, ThinqBinding, ThinqFunction

    binding = ThinqBinding("d", "DEVICE_AIR_PURIFIER", AIR_PURIFIER_CAPABILITIES, (
        ThinqFunction("공기청정기 켜줘", "set_power", (("power", "POWER_ON"),)),
        ThinqFunction("공기청정기 켜 주세요", "set_power", (("power", "POWER_OFF"),)),
    ))
    assert binding.command_for_purpose("ap", "공기청정기 켜 줘") is None


def test_rule_layer_uses_the_same_normalization():
    from rpi.intent.rules import RuleBasedIntentResolver, UnknownIntentError

    rules = RuleBasedIntentResolver()
    assert rules.resolve("즉석밥 좀 데워 주세요") == ("즉석밥", "시작")
    assert rules.resolve("라면 끓여 줄래") == ("라면", "시작")
    assert rules.resolve("에어컨 틀어 줘") == ("전원", "냉방")
    assert rules.resolve("취소") == ("취소",)
    for text in ("즉석밥 데우지 마", "에어컨 안 켜도 돼", "멈춰", "그만 해 주세요"):
        with pytest.raises(UnknownIntentError):
            rules.resolve(text)


# ── 정지어 우선(G7) — 다듬기가 흔들지 않는다 ─────────────────────────────


STOP_VARIANTS = ("멈춰", "멈춰 줘", "멈춰 주세요", "그만", "그만해", "그만 해 줘", "정지", "정지해 주세요", "스톱")


@pytest.mark.parametrize("text", STOP_VARIANTS)
def test_stop_phrases_still_win_and_never_become_an_action(text):
    from rpi.intent.normalize import refuses_matching
    from rpi.intent.stop_words import is_stop_phrase

    assert is_stop_phrase(text)              # 라우터는 해석 전에 정지로 보낸다(원래 문장 그대로)
    assert refuses_matching(text)            # 다듬은 꼴도 정지어 — 일치·후보 없음
    for binding, _ in _bindings():
        assert binding.command_for_purpose("ap", text) is None
        assert binding.suggestion_for(text, NAME) is None


def test_filler_before_stop_word_is_not_an_action_either():
    """'좀 멈춰'는 폰 목록과 같게 정지어로 넓히지 않지만, 다듬으면 정지어라 어떤 동작으로도 풀지 않는다."""
    from rpi.intent.normalize import refuses_matching
    from rpi.intent.stop_words import is_stop_phrase

    assert not is_stop_phrase("좀 멈춰")
    assert refuses_matching("좀 멈춰")


# ── API 계약: 422 본문 ──────────────────────────────────────────────────


def test_execute_accepts_normalized_speech_for_lg_appliance(client):  # noqa: F811
    job = client.post("/execute", json={"text": "공청기 좀 켜 주세요", "appliance_id": "air_purifier"})
    assert job.status_code == 200, job.text
    status = _wait_done(client, job.json()["job_id"])
    assert status["last_route"] == "thinq"


def test_not_understood_422_carries_a_suggestion_and_choices_but_runs_nothing(client):  # noqa: F811
    from rpi.api import deps

    res = client.post("/execute", json={"text": "공기청전기 켜 줘", "appliance_id": "air_purifier"})
    assert res.status_code == 422
    body = res.json()
    assert body["detail"] == "'공기청전기 켜 줘'를 알아듣지 못했어요"
    assert body["suggestion"]["purpose"] == "공기청정기 켜줘"
    assert body["suggestion"]["label"].endswith("전원 켜기")
    purposes = [c["purpose"] for c in body["choices"]]
    assert purposes == ["공기청정기 켜줘", "공기청정기 꺼줘", "강풍으로 바꿔줘", "약풍으로 바꿔줘", "자동으로 바꿔줘"]
    assert all(c["label"] for c in body["choices"])
    assert deps.get_service().thinq_controller.client.controls == []   # 후보는 실행하지 않는다


def test_negated_speech_gets_no_suggestion(client):  # noqa: F811
    res = client.post("/execute", json={"text": "공기청정기 켜지 마", "appliance_id": "air_purifier"})
    assert res.status_code == 422
    assert res.json()["suggestion"] is None
    assert res.json()["choices"]


def test_stop_word_on_execute_still_stops_before_interpretation(client):  # noqa: F811
    res = client.post("/execute", json={"text": "멈춰 줘", "appliance_id": "air_purifier"})
    assert res.status_code == 200
    assert res.json()["status"] == "stopped"


def test_physical_appliance_422_lists_its_functions_and_a_close_one(client):  # noqa: F811
    res = client.post("/execute", json={"text": "즉석빱 데워 줘", "appliance_id": "microwave"})
    assert res.status_code == 422
    body = res.json()
    assert body["detail"] == "'즉석빱 데워 줘'를 알아듣지 못했어요"
    assert body["suggestion"] == {"purpose": "즉석밥 데워줘", "label": "즉석밥 데워줘"}
    assert "즉석밥 데워줘" in [c["purpose"] for c in body["choices"]]


def test_physical_close_tie_gives_no_suggestion(client):  # noqa: F811
    """'3분 돌려'는 '1분'·'5분'과 똑같이 가깝다 — 1·2위 차이가 없으면 후보를 내지 않는다."""
    res = client.post("/execute", json={"text": "3분 돌려 줘", "appliance_id": "microwave"})
    assert res.status_code == 422
    assert res.json()["suggestion"] is None
