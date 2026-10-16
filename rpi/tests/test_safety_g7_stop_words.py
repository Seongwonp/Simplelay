"""G7(안전 계약 적용 보고 2026-10-15 §1-3·§2) — 텍스트·홈 음성의 "멈춰"·"그만"은 정지다. '취소' 버튼 누름이 아니다.

수리 전: 서버 규칙 별칭이 "멈춰줘"·"멈춰"·"그만해줘"·"그만"·"정지해줘"를 '취소해줘'(전자레인지 '취소' 버튼)로 받았다 —
쉬는 중이면 작은 팔이 실제로 '취소'를 눌렀고, 실행 중이면 409(바쁨)로 거절돼 정지도 되지 않았다. 별칭은 벡터 검색 예시로도
들어갔다. 시험 ``test_rules.py::test_default_aliases_resolve_to_canonical_sequence``가 이 동작을 고정하고 있었다.

수리 뒤(규칙은 ``rpi/intent/stop_words.py`` 머리말):
- ``POST /execute``·``POST /execute-for-appliance``는 해석 **맨 앞**에서 발화 전체가 정지어인지 본다. 정지어면 ``POST /stop``과
  같은 일을 하고(실행·개발자 세션·자동 실행·루틴 정지) ``status: "stopped"``와 정지 결과(``stop``)를 돌려준다. 버튼은 누르지 않는다.
- 서비스의 목적 실행(제안 승인 등 다른 호출자)도 정지어를 버튼으로 해석하지 않고 거절한다(두 번째 방어).
- 규칙 별칭에서 정지어를 뺐다(벡터 검색 예시에서도 빠진다). '취소'·'취소해줘'는 그대로 '취소' 버튼이다.

실행 대상은 가짜 — **실물 미검증.**
"""

from __future__ import annotations

import asyncio
import re
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest

from rpi.api import SimpleLayService
from rpi.api.deps import get_service
from rpi.controller import ButtonResult, ButtonStatus, ExecutionResult, ExecutionStatus
from rpi.intent import RuleBasedIntentResolver, UnknownIntentError
from rpi.intent.mock import FixedClock
from rpi.main import app
from rpi.routines import wiring

NOW = datetime(2026, 10, 16, 19, tzinfo=timezone(timedelta(hours=9)))
REPO = Path(__file__).resolve().parents[2]

#: 정지어(전체 일치) — 폰 실행 중 음성 정지와 같은 판정.
STOP_PHRASES = ["멈춰", "멈춰!", "멈춰 멈춰", "멈춰 주세요.", "그만", "그만해줘", "정지해줘", "정지", "스톱", "STOP"]
#: 정지어가 아닌 것 — 버튼 이름을 부른 말, 긴 문장 속 낱말, 다른 명령.
NOT_STOP_PHRASES = ["취소", "취소해줘", "취소 버튼 눌러", "그만 데워줘", "전자레인지 멈춰 있어", "즉석밥 데워줘", "",
                    " ".join(["멈춰"] * 9)]  # 공백을 빼면 18자 — 16자 넘음


class _Recorder:
    """누른 버튼을 적는다. ``hold``가 있으면 정지 요청이 올 때까지 누르는 중으로 머문다."""

    def __init__(self, hold: bool = False) -> None:
        self.calls: list[tuple[str, ...]] = []
        self.hold = hold
        self.started = threading.Event()
        self.stopped = threading.Event()

    def request_stop(self):
        self.stopped.set()

    def reset_stop(self):
        self.stopped.clear()

    def execute(self, buttons, targets=None):
        self.calls.append(tuple(buttons))
        self.started.set()
        if self.hold and self.stopped.wait(5.0):
            first = buttons[0]
            return ExecutionResult(ExecutionStatus.SAFETY_STOPPED, (ButtonResult(first, ButtonStatus.FAILED, 1, None),))
        return ExecutionResult(ExecutionStatus.SUCCEEDED,
                               tuple(ButtonResult(b, ButtonStatus.SUCCEEDED, 1, None) for b in buttons))


def _service(controller) -> SimpleLayService:
    return SimpleLayService(RuleBasedIntentResolver(), controller, clock=FixedClock(NOW))


def _post(service, path: str, payload: dict) -> httpx.Response:
    async def go():
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            return await client.post(path, json=payload)

    app.dependency_overrides[get_service] = lambda: service
    try:
        return asyncio.run(go())
    finally:
        app.dependency_overrides.pop(get_service, None)


def _wait_done(service, job_id):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        snap = service.status()
        if not snap.running and snap.last_job_id == job_id:
            return snap
        time.sleep(0.01)
    raise AssertionError("job did not finish")


@pytest.fixture()
def no_engines(monkeypatch):
    monkeypatch.setattr(wiring, "_engine", None)
    monkeypatch.setattr(wiring, "_auto_engine", None)


# ── 판정 규칙 ───────────────────────────────────────────────────────────────

@pytest.mark.parametrize("text", STOP_PHRASES)
def test_whole_utterance_stop_words_are_stop_phrases(text):
    from rpi.intent.stop_words import is_stop_phrase

    assert is_stop_phrase(text)


@pytest.mark.parametrize("text", NOT_STOP_PHRASES)
def test_cancel_button_and_longer_sentences_are_not_stop_phrases(text):
    from rpi.intent.stop_words import is_stop_phrase

    assert not is_stop_phrase(text)


def test_server_stop_words_are_the_phone_stop_words():
    """같은 말이 폰 실행 중에는 정지, 쉬는 중 서버에서는 버튼 누름이 되지 않게 — 두 목록이 같아야 한다."""
    from rpi.intent.stop_words import STOP_WORDS

    source = (REPO / "app/lib/providers/voice_stop_provider.dart").read_text(encoding="utf-8")
    block = re.search(r"const _stopWords = \[(.*?)\];", source, re.S)
    assert block is not None
    assert tuple(re.findall(r"'([^']*)'", block.group(1))) == STOP_WORDS


# ── 텍스트·홈 음성(/execute) ────────────────────────────────────────────────

@pytest.mark.parametrize("text", ["멈춰", "그만", "정지해줘", "멈춰 멈춰!"])
def test_text_stop_word_while_idle_is_a_stop_not_a_cancel_press(no_engines, text):
    controller = _Recorder()
    service = _service(controller)

    res = _post(service, "/execute", {"text": text, "source": "voice"})

    assert res.status_code == 200
    body = res.json()
    assert body["status"] == "stopped"
    assert body["stop"]["ok"] is True and body["stop"]["was_running"] is False
    assert body["job_id"] == ""  # 새 실행(job)은 없다
    time.sleep(0.05)
    assert controller.calls == []  # '취소' 버튼을 누르지 않았다
    assert service.status().last_job_id is None


def test_text_stop_word_while_running_stops_that_run(no_engines):
    controller = _Recorder(hold=True)
    service = _service(controller)
    job_id = service.submit_buttons(("즉석밥", "시작"))
    assert controller.started.wait(2.0)

    res = _post(service, "/execute", {"text": "멈춰"})

    assert res.status_code == 200  # 예전: 실행 중이라 409(바쁨) — 정지도 되지 않았다
    body = res.json()
    assert body["status"] == "stopped" and body["job_id"] == job_id
    assert body["stop"]["was_running"] is True and body["stop"]["stop_job_id"] == job_id
    _wait_done(service, job_id)
    assert controller.calls == [("즉석밥", "시작")]  # 취소 버튼을 덧붙여 누르지 않았다
    assert service.status().last_result.status is ExecutionStatus.SAFETY_STOPPED


def test_text_stop_word_also_stops_routines_like_the_stop_button(monkeypatch):
    calls: list[tuple[str, str]] = []
    runner = SimpleNamespace(halt_all=lambda reason: calls.append(("halt", reason)) or 0,
                             stop_all=lambda reason: calls.append(("stop", reason)) or 0)
    monkeypatch.setattr(wiring, "_engine", SimpleNamespace(runner=runner))
    monkeypatch.setattr(wiring, "_auto_engine", None)
    controller = _Recorder()

    res = _post(_service(controller), "/execute", {"text": "그만해줘"})

    assert res.status_code == 200
    assert calls[0] == ("halt", "긴급 정지 요청")  # POST /stop과 같은 순서 — 루틴 정지 표시가 먼저
    assert controller.calls == []


def test_custom_appliance_voice_stop_word_is_a_stop(no_engines):
    """사용자 정의 가전의 음성(/execute-for-appliance)도 해석(LLM) 전에 정지어를 본다 — LLM이 없어도 정지는 된다."""
    controller = _Recorder()
    res = _post(_service(controller), "/execute-for-appliance",
                {"text": "멈춰", "known_buttons": ["취소", "시작"]})
    assert res.status_code == 200  # 예전: LLM 미설정 503(설정돼 있으면 LLM이 '취소'를 고를 수 있었다)
    assert res.json()["status"] == "stopped"
    assert controller.calls == []


@pytest.mark.parametrize("text", ["취소", "취소해줘"])
def test_explicit_cancel_still_presses_the_cancel_button(no_engines, text):
    controller = _Recorder()
    service = _service(controller)

    res = _post(service, "/execute", {"text": text})

    assert res.status_code == 200 and res.json()["status"] == "accepted"
    _wait_done(service, res.json()["job_id"])
    assert controller.calls == [("취소",)]


# ── 두 번째 방어: 서비스·규칙 ──────────────────────────────────────────────

@pytest.mark.parametrize("call", ["submit_purpose", "execute_purpose"])
def test_service_never_turns_a_stop_word_into_a_button_press(call):
    """해석 계층이 아직 옛 별칭을 알아도(보드의 벡터 검색 DB는 수리 전 예시로 채워져 있을 수 있다 — 여기서는 그런 계층을
    주입 규칙으로 흉내) 서비스는 정지어를 버튼으로 풀지 않는다. 제안 승인처럼 라우터를 거치지 않는 호출자도 같다."""
    controller = _Recorder()
    stale = RuleBasedIntentResolver({"멈춰": ("취소",), "취소해줘": ("취소",)})
    service = SimpleLayService(stale, controller, clock=FixedClock(NOW))
    with pytest.raises(UnknownIntentError):
        getattr(service, call)("멈춰")
    time.sleep(0.05)
    assert controller.calls == []
    assert service.status().last_job_id is None


def test_stop_words_are_not_rule_aliases_or_vector_examples():
    from rpi.intent.vectordb_seed import examples_from_rules

    resolver = RuleBasedIntentResolver()
    for text in ["멈춰줘", "멈춰", "그만해줘", "그만", "정지해줘"]:
        with pytest.raises(UnknownIntentError):
            resolver.resolve(text)
    examples = examples_from_rules()
    assert not {"멈춰줘", "멈춰", "그만해줘", "그만", "정지해줘"} & set(examples)
    assert examples["취소"] == ("취소",)
