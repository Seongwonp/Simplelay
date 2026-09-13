"""개발자 모드 서버 배선 — 기본 OFF, mock 강제, 실행 게이트, /stop 연동.

Phase 1의 완료 조건은 매니저 단위 계약(test_developer_session)이 아니라
**서버에 물렸을 때의 동작**이다:

- ``SIMPLELAY_DEV_MODE``가 없으면 매니저 자체가 없다(진입점 부재 ≠ 숨김)
- 켜져 있어도 어댑터는 무조건 mock이다
- 개발자 세션이 열려 있으면 일반 실행 API가 409로 거절된다
- fault(정지 미확인)면 일반 실행 API가 409로 거절된다
- POST /stop 은 개발자 세션도 함께 멈춘다
"""

import pytest
from fastapi.testclient import TestClient

import rpi.api.deps as deps
from rpi.main import app

_DEV_DEPS = (
    "get_service",
    "get_control_arbiter",
    "get_developer_session_manager",
    "get_appliance_registry",
    "get_readiness_registry",
)


def _clear_caches() -> None:
    for name in _DEV_DEPS:
        getattr(deps, name).cache_clear()


@pytest.fixture()
def dev_client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.setenv("SIMPLELAY_DEV_MODE", "1")
    _clear_caches()
    yield TestClient(app)
    manager = deps.get_developer_session_manager()
    if manager is not None:
        manager.close()  # 감시 스레드가 테스트 밖에 남지 않게
    _clear_caches()


@pytest.fixture()
def plain_client(monkeypatch):
    monkeypatch.delenv("SIMPLELAY_API_KEY", raising=False)
    monkeypatch.delenv("SIMPLELAY_DEV_MODE", raising=False)
    _clear_caches()
    yield TestClient(app)
    _clear_caches()


def test_developer_mode_is_off_by_default(plain_client) -> None:
    assert deps.developer_mode_enabled() is False
    assert deps.get_developer_session_manager() is None
    # 꺼져 있어도 일반 실행은 그대로 동작한다(중재자는 항상 있다).
    res = plain_client.post("/execute", json={"text": "우유 데워줘"})
    assert res.status_code == 200


def test_enabled_manager_is_mock_only_and_targets_the_registry(dev_client) -> None:
    manager = deps.get_developer_session_manager()
    assert manager is not None
    assert manager._adapter.is_mock is True  # noqa: SLF001 — mock 강제 확인

    # 레지스트리에 없는 가전은 세션을 열 수 없다.
    from rpi.services.developer_session import DevTargetUnknownError

    with pytest.raises(DevTargetUnknownError):
        manager.start("ghost", "node-1")

    # 내장 가전으로는 열린다. 보정 보고가 없으니 press는 막힌다.
    session = manager.start("microwave", "node-1")
    blocked = manager.submit(session.session_id, "microwave", "press BT-01")
    assert blocked.accepted is False
    manager.end(session.session_id)


def test_open_developer_session_blocks_normal_execution(dev_client) -> None:
    manager = deps.get_developer_session_manager()
    session = manager.start("microwave", "node-1")
    try:
        res = dev_client.post(
            "/execute-buttons", json={"buttons": ["시작"]}
        )
        assert res.status_code == 409
        assert "개발자 세션" in res.json()["detail"]
    finally:
        manager.end(session.session_id)

    # 세션이 끝나면 실행이 다시 받아진다.
    res = dev_client.post("/execute-buttons", json={"buttons": ["시작"]})
    assert res.status_code == 200


def test_fault_locks_normal_execution_until_confirmed(dev_client) -> None:
    deps.get_control_arbiter().trip_fault("stop_unconfirmed:test")
    res = dev_client.post("/execute-buttons", json={"buttons": ["시작"]})
    assert res.status_code == 409
    assert "정지가 확인되지" in res.json()["detail"]

    deps.get_control_arbiter().clear_fault()
    res = dev_client.post("/execute-buttons", json={"buttons": ["시작"]})
    assert res.status_code == 200


def test_stop_endpoint_also_stops_the_developer_session(dev_client) -> None:
    manager = deps.get_developer_session_manager()
    manager.start("microwave", "node-1")

    res = dev_client.post("/stop")

    assert res.status_code == 200
    assert manager.session is None
    assert "emergency_stop" in manager._adapter.stops()  # noqa: SLF001


def test_stop_endpoint_works_when_dev_mode_is_off(plain_client) -> None:
    res = plain_client.post("/stop")
    assert res.status_code == 200
