"""온디바이스 D-Bus 서비스를 **파이썬에서 직접** 호출한다(dbus-fast).

왜 CLI(플랫폼 D-Bus CLI) 대신인가:

우리 백엔드는 플랫폼 이미지에서 도는 게 아니라, 그 위에 **파이썬 컨테이너**로 올라간다
(플랫폼 이미지의 python3은 AI 서비스 전용으로 격리돼 우리가 못 쓴다 — dev-docs 참고).
컨테이너 안에는 그 CLI 바이너리가 없다. 그래서 시스템 버스 소켓만 마운트하고
파이썬 D-Bus 바인딩으로 직접 부른다 — 이 경로가 실기기에서 실제로 붙는 것을 확인했다
(2026-08-31, orchestrator introspect 성공).

CLI 클라이언트(dbus_vectordb.py)보다 나은 점: **반환값이 타입으로 온다.** CLI는
텍스트를 찍고 우리가 정규식으로 되파싱했는데(그 출력 포맷은 실기기로 확정된 적이
없어 CAUTION이 붙어 있었다), 여기서는 D-Bus가 구조체·맵을 그대로 준다.

호출은 ``invoker``로 주입받는다 -- 기존 subprocess ``runner``와 같은 철학이다.
테스트는 버스 없이 가짜 invoker를 넣고, 프로덕션은 dbus-fast invoker를 쓴다.
그래서 이 모듈은 **dbus-fast가 없어도 import된다**(실제 연결 시에만 지연 import).

미확정으로 남는 것: vectordb 서비스가 이 이미지에서 systemd 유닛 누락으로 활성화되지
않아, 인자 인코딩(a{sv}·a(sus))과 반환 구조를 **실 호출로 확정하지 못했다.** 아래는
우리가 아는 인터페이스 모양에 맞춰 쓰되, CLI 클라이언트와 같은 정신으로 작고
교체 가능한 조각(_encode_metadata / _to_result)으로 분리해 뒀다 -- 실 출력이 잡히면
그 두 함수만 고치면 된다.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from rpi import dbus_env

from .dbus_vectordb import (
    _METADATA_BUTTONS_KEY,
    SearchResult,
    VectordbClientError,
)

# 메서드 한 건을 부르고 이미 타입이 된 응답을 돌려주는 코루틴.
# 인자: (config, method_name, *args). 주입 지점이라 테스트가 버스 없이 대체한다.
DbusInvoker = Callable[..., Awaitable[Any]]


@dataclass(frozen=True)
class DbusVectordbConfig:
    """서비스 주소는 기기의 성질이라 환경에서 받는다(dbus_env). CLI 경로가 필요
    없다는 점만 CLI 설정과 다르다 -- 여기선 소켓으로 직접 붙는다."""

    service: str
    object_path: str
    interface: str
    call_timeout_seconds: float = 5.0

    @classmethod
    def from_env(cls) -> "DbusVectordbConfig":
        service = dbus_env.required(
            dbus_env.ENV_VECTORDB_SERVICE, "온디바이스 유사도 검색 서비스"
        )
        return cls(
            service=service,
            object_path=dbus_env.object_path_for(service),
            interface=service,
        )


def _encode_metadata(metadata: Mapping[str, str]) -> list[dict[str, Any]]:
    """AddText의 metadata 인자(a{sv})로 넣을 값.

    문자열 값을 D-Bus variant로 감싸 ``[{key: Variant('s', value)}]`` 형태로 만든다.
    dbus-fast가 없어도 import되도록 Variant는 여기서 지연 생성한다.
    실 호출로 인코딩이 확정되면 이 함수만 고친다.
    """
    from dbus_fast.signature import Variant  # noqa: PLC0415 -- 지연 import

    return [{key: Variant("s", str(value)) for key, value in metadata.items()}]


def _unwrap(value: Any) -> Any:
    """dbus-fast는 variant를 Variant 객체로 준다 -- 실제 값만 꺼낸다."""
    inner = getattr(value, "value", None)
    return inner if inner is not None or hasattr(value, "value") else value


def _to_result(item: Sequence[Any]) -> SearchResult:
    """SearchText가 돌려주는 결과 한 건(struct)을 SearchResult로.

    필드 순서는 CLI 클라이언트와 같다: (id, metadata, originalData, score).
    metadata는 a{sv}라 값이 Variant로 오므로 벗겨서 문자열 dict로 만든다.
    """
    raw_meta = item[1] if len(item) > 1 else {}
    metadata = {str(k): _unwrap(v) for k, v in dict(raw_meta).items()}
    return SearchResult(
        id=str(item[0]),
        metadata=metadata,
        original_data=str(item[2]) if len(item) > 2 else "",
        score=float(item[3]) if len(item) > 3 else 0.0,
    )


class DbusFastVectordbClient:
    """VectordbSearcher를 dbus-fast로 구현한다(CLI 클라이언트와 교체 가능).

    resolver는 search_text만 보므로(VectordbSearcher Protocol), 이 클라이언트를 그대로
    끼우면 상위 로직은 바뀌지 않는다. create_db·add_text는 시드용이다.
    """

    def __init__(
        self,
        config: DbusVectordbConfig | None = None,
        invoker: DbusInvoker | None = None,
    ) -> None:
        self._cfg = config or DbusVectordbConfig.from_env()
        self._invoke = invoker or self._dbus_fast_invoke

    def create_db(
        self,
        db_name: str,
        data_type: str = "TEXT",
        vector_dimension: int = 768,
        similarity_metric: str = "COSINE",
    ) -> None:
        self._sync(
            self._invoke(
                self._cfg,
                "CreateDB",
                db_name,
                [(data_type, vector_dimension, similarity_metric)],
            )
        )

    def add_text(self, input_text: str, metadata: Mapping[str, str]) -> str:
        return_id = self._sync(
            self._invoke(self._cfg, "AddText", input_text, _encode_metadata(metadata))
        )
        return str(return_id)

    def search_text(self, input_text: str, top_k: int = 1) -> list[SearchResult]:
        raw = self._sync(self._invoke(self._cfg, "SearchText", input_text, top_k))
        return [_to_result(item) for item in (raw or [])]

    # ── 실행 ──────────────────────────────────────────────────────────────

    def _sync(self, coro: Awaitable[Any]) -> Any:
        """코루틴을 완료까지 돌린다.

        FastAPI가 동기 resolver를 워커 스레드에서 부르므로 그 스레드엔 실행 중인
        이벤트 루프가 없다 -- asyncio.run이 새 루프를 만들어 돌릴 수 있다. 한 호출은
        연결→호출→해제로 끝난다. 시스템 버스는 로컬 소켓이라 매번 붙어도 싸고,
        상태를 남기지 않아 재시도·타임아웃 처리가 단순하다.
        """
        try:
            return asyncio.run(coro)  # type: ignore[arg-type]
        except VectordbClientError:
            raise
        except Exception as exc:  # noqa: BLE001 -- 어떤 버스 오류든 도메인 오류로
            raise VectordbClientError(f"D-Bus 호출 실패: {exc}") from exc

    async def _dbus_fast_invoke(
        self, cfg: DbusVectordbConfig, method: str, *args: Any
    ) -> Any:
        from dbus_fast.aio import MessageBus  # noqa: PLC0415 -- 연결 시에만 필요
        from dbus_fast.constants import BusType  # noqa: PLC0415

        bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        try:
            introspection = await bus.introspect(cfg.service, cfg.object_path)
            obj = bus.get_proxy_object(cfg.service, cfg.object_path, introspection)
            iface = obj.get_interface(cfg.interface)
            call = getattr(iface, "call_" + _snake_case(method))
            return await asyncio.wait_for(call(*args), cfg.call_timeout_seconds)
        finally:
            bus.disconnect()


def _snake_case(method: str) -> str:
    """D-Bus 메서드 이름을 dbus-fast의 프록시 메서드 이름으로.

    dbus-fast는 ``SearchText`` → ``call_search_text``로 노출한다. 대문자 앞에
    밑줄을 넣되 첫 글자는 제외한다.
    """
    out: list[str] = []
    for i, ch in enumerate(method):
        if ch.isupper() and i > 0:
            out.append("_")
        out.append(ch.lower())
    return "".join(out)
