"""ThinQ 경로·시나리오 API (U1-b·U1-c 모의). ``router.py``가 포함한다.

- ``GET  /thinq/devices``            ThinQ 기기·등록 가전·동작 표(모드 off면 404)
- ``GET  /thinq/status/{id}``        가전 상태 다시 조회("보냈지만 확인 못 함" 뒤 재조회)
- ``POST /thinq/command``            직접 명령 1건 → job_id (요청 자체가 승인)
- ``GET  /readiness/{id}``           경로별 준비 상태(물리 4축 / ThinQ 모드·연결·기기)
- ``GET  /scenarios``                시나리오 정의
- ``GET  /scenarios/last-run``       마지막 명령 실행의 단계별 결과(경로·수신·확인 근거)
- ``POST /demo/scenario/{id}``       시연 트리거 → 제안 카드(실행하지 않음)
- ``POST /demo/thinq/event``         모의 ThinQ 이벤트 주입(세탁 완료 등) — mock 모드만
- ``GET  /thinq/events``             최근 모의 이벤트
- ``POST /demo/thinq/fault``         모의 ThinQ 지속 장애 주입(오프라인·접수됨·접수 불명·지연) — mock 모드만
- ``GET  /demo/thinq/fault``         지금 걸린 모의 장애

``/demo/*``는 다른 리허설 경로와 같은 보호(API 키)를 받고, ThinQ 이벤트 주입은
추가로 **mock 모드에서만** 열린다 -- real 모드에서 가짜 이벤트가 실제처럼 섞이지 않게.
"""

from __future__ import annotations

import asyncio
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from rpi.commands import Command
from rpi.intent.rules import UnknownIntentError

from .deps import get_appliance_registry, get_readiness_registry, get_service
from .service import SimpleLayService

router = APIRouter()


def _thinq_on(service: SimpleLayService):
    controller = service.thinq_controller
    if controller is None:
        raise HTTPException(404, "ThinQ 연동이 꺼져 있어요 (SIMPLELAY_THINQ_MODE=off)")
    return controller


def _capabilities(binding) -> list[dict]:
    return [
        {"action": c.action, "label": c.label, "arg": c.arg, "allowed": list(c.allowed),
         "value_labels": dict(c.value_labels)}
        for c in binding.capabilities
    ]


@router.get("/thinq/devices")
async def thinq_devices(service: SimpleLayService = Depends(get_service),
                        registry=Depends(get_appliance_registry)) -> dict:
    controller = _thinq_on(service)
    try:
        devices = await asyncio.to_thread(controller.client.list_devices)
        reachable, error = True, None
    except NotImplementedError as exc:
        devices, reachable, error = (), False, str(exc)
    except Exception:  # noqa: BLE001
        devices, reachable, error = (), False, "ThinQ 클라우드에 연결되지 않았어요"
    appliances = []
    for appliance in registry.system_appliances():
        if appliance.thinq is None:
            continue
        readiness = await asyncio.to_thread(service.thinq_readiness, appliance.appliance_id)
        appliances.append({
            "appliance_id": appliance.appliance_id,
            "name": appliance.name,
            "device_id": appliance.thinq.device_id,
            "device_type": appliance.thinq.device_type,
            "read_only": appliance.thinq.read_only,
            "capabilities": _capabilities(appliance.thinq),
            "functions": [f.purpose for f in appliance.thinq.functions],
            "readiness": readiness.state,
            "readiness_reasons": list(readiness.reasons),
            "can_execute": readiness.can_execute,
        })
    return {
        "mode": controller.mode.value,
        "execution_mode": controller.execution_mode.value,
        "client_reachable": reachable,
        "error": error,
        "devices": [
            {"device_id": d.device_id, "device_type": d.device_type, "alias": d.alias,
             "model_name": d.model_name, "online": d.online}
            for d in devices
        ],
        "appliances": appliances,
    }


@router.get("/thinq/status/{appliance_id}")
async def thinq_status(appliance_id: str, service: SimpleLayService = Depends(get_service),
                       registry=Depends(get_appliance_registry)) -> dict:
    controller = _thinq_on(service)
    appliance = registry.get(appliance_id)
    if appliance is None or appliance.thinq is None:
        raise HTTPException(404, "ThinQ 가전이 아니에요")
    try:
        state = await asyncio.to_thread(controller.client.get_status, appliance.thinq.device_id)
    except NotImplementedError as exc:
        raise HTTPException(503, str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(503, "상태를 읽지 못했어요 — 가전·인터넷 연결을 확인해 주세요") from exc
    return {"appliance_id": appliance_id, "execution_mode": controller.execution_mode.value,
            "state": state}


class ThinqCommandRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    appliance_id: str = Field(min_length=1, max_length=64)
    action: str = Field(min_length=1, max_length=40)
    args: dict[str, str | int | float | bool] = Field(default_factory=dict, max_length=16)


@router.post("/thinq/command")
async def thinq_command(body: ThinqCommandRequest,
                        service: SimpleLayService = Depends(get_service)) -> dict:
    """직접 명령 — 사용자의 요청 자체가 승인이다(계약 §4-5). 재해석하지 않는다."""
    try:
        command = Command.thinq(body.appliance_id, body.action, body.args)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    try:
        job_id = await asyncio.to_thread(service.submit_command, command)
    except UnknownIntentError as exc:
        raise HTTPException(422, str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(409, str(exc)) from exc
    return {"job_id": job_id}


@router.get("/readiness/{appliance_id}")
async def readiness(appliance_id: str, service: SimpleLayService = Depends(get_service),
                    registry=Depends(get_appliance_registry),
                    readiness_registry=Depends(get_readiness_registry)) -> dict:
    appliance = registry.get(appliance_id)
    if appliance is None:
        raise HTTPException(404, "appliance not found")
    route = appliance.control_path.value
    if appliance.thinq is not None:
        r = await asyncio.to_thread(service.thinq_readiness, appliance_id)
        return {
            "appliance_id": appliance_id, "route": route, "state": r.state,
            "can_execute": r.can_execute, "reasons": list(r.reasons),
            "thinq": {"mode": r.mode, "client_reachable": r.client_reachable,
                      "device_present": r.device_present, "device_online": r.device_online,
                      "read_only": r.read_only},
        }
    r = readiness_registry.get(appliance_id)
    local = service.runs_locally(appliance_id)
    system = appliance_id in service._system_controllers
    return {
        "appliance_id": appliance_id, "route": route,
        "state": r.state.value, "can_execute": r.can_execute or local or system,
        "reasons": [] if (local or system) else list(r.blocking_reasons),
        "physical": {c.value: r.is_ready(c) for c in r.checks},
        "runs_locally": local,
        "mock_system": system,
    }


@router.get("/scenarios")
async def scenarios() -> list[dict]:
    from .thinq_wiring import get_scenario_engine  # noqa: PLC0415

    engine = get_scenario_engine()
    return [
        {
            "scenario_id": d.scenario_id, "name": d.name, "question": d.question,
            "trigger": {"kind": d.trigger.kind, "appliance_id": d.trigger.appliance_id,
                        "event": d.trigger.event,
                        "allow_mock_success": d.trigger.allow_mock_success},
            "steps": [
                {"target_id": s.target_id, "route": s.route.value, "action": s.action,
                 "args": dict(s.args), "buttons": list(s.buttons)}
                for s in d.steps
            ],
        }
        for d in engine.catalog.list()
    ]


@router.get("/scenarios/last-run")
async def scenarios_last_run(service: SimpleLayService = Depends(get_service)) -> dict:
    run = service.last_run()
    return {"run": run.as_dict() if run is not None else None}


def suggestion_payload(s) -> dict:
    return {
        "id": s.suggestion_id, "purpose": s.purpose, "time_band": s.time_band,
        "occurrences": s.occurrences, "steps": list(s.steps), "reason": s.reason,
        "appliance_id": s.appliance_id, "is_demo": s.is_demo or s.time_band == "데모",
        "scenario_id": s.scenario_id,
        "commands": command_payloads(s),
    }


def command_payloads(s) -> list[dict]:
    return [
        {"target_id": c.target_id, "route": c.route.value, "action": c.action,
         "args": c.args_dict(), "buttons": list(c.buttons), "summary": summary}
        for c, summary in zip(s.commands, s.command_summaries)
    ]


@router.post("/demo/scenario/{scenario_id}")
async def demo_scenario(scenario_id: str) -> dict:
    from rpi.scenarios import ScenarioUnavailableError  # noqa: PLC0415

    from .thinq_wiring import get_scenario_engine  # noqa: PLC0415

    engine = get_scenario_engine()
    try:
        suggestion = await asyncio.to_thread(engine.trigger_manual, scenario_id)
    except KeyError as exc:
        raise HTTPException(404, "scenario not found") from exc
    except ScenarioUnavailableError as exc:
        raise HTTPException(409, f"시나리오를 지금 제안할 수 없어요: {exc}") from exc
    if suggestion is None:
        raise HTTPException(409, "DND is active or the scenario is muted")
    return suggestion_payload(suggestion)


class ThinqEventRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    event: Literal["wash_complete", "wash_start"]


@router.post("/demo/thinq/event")
async def demo_thinq_event(body: ThinqEventRequest,
                           service: SimpleLayService = Depends(get_service)) -> dict:
    controller = _thinq_on(service)
    inject = getattr(controller.client, "inject_event", None)
    if inject is None:
        raise HTTPException(409, "모의(mock) 모드에서만 이벤트를 주입할 수 있어요")
    return await asyncio.to_thread(inject, body.event)


@router.get("/thinq/events")
async def thinq_events(service: SimpleLayService = Depends(get_service)) -> dict:
    controller = _thinq_on(service)
    events = getattr(controller.client, "events", None)
    return {"events": list(events()) if events is not None else []}


class ThinqFaultRequest(BaseModel):
    """리허설용 지속 장애(G6). ``device_id``에는 ThinQ 기기 ID나 가전 ID(air_purifier 등)."""

    model_config = ConfigDict(extra="forbid")
    device_id: str = Field(min_length=1, max_length=64)
    mode: Literal["normal", "offline", "unconfirmed", "lost"]
    latency_ms: int | None = Field(default=None, ge=0, le=30_000)


def _fault_client(service: SimpleLayService):
    controller = _thinq_on(service)
    client = controller.client
    if getattr(client, "set_fault", None) is None:
        raise HTTPException(409, "모의(mock) 모드에서만 장애를 주입할 수 있어요")
    return client


@router.post("/demo/thinq/fault")
async def demo_thinq_fault(body: ThinqFaultRequest,
                           service: SimpleLayService = Depends(get_service),
                           registry=Depends(get_appliance_registry)) -> dict:
    """모의 클라이언트에 지속 장애를 건다 — ``mode: normal``로 걷어 낼 때까지 유지된다.

    - offline: 준비 상태 disconnected, 실행 요청은 412(보내지 않음).
    - unconfirmed: 명령은 접수되지만 상태가 바뀌지 않는다 → ``접수됨``(unconfirmed/accepted/none).
    - lost: 명령 뒤 응답을 잃는다 → ``접수 불명``(unconfirmed/unknown/none). 자동 재전송 없음.
    - latency_ms: 그 기기 조회·전송마다 지연. 확인 대기 상한(SIMPLELAY_THINQ_CONFIRM_SECONDS)을
      넘기면 상태가 바뀌어도 ``접수됨``으로 끝난다.
    """
    client = _fault_client(service)
    device_id = body.device_id
    appliance = registry.get(device_id)
    if appliance is not None and appliance.thinq is not None:
        device_id = appliance.thinq.device_id
    try:
        view = await asyncio.to_thread(client.set_fault, device_id, body.mode, body.latency_ms)
    except KeyError as exc:
        raise HTTPException(404, "모의 ThinQ 기기를 찾지 못했어요") from exc
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    return view


@router.get("/demo/thinq/fault")
async def demo_thinq_faults(service: SimpleLayService = Depends(get_service)) -> dict:
    client = _fault_client(service)
    return {"faults": list(client.faults().values())}
