"""_build_llm_client()의 환경변수 기반 LLM 클라이언트 선택 로직 검증.

명시적으로 설정 안 하면 None(오프라인 기본), SIMPLELAY_LLM_MODE=dbus면
온디바이스 경로, 그 외 SIMPLELAY_LLM_BASE_URL이 있으면 HTTP 경로 -- 자동
폴백 없이 항상 운영자가 명시적으로 고르는 구조라는 게 핵심이라 각 분기를
직접 확인한다.
"""

import pytest

from rpi import dbus_env
from rpi.api.deps import _build_llm_client
from rpi.intent import DbusAgentLlmClient, HttpLlmClient

# 온디바이스 경로는 서비스 주소를 환경에서 읽는다 -- 테스트는 가짜 주소를 준다
_FAKE_SERVICE = "com.example.TestAgent1"
_FAKE_CLI = "fake-dbus-cli"


def _configure_dbus(monkeypatch: pytest.MonkeyPatch) -> None:
    """dbus 모드가 요구하는 주소를 전부 준다.

    온디바이스 계층이 둘(대화형 에이전트·유사도 검색)이라 주소도 둘이다. 하나만
    주고 켜면 기동 시 실패하는데, 그게 의도된 동작이라 별도 테스트로 잡아둔다.
    """
    monkeypatch.setenv(dbus_env.ENV_AGENT_SERVICE, _FAKE_SERVICE)
    monkeypatch.setenv(dbus_env.ENV_VECTORDB_SERVICE, "com.example.TestVectordb1")
    monkeypatch.setenv(dbus_env.ENV_DBUS_CLI, _FAKE_CLI)


@pytest.fixture(autouse=True)
def clean_llm_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in ("SIMPLELAY_LLM_MODE", "SIMPLELAY_LLM_BASE_URL",
                "SIMPLELAY_LLM_API_KEY", "SIMPLELAY_LLM_MODEL",
                dbus_env.ENV_AGENT_SERVICE, dbus_env.ENV_VECTORDB_SERVICE,
                dbus_env.ENV_DBUS_CLI):
        monkeypatch.delenv(key, raising=False)


def test_returns_none_when_nothing_configured():
    assert _build_llm_client() is None


def test_dbus_mode_returns_dbus_client(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "dbus")
    _configure_dbus(monkeypatch)

    client = _build_llm_client()

    assert isinstance(client, DbusAgentLlmClient)


def test_dbus_mode_is_case_insensitive(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "DBUS")
    _configure_dbus(monkeypatch)

    assert isinstance(_build_llm_client(), DbusAgentLlmClient)


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

    assert isinstance(_build_llm_client(), DbusAgentLlmClient)


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


# ═══════════════════════════════════════════════════════════════════════════════
# 계층 순서 — _build_intent_resolver()
# ═══════════════════════════════════════════════════════════════════════════════

def test_rule_tier_comes_before_similarity_tier(monkeypatch: pytest.MonkeyPatch):
    """규칙이 유사도보다 먼저여야 한다.

    먼저 성공한 계층이 이기므로(tiered.py), 유사도가 앞에 있으면 임계값만 넘기면
    **정확한 규칙을 덮어쓴다**. 서브프로세스 왕복 비용도 규칙으로 끝날 문장까지
    물게 된다. 한때 실제로 순서가 반대였고, 유사도 계층이 항상 미스라 드러나지
    않았을 뿐이다 — 시드를 채우는 순간 활성화될 버그였다.
    """
    from rpi.api.deps import _build_intent_resolver
    from rpi.intent import RuleBasedIntentResolver, TieredIntentResolver
    from rpi.intent.dbus_vectordb import VectordbIntentResolver

    monkeypatch.setenv("SIMPLELAY_LLM_MODE", "dbus")
    _configure_dbus(monkeypatch)

    resolver = _build_intent_resolver()

    assert isinstance(resolver, TieredIntentResolver)
    tiers = resolver._resolvers
    assert isinstance(tiers[0], RuleBasedIntentResolver)
    assert isinstance(tiers[1], VectordbIntentResolver)


def test_rule_tier_alone_when_nothing_else_configured():
    """아무 설정이 없으면 규칙 단독 — 오프라인 완결이라는 기본 성질."""
    from rpi.api.deps import _build_intent_resolver
    from rpi.intent import RuleBasedIntentResolver

    assert isinstance(_build_intent_resolver(), RuleBasedIntentResolver)


# ═══════════════════════════════════════════════════════════════════════════════
# 노드 전송 선택 — _node_controller_factory()
# ═══════════════════════════════════════════════════════════════════════════════

class TestNodeTransportSelection:
    """등록된 노드 주소를 어느 전송으로 부를지 고르는 부분.

    이 배선이 없던 동안에는 펌웨어에서 ESP-NOW를 켜고 MAC을 등록해도 RPi5가 그
    MAC을 HTTP base_url로 취급했다 — 신규 전송이 테스트에만 존재하고 프로덕션
    요청은 지나가지 않는 상태였다(교차 리뷰 치명 지적).
    """

    def test_defaults_to_http(self, monkeypatch: pytest.MonkeyPatch):
        from rpi.api.deps import NODE_TRANSPORT_ENV, _node_controller_factory
        from rpi.services import EspNodeController

        monkeypatch.delenv(NODE_TRANSPORT_ENV, raising=False)

        assert _node_controller_factory() is EspNodeController

    def test_espnow_mode_uses_gateway_link(self, monkeypatch: pytest.MonkeyPatch):
        import rpi.api.deps as deps
        from rpi.services.espnow_node_controller import (
            EspNowGatewayLink,
            EspNowNodeController,
        )

        class _FakePort:
            def write(self, data: bytes) -> int:
                return len(data)

            def readline(self) -> bytes:
                return b""

        monkeypatch.setenv(deps.NODE_TRANSPORT_ENV, "espnow")
        # 실제 시리얼 포트를 열지 않도록 링크만 갈아끼운다
        monkeypatch.setattr(
            deps, "_get_gateway_link", lambda: EspNowGatewayLink(_FakePort())
        )

        factory = deps._node_controller_factory()
        controller = factory("AA:BB:CC:DD:EE:FF")

        assert isinstance(controller, EspNowNodeController)

    def test_unknown_transport_fails_loudly(self, monkeypatch: pytest.MonkeyPatch):
        # 오타가 조용히 기본값으로 떨어지면 어느 전송으로 도는지 알 수 없다
        from rpi.api.deps import NODE_TRANSPORT_ENV, _node_controller_factory

        monkeypatch.setenv(NODE_TRANSPORT_ENV, "esp-now")  # 흔한 오타

        with pytest.raises(RuntimeError, match="http 또는 espnow"):
            _node_controller_factory()

    def test_espnow_without_port_names_the_missing_variable(
        self, monkeypatch: pytest.MonkeyPatch
    ):
        import rpi.api.deps as deps

        monkeypatch.setenv(deps.NODE_TRANSPORT_ENV, "espnow")
        monkeypatch.delenv(deps.GATEWAY_PORT_ENV, raising=False)
        deps._get_gateway_link.cache_clear()

        with pytest.raises(RuntimeError, match=deps.GATEWAY_PORT_ENV):
            deps._node_controller_factory()

    def test_registry_uses_the_selected_factory(self, monkeypatch: pytest.MonkeyPatch):
        import rpi.api.deps as deps
        from rpi.services import EspNodeController

        monkeypatch.delenv(deps.NODE_TRANSPORT_ENV, raising=False)
        deps.get_node_registry.cache_clear()

        registry = deps.get_node_registry()

        assert registry._controller_factory is EspNodeController
        deps.get_node_registry.cache_clear()
