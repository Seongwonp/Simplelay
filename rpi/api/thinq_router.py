"""ThinQ 경로·시나리오 API (U1-b·U1-c 모의). ``router.py``가 포함한다.

- ``GET  /thinq/devices``            ThinQ 기기·등록 가전·동작 표(모드 off면 404)
- ``GET  /thinq/discovered``         ThinQ 계정에서 찾은 가전·지원 여부·추가 여부(등록 안 함)
- ``POST /thinq/added``              찾은 가전 하나를 추가(사용자 확인, 서버 DB에 남음)
- ``DELETE /thinq/added/{key}``      추가한 가전 빼기(환경 변수로 넣은 가전은 409)
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
- ``POST /demo/thinq/air-quality``   모의 공기청정기 센서 값 주입 → 공기질 판독 1회(2026-10-15) — mock·fake_cloud만, real은 409

``/demo/*``는 다른 리허설 경로와 같은 보호(API 키)를 받고, ThinQ 이벤트 주입은
추가로 **mock 모드에서만** 열린다 -- real 모드에서 가짜 이벤트가 실제처럼 섞이지 않게.

**기기 ID 원문은 서버 안에만 둔다(3차 평가 M3, 2026-10-14).** 응답에는 기기 ID 대신 ``key``(``device_key``,
`rpi/services/thinq/discovery.py`)와 가전 ID를 싣는다 — ``/thinq/devices``·이벤트·장애 주입 응답 모두. 앱·키오스크는
원문 ID를 쓰지 않는다(소비자 확인: 폰은 ``appliances[].appliance_id``·이름·준비 상태만 읽는다).
"""

from __future__ import annotations

import asyncio
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from rpi.commands import Command
from rpi.intent.rules import UnknownIntentError

from .deps import get_appliance_registry, get_node_registry, get_readiness_registry, get_service
from .readiness_view import readiness_view
from .service import SimpleLayService

router = APIRouter()


def _thinq_on(service: SimpleLayService):
    controller = service.thinq_controller
    if controller is None:
        raise HTTPException(404, "ThinQ 연동이 꺼져 있어요 (SIMPLELAY_THINQ_MODE=off)")
    return controller


def _key(device_id: str) -> str:
    from rpi.services.thinq.discovery import device_key  # noqa: PLC0415

    return device_key(device_id)


def _public(record: dict, registry) -> dict:
    """응답용 사본 — ``device_id`` 원문을 빼고 ``device_key``와(등록돼 있으면) 가전 ID를 싣는다(3차 평가 M3)."""
    out = {k: v for k, v in record.items() if k != "device_id"}
    device_id = record.get("device_id")
    if isinstance(device_id, str):
        out["device_key"] = _key(device_id)
        appliance = next((a for a in registry.system_appliances()
                          if a.thinq is not None and a.thinq.device_id == device_id), None)
        out["appliance_id"] = appliance.appliance_id if appliance is not None else None
    return out


def _reason(exc: Exception, fallback: str) -> str:
    from rpi.services.thinq.client import ThinqClientError  # noqa: PLC0415

    reason = getattr(exc, "reason", None) if isinstance(exc, ThinqClientError) else None
    return reason if isinstance(reason, str) and reason else fallback


def _capabilities(binding, support: dict | None = None) -> list[dict]:
    """동작 표. ``profile_allowed``는 이 기기 프로필이 실제로 허용하는 값(프로필을 못 읽었으면 None)."""
    support = support or {}
    return [
        {"action": c.action, "label": c.label, "arg": c.arg, "allowed": list(c.allowed),
         "value_labels": dict(c.value_labels),
         "profile_allowed": support[c.action]["allowed"] if c.action in support else None}
        for c in binding.capabilities
    ]


@router.get("/thinq/devices")
async def thinq_devices(service: SimpleLayService = Depends(get_service),
                        registry=Depends(get_appliance_registry)) -> dict:
    controller = _thinq_on(service)
    try:
        devices = await asyncio.to_thread(controller.client.list_devices)
        reachable, error = True, None
    except Exception as exc:  # noqa: BLE001 -- 사람 말 이유만 싣는다(토큰 없음)
        devices, reachable, error = (), False, _reason(exc, "ThinQ 클라우드에 연결되지 않았어요")
    appliances = []
    for appliance in registry.system_appliances():
        if appliance.thinq is None:
            continue
        readiness = await asyncio.to_thread(service.thinq_readiness, appliance.appliance_id)
        support = await asyncio.to_thread(controller.profile_support, appliance.appliance_id)
        appliances.append({
            "appliance_id": appliance.appliance_id,
            "name": appliance.name,
            # 3차 평가 M3: 원문 기기 ID 대신 key(발견 API와 같은 값).
            "device_key": _key(appliance.thinq.device_id),
            "device_type": appliance.thinq.device_type,
            "read_only": appliance.thinq.read_only,
            "capabilities": _capabilities(appliance.thinq, support),
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
            {"key": _key(d.device_id), "device_type": d.device_type, "alias": d.alias,
             "model_name": d.model_name, "online": d.online}
            for d in devices
        ],
        "appliances": appliances,
    }


@router.get("/thinq/discovered")
async def thinq_discovered(service: SimpleLayService = Depends(get_service),
                           registry=Depends(get_appliance_registry)) -> dict:
    """ThinQ 계정에서 찾은 가전(종류·별칭·지원 여부·추가 여부). **아무것도 등록하지 않는다.**

    목록 조회가 실패하면 200에 ``reachable: false``와 사람 말 이유(``error``) -- '0대'와 섞지 않는다.
    기기 ID 원문 대신 ``key``를 준다.
    """
    from .thinq_wiring import discover  # noqa: PLC0415

    controller = _thinq_on(service)
    return await asyncio.to_thread(discover, controller, registry)


class ThinqAddRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    key: str = Field(min_length=1, max_length=64)


@router.post("/thinq/added")
async def thinq_add(body: ThinqAddRequest, service: SimpleLayService = Depends(get_service),
                    registry=Depends(get_appliance_registry)) -> dict:
    """사용자가 고른 가전 하나를 추가한다(사용자 확인). 추가해도 실행은 종전처럼 승인을 거친다."""
    from .thinq_wiring import DiscoveryError, add_discovered  # noqa: PLC0415

    controller = _thinq_on(service)
    try:
        return await asyncio.to_thread(add_discovered, controller, registry, body.key)
    except DiscoveryError as exc:
        raise HTTPException(exc.status, exc.reason) from None


@router.delete("/thinq/added/{key}")
async def thinq_remove(key: str, service: SimpleLayService = Depends(get_service),
                       registry=Depends(get_appliance_registry)) -> dict:
    from .thinq_wiring import DiscoveryError, remove_added  # noqa: PLC0415

    _thinq_on(service)
    try:
        return await asyncio.to_thread(remove_added, registry, key)
    except DiscoveryError as exc:
        raise HTTPException(exc.status, exc.reason) from None


@router.get("/thinq/status/{appliance_id}")
async def thinq_status(appliance_id: str, service: SimpleLayService = Depends(get_service),
                       registry=Depends(get_appliance_registry)) -> dict:
    controller = _thinq_on(service)
    appliance = registry.get(appliance_id)
    if appliance is None or appliance.thinq is None:
        raise HTTPException(404, "ThinQ 가전이 아니에요")
    try:
        state = await asyncio.to_thread(controller.client.get_status, appliance.thinq.device_id)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(503, _reason(exc, "상태를 읽지 못했어요 — 가전·인터넷 연결을 확인해 주세요")) from None
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
                    readiness_registry=Depends(get_readiness_registry),
                    nodes=Depends(get_node_registry)) -> dict:
    # 가전 목록 잠금은 등록·보정의 DB 쓰기 동안 잡힌다 — 이벤트 루프에서 기다리지 않는다(2026-10-14 HIGH 재확인 H-R2).
    appliance = await asyncio.to_thread(registry.get, appliance_id)
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
    # 가전 목록과 같은 판정(같은 대상·같은 조건 → 같은 state·can_execute·reasons, 걸림 사유 포함).
    state, reasons, can_execute = readiness_view(appliance, service, nodes)
    return {
        "appliance_id": appliance_id, "route": route,
        "state": state, "can_execute": can_execute,
        "reasons": reasons,
        "physical": {c.value: r.is_ready(c) for c in r.checks},
        "runs_locally": local,
        "mock_system": system,
    }


@router.get("/scenarios")
async def scenarios() -> list[dict]:
    from .deps import build_off_loop, get_suggestion_service  # noqa: PLC0415
    from .thinq_wiring import get_scenario_engine  # noqa: PLC0415

    await build_off_loop(get_suggestion_service)  # 시나리오 엔진은 제안 서비스가 만든다 — 최초 생성은 루프 밖에서(외부 재확인 3차)
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

    from .deps import build_off_loop, get_suggestion_service  # noqa: PLC0415
    from .thinq_wiring import get_scenario_engine  # noqa: PLC0415

    await build_off_loop(get_suggestion_service)  # 최초 생성은 루프 밖에서(외부 재확인 3차)
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
                           service: SimpleLayService = Depends(get_service),
                           registry=Depends(get_appliance_registry)) -> dict:
    controller = _thinq_on(service)
    inject = getattr(controller.client, "inject_event", None)
    if inject is None:
        raise HTTPException(409, "모의(mock) 모드에서만 이벤트를 주입할 수 있어요")
    # 시나리오 엔진은 제안 서비스와 함께 만들어지고 그때 이벤트를 구독한다. 서버를
    # 막 띄워 이벤트가 첫 요청이면 구독 전이라 카드가 조용히 안 생겼다(2026-09-29).
    from .thinq_wiring import get_scenario_engine  # noqa: PLC0415

    await asyncio.to_thread(get_scenario_engine)
    return _public(await asyncio.to_thread(inject, body.event), registry)


class AirQualityInjectRequest(BaseModel):
    """리허설용 모의 센서 값(2026-10-15). ``NONE``은 센서 칸 없음(꺼짐·센서 준비 중 흉내)."""

    model_config = ConfigDict(extra="forbid")
    level: Literal["GOOD", "NORMAL", "BAD", "VERY_BAD", "NONE"]
    pm2: int | None = Field(default=None, ge=0, le=999)
    pm10: int | None = Field(default=None, ge=0, le=999)
    #: 재알림 기억(다시 준비·카드 뒤 쉬는 시간)을 지우고 판독 — 리허설을 되풀이할 때만.
    forget_recent: bool = False


@router.post("/demo/thinq/air-quality")
async def demo_thinq_air_quality(body: AirQualityInjectRequest,
                                 service: SimpleLayService = Depends(get_service),
                                 registry=Depends(get_appliance_registry)) -> dict:
    """모의 공기청정기 센서 값을 넣고 공기질 판독을 한 번 바로 한다(주기를 기다리지 않는다). 결과는 ``check``
    (``offered``·``no_data``·``ok``·``already_strong``·``waiting_rearm``·``card_quiet``·``not_offered`` 등)와 떠 있는
    공기질 카드. **real 모드에서는 409** — 실제 공기청정기 값 자리에 모의 값을 섞지 않는다. 응답·카드는 모의로 표시한다."""
    from .air_quality_wiring import AirInjectError, inject_mock_air  # noqa: PLC0415

    controller = _thinq_on(service)
    try:
        return await asyncio.to_thread(inject_mock_air, controller, registry, body.level, body.pm2, body.pm10,
                                       body.forget_recent)
    except AirInjectError as exc:
        raise HTTPException(exc.status, exc.reason) from None


@router.get("/thinq/events")
async def thinq_events(service: SimpleLayService = Depends(get_service),
                       registry=Depends(get_appliance_registry)) -> dict:
    controller = _thinq_on(service)
    events = getattr(controller.client, "events", None)
    return {"events": [_public(dict(e), registry) for e in events()] if events is not None else []}


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
        raise HTTPException(404, "모의 ThinQ 기기를 찾지 못했어요") from None
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    return _public(view, registry)


@router.get("/demo/thinq/fault")
async def demo_thinq_faults(service: SimpleLayService = Depends(get_service),
                            registry=Depends(get_appliance_registry)) -> dict:
    client = _fault_client(service)
    return {"faults": [_public(dict(v), registry) for v in client.faults().values()]}
