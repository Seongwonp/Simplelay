"""_build_llm_client()의 환경변수 기반 LLM 클라이언트 선택 로직 검증.

명시적으로 설정 안 하면 None(오프라인 기본), SIMPLELAY_LLM_MODE=dbus면
온디바이스 경로, 그 외 SIMPLELAY_LLM_BASE_URL이 있으면 HTTP 경로 -- 자동
폴백 없이 항상 운영자가 명시적으로 고르는 구조라는 게 핵심이라 각 분기를
직접 확인한다.
"""

import pytest

from rpi.api.deps import _build_llm_client
from rpi.intent import Dbusinternal_aiLlmClient, HttpLlmClient


@pytest.fixture(autouse=True)
def clean_llm_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("SIMPLELAY_LLM_MODE", "SIMPLELAY_LLM_BASE_URL",
                "SIMPLELAY_LLM_API_KEY", "SIMPLELAY_LLM_MODEL"):
        monkeypatch.delenv(key, raising=False)


def test_returns_none_when_nothing_configured():
    assert _build_llm_client() is None


def test_dbus_mode_returns_dbus_client(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "dbus")

    client = _build_llm_client()

    assert isinstance(client, Dbusinternal_aiLlmClient)


def test_dbus_mode_is_case_insensitive(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "DBUS")

    assert isinstance(_build_llm_client(), Dbusinternal_aiLlmClient)


def test_base_url_without_mode_returns_http_client(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_LLM_BASE_URL", "https://example.invalid/v1")

    client = _build_llm_client()

    assert isinstance(client, HttpLlmClient)


def test_dbus_mode_takes_priority_over_base_url(monkeypatch: pytest.MonkeyPatch):
    # 둘 다 설정돼 있으면 dbus가 이긴다 -- 조용한 이중 폴백이 아니라 명시적
    # 선택이어야 하므로, 모호한 상태를 만들지 않기 위해 우선순위를 고정한다.
    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "dbus")
    monkeypatch.setenv("SIMPLELAY_LLM_BASE_URL", "https://example.invalid/v1")

    assert isinstance(_build_llm_client(), Dbusinternal_aiLlmClient)
