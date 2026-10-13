"""사용자 루틴 API (2026-09-30) — 계약은 docs/devlog/devlog_2026-09-30-routines.md.

저장·수정·켜기/끄기·다음 실행·템플릿·'지금 실행'(카드 만들기)·실행 기록. 이 모듈에는
**실행 진입점이 없다.** 실행은 ``POST /suggestions/{id}/approve``로만 일어난다.
검증 오류는 422이며 detail은 화면에 그대로 보여도 되는 한국어 문장이다.
"""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Body, HTTPException, Query

from rpi.routines import (
    RoutineNotFoundError,
    RoutineUnavailableError,
    RoutineValidationError,
    build_routine,
    template_payloads,
    validate_against,
)
from rpi.routines.model import MODE_LABELS
from rpi.routines.wiring import get_routine_engine, get_routine_store

from .deps import get_appliance_registry, get_clock, get_service
from .thinq_router import suggestion_payload

router = APIRouter()


def _payload(routine, names=None) -> dict:
    data = routine.to_dict()
    data["when"] = routine.trigger.describe(names)
    data["mode_label"] = MODE_LABELS[routine.mode]
    return data


def _names() -> dict[str, str]:
    return {r.routine_id: r.name for r in get_routine_store().list()}


def _build(body: dict, routine_id: str, created_at=None):
    store = get_routine_store()
    try:
        routine = build_routine(body, routine_id=routine_id, now=get_clock().now(),
                                created_at=created_at)
        get_service()  # ThinQ·모의 가전(시스템 가전)은 실행 서비스를 만들 때 등록된다
        validate_against(routine, get_appliance_registry(),
                         known_routine_ids=[r.routine_id for r in store.list()])
    except RoutineValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return routine


def _require(routine_id: str):
    try:
        return get_routine_store().require(routine_id)
    except RoutineNotFoundError as exc:
        raise HTTPException(status_code=404, detail="루틴을 찾을 수 없어요") from exc


@router.get("/routines")
async def list_routines() -> list[dict]:
    names = _names()
    return [_payload(r, names) for r in get_routine_store().list()]


@router.post("/routines", status_code=201)
async def create_routine(body: dict = Body(...)) -> dict:
    store = get_routine_store()
    routine = _build(body, store.new_id())
    store.save(routine)
    return _payload(routine, _names())


@router.get("/routines/next")
async def next_routines(limit: int = Query(3, ge=1, le=10)) -> list[dict]:
    """'다음 실행' 카드 — 켜진 시각 루틴의 가까운 순서."""
    return get_routine_engine().next_runs(limit=limit)


@router.get("/routines/templates")
async def routine_templates() -> list[dict]:
    """추천 템플릿(사용자 데이터 아님, ``is_template: true``). 저장하려면 POST /routines."""
    return template_payloads()


@router.get("/routines/runs")
async def routine_runs() -> list[dict]:
    runner = get_routine_engine().runner
    return [run.as_dict() for run in runner.runs()] if runner is not None else []


@router.get("/routines/runs/{run_id}")
async def routine_run(run_id: str) -> dict:
    runner = get_routine_engine().runner
    run = runner.get(run_id) if runner is not None else None
    if run is None:
        raise HTTPException(status_code=404, detail="루틴 실행 기록을 찾을 수 없어요")
    return run.as_dict()


@router.post("/routines/runs/{run_id}/stop")
async def stop_routine_run(run_id: str) -> dict:
    """남은 단계를 보내지 않는다. 지금 누르는 중이면 긴급 정지도 보낸다."""
    runner = get_routine_engine().runner
    stopped = await asyncio.to_thread(runner.stop, run_id) if runner is not None else False
    if not stopped:
        raise HTTPException(status_code=409, detail="진행 중인 루틴 실행이 아니에요")
    return {"ok": True}


@router.get("/routines/log")
async def routine_trigger_log() -> list[dict]:
    """트리거 기록(카드 만듦·알림·조건 불만족·지금 못 만듦). 최근 50건."""
    return get_routine_engine().recent_log()


@router.get("/routines/{routine_id}")
async def get_routine(routine_id: str) -> dict:
    return _payload(_require(routine_id), _names())


@router.put("/routines/{routine_id}")
async def update_routine(routine_id: str, body: dict = Body(...)) -> dict:
    """전체 교체. 단계·실행 방식이 바뀌면 이미 떠 있는 카드의 승인은 무효(재승인)."""
    current = _require(routine_id)
    routine = _build(body, routine_id, created_at=current.created_at)
    get_routine_store().save(routine)
    return _payload(routine, _names())


@router.delete("/routines/{routine_id}")
async def delete_routine(routine_id: str) -> dict:
    try:
        get_routine_store().delete(routine_id)
    except RoutineNotFoundError as exc:
        raise HTTPException(status_code=404, detail="루틴을 찾을 수 없어요") from exc
    return {"ok": True}


@router.post("/routines/{routine_id}/enable")
async def enable_routine(routine_id: str, body: dict = Body(...)) -> dict:
    enabled = body.get("enabled")
    if not isinstance(enabled, bool):
        raise HTTPException(status_code=422, detail="켜기/끄기 값은 true 또는 false로 보내 주세요")
    from dataclasses import replace  # noqa: PLC0415

    routine = replace(_require(routine_id), enabled=enabled, updated_at=get_clock().now())
    get_routine_store().save(routine)
    return _payload(routine, _names())


@router.post("/routines/{routine_id}/trigger")
async def trigger_routine(routine_id: str) -> dict:
    """'지금 실행' — 승인 루틴은 **카드를 만든다**(실행은 카드 승인 뒤), 알림 루틴은 알림만."""
    engine = get_routine_engine()
    try:
        result = await asyncio.to_thread(engine.trigger_manual, routine_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="루틴을 찾을 수 없어요") from exc
    except RoutineUnavailableError as exc:
        raise HTTPException(status_code=409, detail=f"지금은 루틴 카드를 만들 수 없어요: {exc}") from exc
    if isinstance(result, dict):
        return {"kind": "notice", "notice": result}
    card = suggestion_payload(result)
    card["routine_id"] = result.routine_id
    card["routine_name"] = result.routine_name
    return {"kind": "suggestion", "suggestion": card}
