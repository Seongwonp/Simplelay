"""_build_llm_client()의 환경변수 기반 LLM 클라이언트 선택 로직 검증.

명시적으로 설정 안 하면 None(오프라인 기본), SIMPLELAY_LLM_MODE=dbus면
온디바이스 경로, 그 외 SIMPLELAY_LLM_BASE_URL이 있으면 HTTP 경로 -- 자동
폴백 없이 항상 운영자가 명시적으로 고르는 구조라는 게 핵심이라 각 분기를
직접 확인한다.
"""

import pytest

from rpi import dbus_env
from rpi.api.deps import _build_llm_client
from rpi.intent import Dbusinternal_aiLlmClient, HttpLlmClient

# 온디바이스 경로는 서비스 주소를 환경에서 읽는다 -- 테스트는 가짜 주소를 준다
_FAKE_SERVICE = "com.example.TestAgent1"
_FAKE_CLI = "fake-dbus-cli"


def _configure_dbus(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(dbus_env.ENV_AGENT_SERVICE, _FAKE_SERVICE)
    monkeypatch.setenv(dbus_env.ENV_DBUS_CLI, _FAKE_CLI)


@pytest.fixture(autouse=True)
def clean_llm_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("SIMPLELAY_LLM_MODE", "SIMPLELAY_LLM_BASE_URL",
                "SIMPLELAY_LLM_API_KEY", "SIMPLELAY_LLM_MODEL",
                dbus_env.ENV_AGENT_SERVICE, dbus_env.ENV_DBUS_CLI):
        monkeypatch.delenv(key, raising=False)


def test_returns_none_when_nothing_configured():
    assert _build_llm_client() is None


def test_dbus_mode_returns_dbus_client(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "dbus")
    _configure_dbus(monkeypatch)

    client = _build_llm_client()

    assert isinstance(client, Dbusinternal_aiLlmClient)


def test_dbus_mode_is_case_insensitive(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "DBUS")
    _configure_dbus(monkeypatch)

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
    _configure_dbus(monkeypatch)

    assert isinstance(_build_llm_client(), Dbusinternal_aiLlmClient)


def test_dbus_mode_without_service_address_fails_loudly(
    monkeypatch: pytest.MonkeyPatch,
):
    # 주소 없이 조용히 동작하는 것보다, 무엇을 설정해야 하는지 짚고 즉시 실패하는 편이
    # 낫다 -- "켰는데 아무 일도 안 일어난다"가 가장 진단하기 어려운 상태다.
    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "dbus")

    with pytest.raises(
        dbus_env.MissingPlatformConfigError, match=dbus_env.ENV_AGENT_SERVICE
    ):
        _build_llm_client()
