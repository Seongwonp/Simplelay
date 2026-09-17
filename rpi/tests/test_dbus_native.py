"""dbus-fast 네이티브 vectordb 클라이언트 -- 버스 없이 로직을 고정한다.

invoker를 주입해 D-Bus 없이 검증한다(기존 CLI 클라이언트가 runner를 주입하는 것과
같은 방식). 여기서 잡는 것: 어떤 메서드를 어떤 인자로 부르는가, 그리고 타입 있는
응답이 SearchResult로 올바로 매핑되는가.

실기기 연결 자체(dbus-fast가 시스템 버스에 붙는 것)는 2026-08-31에 실기기 orchestrator로
확인했다. 여기서는 그 위의 우리 로직만 본다.
"""

from __future__ import annotations

import asyncio

import pytest

from rpi.intent.dbus_native import (
    DbusFastVectordbClient,
    DbusVectordbConfig,
    _snake_case,
    _to_result,
)
from rpi.intent.dbus_vectordb import SearchResult, VectordbClientError

_CFG = DbusVectordbConfig(
    service="com.example.Vectordb1",
    object_path="/com/example/Vectordb1",
    interface="com.example.Vectordb1",
)


class _RecordingInvoker:
    """부른 메서드·인자를 기록하고, 미리 넣어둔 응답을 돌려준다."""

    def __init__(self, reply=None, error: Exception | None = None) -> None:
        self.reply = reply
        self.error = error
        self.calls: list[tuple] = []

    async def __call__(self, cfg, method, *args):
        self.calls.append((method, args))
        if self.error is not None:
            raise self.error
        return self.reply


class _FakeVariant:
    """dbus-fast Variant처럼 .value를 가진 것 -- metadata 언랩 검증용."""

    def __init__(self, value) -> None:
        self.value = value


class TestSnakeCase:
    @pytest.mark.parametrize(
        "method,expected",
        [
            ("SearchText", "search_text"),
            ("AddText", "add_text"),
            ("CreateDB", "create_d_b"),  # dbus-fast의 기계적 변환 그대로 (연속 대문자)
        ],
    )
    def test_maps_dbus_method_to_proxy_name(self, method, expected):
        assert _snake_case(method) == expected


class TestToResult:
    def test_maps_struct_fields_in_order(self):
        # (id, metadata, originalData, score)
        item = ["id-1", {"buttons": "해동,시작"}, "즉석밥 데우기", 0.92]
        result = _to_result(item)
        assert result.id == "id-1"
        assert result.metadata == {"buttons": "해동,시작"}
        assert result.original_data == "즉석밥 데우기"
        assert result.score == pytest.approx(0.92)

    def test_unwraps_variant_metadata_values(self):
        # a{sv}라 값이 Variant로 온다 -- 실제 값만 남겨야 resolver가 읽는다
        item = ["id-2", {"buttons": _FakeVariant("시작")}, "원본", 0.8]
        result = _to_result(item)
        assert result.metadata == {"buttons": "시작"}

    def test_tolerates_short_struct(self):
        # metadata가 비고 originalData/score가 없어도 죽지 않는다
        result = _to_result(["id-3", {}])
        assert result.id == "id-3"
        assert result.metadata == {}
        assert result.original_data == ""
        assert result.score == 0.0


class TestSearchText:
    def test_calls_search_text_with_top_k_and_maps_results(self):
        invoker = _RecordingInvoker(
            reply=[
                ["id-1", {"buttons": "해동,시작"}, "즉석밥 데우기", 0.9],
                ["id-2", {"buttons": "시작"}, "시작만", 0.7],
            ]
        )
        client = DbusFastVectordbClient(config=_CFG, invoker=invoker)

        results = client.search_text("즉석밥 데워줘", top_k=2)

        assert invoker.calls == [("SearchText", ("즉석밥 데워줘", 2))]
        assert [r.id for r in results] == ["id-1", "id-2"]
        assert results[0].metadata["buttons"] == "해동,시작"

    def test_empty_reply_gives_empty_list(self):
        client = DbusFastVectordbClient(config=_CFG, invoker=_RecordingInvoker(reply=[]))
        assert client.search_text("없는 명령") == []

    def test_none_reply_gives_empty_list(self):
        # 서비스가 빈 응답을 None으로 줄 수도 있다
        client = DbusFastVectordbClient(config=_CFG, invoker=_RecordingInvoker(reply=None))
        assert client.search_text("없는 명령") == []

    def test_bus_error_becomes_domain_error(self):
        invoker = _RecordingInvoker(error=RuntimeError("bus down"))
        client = DbusFastVectordbClient(config=_CFG, invoker=invoker)
        with pytest.raises(VectordbClientError, match="D-Bus 호출 실패"):
            client.search_text("명령")

    def test_timeout_becomes_domain_error(self):
        async def _hang(cfg, method, *args):
            await asyncio.sleep(10)

        cfg = DbusVectordbConfig(
            service=_CFG.service,
            object_path=_CFG.object_path,
            interface=_CFG.interface,
            call_timeout_seconds=0.05,
        )
        # invoker 자체가 asyncio.wait_for를 쓰지 않으므로 여기서는 _sync가
        # 예외를 도메인 오류로 감싸는지만 본다(빠른 실패)
        client = DbusFastVectordbClient(
            config=cfg, invoker=lambda c, m, *a: _raise_timeout()
        )
        with pytest.raises(VectordbClientError):
            client.search_text("명령")


async def _raise_timeout():
    raise TimeoutError("simulated")


class TestAddText:
    def test_encodes_metadata_and_returns_id(self):
        invoker = _RecordingInvoker(reply="new-id-42")
        client = DbusFastVectordbClient(config=_CFG, invoker=invoker)

        return_id = client.add_text("즉석밥 데우기", {"buttons": "해동,시작"})

        assert return_id == "new-id-42"
        method, args = invoker.calls[0]
        assert method == "AddText"
        assert args[0] == "즉석밥 데우기"
        # metadata는 [{key: Variant('s', value)}] 형태 -- Variant는 지연 import라
        # 여기선 리스트에 dict 하나가 들었고 그 안에 buttons 키가 있는지만 본다
        encoded = args[1]
        assert isinstance(encoded, list) and len(encoded) == 1
        assert "buttons" in encoded[0]


class TestCreateDb:
    def test_passes_schema_tuple(self):
        invoker = _RecordingInvoker(reply=None)
        client = DbusFastVectordbClient(config=_CFG, invoker=invoker)

        client.create_db("simplelay", vector_dimension=768)

        method, args = invoker.calls[0]
        assert method == "CreateDB"
        assert args[0] == "simplelay"
        # [(type, dim, metric)]
        assert args[1] == [("TEXT", 768, "COSINE")]


class TestResolverIntegration:
    """네이티브 클라이언트가 기존 resolver에 그대로 끼워지는지 -- 같은 Protocol."""

    def test_resolver_uses_native_client(self):
        from rpi.intent.dbus_vectordb import VectordbIntentResolver

        invoker = _RecordingInvoker(
            reply=[["id-1", {"buttons": "해동,시작"}, "즉석밥 데우기", 0.9]]
        )
        client = DbusFastVectordbClient(config=_CFG, invoker=invoker)
        resolver = VectordbIntentResolver(client)

        assert resolver.resolve("즉석밥 데워줘") == ("해동", "시작")


class TestTransportSelection:
    """deps.py가 SIMPLELAY_DBUS_TRANSPORT로 CLI/native를 고르는지."""

    def test_defaults_to_native(self, monkeypatch):
        import rpi.api.deps as deps
        from rpi.intent.dbus_native import DbusFastVectordbClient

        monkeypatch.delenv(deps.DBUS_TRANSPORT_ENV, raising=False)
        monkeypatch.setenv("SIMPLELAY_DBUS_VECTORDB_SERVICE", "com.example.Vectordb1")

        assert isinstance(deps._build_vectordb_client(), DbusFastVectordbClient)

    def test_cli_selects_subprocess_client(self, monkeypatch):
        import rpi.api.deps as deps
        from rpi.intent.dbus_vectordb import VectordbClient

        monkeypatch.setenv(deps.DBUS_TRANSPORT_ENV, "cli")
        monkeypatch.setenv("SIMPLELAY_DBUS_VECTORDB_SERVICE", "com.example.Vectordb1")
        monkeypatch.setenv("SIMPLELAY_DBUS_CLI", "dbus-cli")

        assert isinstance(deps._build_vectordb_client(), VectordbClient)

    def test_unknown_transport_fails_loudly(self, monkeypatch):
        import rpi.api.deps as deps

        monkeypatch.setenv(deps.DBUS_TRANSPORT_ENV, "carrier-pigeon")
        monkeypatch.setenv("SIMPLELAY_DBUS_VECTORDB_SERVICE", "com.example.Vectordb1")

        with pytest.raises(RuntimeError, match="알 수 없는"):
            deps._build_vectordb_client()
