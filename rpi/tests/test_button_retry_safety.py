"""R1: unknown 기본값과 L1/L2 재누름 차단. 가짜 모션, 실물 검증 아님."""
import pytest

from rpi.controller import ClosedLoopController, MockAcceptanceVerifier
from rpi.controller.mock import MockGrblClient, MockAlertSink, MockSafetyController
from rpi.verifier import MockVerifier
from rpi.commands.physical import status_of


@pytest.mark.parametrize("layer", ["L1", "L2"])
def test_unclassified_button_is_not_pressed_twice(layer):
    motion = MockGrblClient()
    controller = ClosedLoopController(
        motion, MockVerifier([False, True, True] if layer == "L1" else [True, True, True]),
        MockAlertSink(), MockSafetyController(),
        acceptance=MockAcceptanceVerifier([False, True, True]) if layer == "L2" else None,
    )
    result = controller.execute(["시작", "다음"])
    assert len(motion.commands) == 1
    assert result.buttons[0].attempts == 1
    assert status_of(result).value == "unconfirmed"


@pytest.mark.parametrize("behavior", ["toggle", "unknown", "idempotent"])
@pytest.mark.parametrize("layer", ["L1", "L2"])
def test_declared_behavior_controls_both_retry_paths(behavior, layer):
    motion = MockGrblClient()
    controller = ClosedLoopController(
        motion, MockVerifier([False, True, True] if layer == "L1" else [True, True, True]),
        MockAlertSink(), MockSafetyController(),
        acceptance=MockAcceptanceVerifier([False, True, True]) if layer == "L2" else None,
    )
    result = controller.execute(["시험 버튼"], button_behaviors={"시험 버튼": behavior})
    safe = behavior == "idempotent"
    assert len(motion.commands) == (2 if safe else 1)
    assert status_of(result).value == ("succeeded" if safe else "unconfirmed")
    assert result.buttons[0].reinputs == (1 if safe and layer == "L2" else 0)


@pytest.mark.parametrize("label,safe", [("시작", False), ("즉석밥", False), ("10초", True)])
@pytest.mark.parametrize("layer", ["L1", "L2"])
def test_service_to_real_link_executor_and_history(label, safe, layer):
    """RPi5 서비스→동기 브리지→줄 규약→RPi4 실행기→공유 폐루프→기록."""
    import asyncio
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.services.act_client import ActClient
    from rpi.services.act_client_controller import ActClientController
    from rpi.services.appliance_registry import ApplianceRegistry
    from rpi.services.history import InMemoryJobHistory
    from rpi4.services.act_executor import ActExecutor
    from rpi4.tests.test_act_link_integration import _make_link

    async def scenario():
        r4, w4, r5, w5 = _make_link()
        motion = MockGrblClient()
        controller = ClosedLoopController(
            motion, MockVerifier([False, True] if layer == "L1" else [True, True]),
            MockAlertSink(), MockSafetyController(),
            acceptance=MockAcceptanceVerifier([False, True]) if layer == "L2" else None,
        )
        executor = ActExecutor(reader=r4, writer=w4, controller=controller)
        client = ActClient(r5, w5)
        history = InMemoryJobHistory()
        service = SimpleLayService(
            RuleBasedIntentResolver(), ActClientController(asyncio.get_running_loop(), client),
            appliance_registry=ApplianceRegistry(), history_store=history,
        )
        await client.start()
        receive = asyncio.create_task(executor.run())
        for _ in range(100):
            if client.estop_latched is False:
                break
            await asyncio.sleep(0.01)
        assert client.estop_latched is False
        try:
            result = await asyncio.to_thread(service.execute_buttons, (label,), "microwave")
            assert len(motion.commands) == (2 if safe else 1)
            assert status_of(result).value == ("succeeded" if safe else "unconfirmed")
            entry, = history.recent()
            assert entry.retry_count == (1 if safe else 0)
            if not safe:
                assert entry.outcome == "unconfirmed"
                assert "눌렸는지 확인하지 못했어요" in entry.detail
        finally:
            r4.feed_eof()
            await receive
            await client.stop()
    asyncio.run(scenario())


@pytest.mark.parametrize("entrypoint", ["/execute-buttons", "/execute"])
def test_api_unconfirmed_status_and_history(entrypoint):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from rpi.api.deps import get_service, get_job_history
    from rpi.api.router import router
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.services.appliance_registry import ApplianceRegistry
    from rpi.services.history import InMemoryJobHistory
    from rpi.tests.test_button_map_extension import _wait_done

    motion = MockGrblClient()
    service = SimpleLayService(
        RuleBasedIntentResolver({"시험": ("시작", "10초")}),
        ClosedLoopController(motion, MockVerifier([False, True, True]),
                             MockAlertSink(), MockSafetyController()),
        appliance_registry=ApplianceRegistry(), history_store=InMemoryJobHistory(),
    )
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_service] = lambda: service
    app.dependency_overrides[get_job_history] = lambda: service._history_store
    with TestClient(app) as client:
        payload = {"appliance_id": "microwave"}
        payload.update({"buttons": ["시작", "10초"]} if entrypoint.endswith("buttons") else {"text": "시험"})
        response = client.post(entrypoint, json=payload)
        assert response.status_code == 200, response.text
        body = _wait_done(client, response.json()["job_id"])
        assert len(motion.commands) == 1
        assert body["last_outcome"] == "unconfirmed"
        assert "눌렸는지 확인하지 못했어요" in body["last_detail"]
        # 기존 폰은 abort_reason이 있으면 '누르지 못함'으로 표시한다.
        # 관측 미확인은 모션 중단을 뜻하는 공개 필드에 넣지 않는다.
        assert body["last_abort_reason"] is None
        entry, = client.get("/history").json()
        assert entry["outcome"] == "unconfirmed" and entry["abort_reason"] is None
        assert entry["buttons"][0]["attempts"] == 1
        assert "눌렸는지 확인하지 못했어요" in entry["detail"]


def test_grid_registry_and_persistence_preserve_behavior(tmp_path):
    from pathlib import Path
    from dataclasses import replace
    from rpi.intent.appliance import load_button_map
    from rpi.services.appliance_registry import BUILTIN_MICROWAVE
    from rpi.services.persistence import SimpleLayDb
    grid = load_button_map(Path("docs/button-maps/microwave.json"))
    assert {b.label: b.behavior for b in grid.buttons} == {
        b.label: b.behavior for b in BUILTIN_MICROWAVE.buttons
    }
    path = str(tmp_path / "behavior.db")
    db = SimpleLayDb(path)
    db.save_appliance(replace(BUILTIN_MICROWAVE, appliance_id="custom_test"))
    loaded, = SimpleLayDb(path).appliances()
    assert loaded.buttons == BUILTIN_MICROWAVE.buttons


@pytest.mark.parametrize("raw", [None, "", "safe", True, {}, ["idempotent"]])
def test_invalid_metadata_is_unknown(raw):
    import json
    from rpi4.models.act_messages import parse_act_message
    message = parse_act_message(json.dumps({
        "type": "execute", "sequence_id": "r1", "appliance_id": "microwave",
        "buttons": ["시작"], "button_behaviors": {"시작": raw},
    }))
    assert message.button_behaviors == {"시작": "unknown"}


@pytest.mark.parametrize("layer", ["L1", "L2"])
def test_stop_during_verification_keeps_user_stop_outcome(layer):
    class Verifier(MockVerifier):
        def verify(self, button):
            if layer == "L1":
                controller.request_stop()
            return super().verify(button)
    class Acceptance(MockAcceptanceVerifier):
        def verify_acceptance(self, button):
            controller.request_stop()
            return super().verify_acceptance(button)
    motion = MockGrblClient()
    controller = ClosedLoopController(
        motion, Verifier([layer == "L2"]), MockAlertSink(), MockSafetyController(),
        acceptance=Acceptance([False]) if layer == "L2" else None,
    )
    result = controller.execute(["시작"])
    assert len(motion.commands) == 1
    assert result.abort_reason is None
    assert result.status.value == "safety_stopped"


@pytest.mark.parametrize("error_type", [RuntimeError, pytest.param(None, id="sensor-unavailable")])
def test_verifier_error_closes_window_and_reports_unknown(error_type):
    from rpi.verifier import SensorUnavailable
    cancelled = []
    class Verifier:
        def verify(self, button):
            raise (error_type or SensorUnavailable)("test read failure")
        def cancel_press(self):
            cancelled.append(True)
    motion = MockGrblClient()
    controller = ClosedLoopController(motion, Verifier(), MockAlertSink(), MockSafetyController())
    result = controller.execute(["시작"])
    assert len(motion.commands) == 1
    assert cancelled
    assert status_of(result).value == "unconfirmed"


def test_approved_plan_stops_after_unknown_and_keeps_unconfirmed_event():
    from datetime import datetime, timezone
    from rpi.commands import ApprovedCommand, Command
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.services.appliance_registry import ApplianceRegistry
    from rpi.services.history import InMemoryJobHistory
    motion, history, events = MockGrblClient(), InMemoryJobHistory(), []
    service = SimpleLayService(
        RuleBasedIntentResolver(),
        ClosedLoopController(motion, MockVerifier([False, True, True]),
                             MockAlertSink(), MockSafetyController()),
        appliance_registry=ApplianceRegistry(), history_store=history,
        job_listeners=(events.append,),
    )
    approved = tuple(ApprovedCommand(Command.physical("microwave", (label,)),
                                    "card", datetime.now(timezone.utc), label)
                     for label in ("시작", "10초"))
    record = service.execute_approved(approved)
    assert len(motion.commands) == 1
    assert record.results[0].status.value == "unconfirmed"
    assert "눌렸는지 확인하지 못했어요" in record.results[0].detail
    assert history.recent()[0].outcome == "unconfirmed"
    assert len(events) == 1 and events[0].status == "unconfirmed"


def test_behavior_does_not_leak_from_previous_run_or_other_appliance():
    from dataclasses import replace
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.services.appliance_registry import ApplianceRegistry, BUILTIN_MICROWAVE
    registry = ApplianceRegistry()
    custom = replace(BUILTIN_MICROWAVE, appliance_id="custom_test", buttons=tuple(
        replace(b, behavior="unknown") for b in BUILTIN_MICROWAVE.buttons))
    registry.register(custom)
    motion = MockGrblClient()
    controller = ClosedLoopController(motion, MockVerifier([False, True, False, True]),
                                      MockAlertSink(), MockSafetyController())
    service = SimpleLayService(RuleBasedIntentResolver(), controller, appliance_registry=registry)
    assert service._button_behaviors_snapshot("microwave", ("10초",)) == {"10초": "idempotent"}
    assert service._button_behaviors_snapshot("custom_test", ("10초",)) == {"10초": "unknown"}
    controller.execute(["10초"], button_behaviors={"10초": "idempotent"})
    result = controller.execute(["10초"])
    assert len(motion.commands) == 3  # 2 + 1, 앞 실행의 허용을 물려받지 않는다.
    assert status_of(result).value == "unconfirmed"


def test_explicit_whole_sequence_rerun_repeats_successful_prefix_report_only():
    """사용자가 새로 실행하면 성공했던 앞 토글도 다시 누름: 이번 수정 범위 밖인 잔존 위험."""
    motion = MockGrblClient()
    controller = ClosedLoopController(motion, MockVerifier([True, False, True, True]),
                                      MockAlertSink(), MockSafetyController())
    for _ in range(2):
        controller.execute(["시작", "즉석밥"], button_behaviors={"시작": "toggle"})
    assert [c.button for c in motion.commands] == ["시작", "즉석밥", "시작", "즉석밥"]


@pytest.mark.parametrize("metadata,expected", [({}, "unknown"),
                         ({"behavior": "idempotent"}, "idempotent"),
                         ({"behavior": "safe"}, "unknown")])
def test_registration_api_and_restart_keep_behavior(tmp_path, metadata, expected):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from rpi.api.deps import get_appliance_registry, get_service, get_node_registry
    from rpi.api.router import router
    from rpi.api.service import SimpleLayService
    from rpi.intent import RuleBasedIntentResolver
    from rpi.services.appliance_registry import ApplianceRegistry
    from rpi.services.node_registry import NodeRegistry
    from rpi.services.persistence import SimpleLayDb
    path = str(tmp_path / "registered.db")
    registry = ApplianceRegistry(store=SimpleLayDb(path))
    service = SimpleLayService(RuleBasedIntentResolver(),
        ClosedLoopController(MockGrblClient(), MockVerifier([True]),
                             MockAlertSink(), MockSafetyController()),
        appliance_registry=registry)
    app = FastAPI()
    app.include_router(router)
    app.dependency_overrides[get_service] = lambda: service
    app.dependency_overrides[get_appliance_registry] = lambda: registry
    app.dependency_overrides[get_node_registry] = lambda: NodeRegistry()
    with TestClient(app) as client:
        response = client.put("/appliances/custom_r1", json={
            "name": "시험 가전", "rows": 1, "cols": 1,
            "buttons": [{"id": "b1", "label": "시험 버튼", "x": 0, "y": 0, **metadata}],
        })
        assert response.status_code == 200, response.text
        assert response.json()["buttons"][0]["behavior"] == expected
    reopened = ApplianceRegistry(store=SimpleLayDb(path))
    assert reopened.get("custom_r1").buttons[0].behavior == expected
