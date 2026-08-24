"""서버 종료 정리 절차 (교차 리뷰 #11) + /health act_mode 노출 (교차 리뷰 #12).

systemd 재시작 시 실행 중이던 물리 동작에 정지 명령 없이 프로세스가 죽으면
안 된다 — lifespan 종료가 신규 차단 → 협조 정지 → 자원 정리를 수행해야 한다.
"""

import asyncio
from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import _shutdown_cleanup, app


@dataclass
class _Status:
    running: bool


class FakeController:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True


class FakeService:
    def __init__(self, running_polls: int = 0) -> None:
        self.calls: list[str] = []
        self._running_polls = running_polls
        self._controller = FakeController()

    def request_shutdown(self) -> None:
        self.calls.append("request_shutdown")

    def emergency_stop(self) -> bool:
        self.calls.append("emergency_stop")
        return self._running_polls > 0

    def status(self) -> _Status:
        if self._running_polls > 0:
            self._running_polls -= 1
            return _Status(running=True)
        return _Status(running=False)


class FakeDb:
    def __init__(self) -> None:
        self.closed = False

    def close(self) -> None:
        self.closed = True


def test_shutdown_stops_and_closes_in_order(monkeypatch):
    service = FakeService(running_polls=2)
    db = FakeDb()
    monkeypatch.setattr(deps, "get_service", lambda: service)
    monkeypatch.setattr(deps, "get_db", lambda: db)

    asyncio.run(_shutdown_cleanup())

    assert service.calls == ["request_shutdown", "emergency_stop"]
    assert service._controller.closed
    assert db.closed


def test_shutdown_when_idle_skips_wait_but_still_closes(monkeypatch):
    service = FakeService(running_polls=0)  # emergency_stop → False (유휴)
    db = FakeDb()
    monkeypatch.setattr(deps, "get_service", lambda: service)
    monkeypatch.setattr(deps, "get_db", lambda: db)

    asyncio.run(_shutdown_cleanup())

    assert service.calls == ["request_shutdown", "emergency_stop"]
    assert service._controller.closed
    assert db.closed


def test_service_failure_does_not_block_db_close(monkeypatch):
    # 정리 중 한 단계가 죽어도 나머지 자원은 닫혀야 한다
    def broken_service():
        raise RuntimeError("service init failed")

    db = FakeDb()
    monkeypatch.setattr(deps, "get_service", broken_service)
    monkeypatch.setattr(deps, "get_db", lambda: db)

    asyncio.run(_shutdown_cleanup())  # 예외가 새어 나오면 여기서 실패

    assert db.closed


def test_no_db_is_fine(monkeypatch):
    service = FakeService()
    monkeypatch.setattr(deps, "get_service", lambda: service)
    monkeypatch.setattr(deps, "get_db", lambda: None)

    asyncio.run(_shutdown_cleanup())

    assert service.calls == ["request_shutdown", "emergency_stop"]


# ── /health act_mode ─────────────────────────────────────────────────────


@pytest.fixture()
def client():
    deps.get_service.cache_clear()
    deps.get_suggestion_service.cache_clear()
    yield TestClient(app)
    deps.get_service.cache_clear()
    deps.get_suggestion_service.cache_clear()


def test_health_reports_local_mode_by_default(client, monkeypatch):
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    assert client.get("/health").json()["act_mode"] == "local"


def test_health_reports_uart_mode(client, monkeypatch):
    # 시연 전 "실물이 진짜 움직일 설정인가"를 curl 한 번으로 확인하는 용도.
    # 서비스 싱글톤은 local 모드로 먼저 띄우고(pyserial 없는 개발 PC),
    # /health가 env를 매 요청 읽는다는 것만 검증한다.
    monkeypatch.delenv("SIMPLELAY_ACT_MODE", raising=False)
    assert client.get("/health").json()["act_mode"] == "local"
    monkeypatch.setenv("SIMPLELAY_ACT_MODE", "UART")
    assert client.get("/health").json()["act_mode"] == "uart"
