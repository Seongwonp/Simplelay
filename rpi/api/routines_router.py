"""사용자 루틴 API (2026-09-30) — 계약은 docs/devlog/devlog_2026-09-30-routines.md.

저장·수정·켜기/끄기·다음 실행·템플릿·'지금 실행'(카드 만들기)·실행 기록. 이 모듈에는
**실행 진입점이 없다.** 실행은 ``POST /suggestions/{id}/approve``로만 일어난다.
검증 오류는 422이며 detail은 화면에 그대로 보여도 되는 한국어 문장이다.
"""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, Body, HTTPException, Query, Request

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

# 루틴 저장소를 읽고 쓰는 라우터는 ``def``(스레드풀) — 저장소 잠금이 DB 쓰기 동안 잡혀 있어 이벤트 루프에서 기다리면
# ``/stop``까지 멈춘다(2026-10-14 HIGH 재확인 H-R2).
log = logging.getLogger(__name__)

router = APIRouter()


def _payload(routine, names=None) -> dict:
    data = routine.to_dict()
    data["when"] = routine.trigger.describe(names)
    data["mode_label"] = MODE_LABELS[routine.mode]
    return data


async def _routine_engine():
    """async 라우터용 루틴 엔진. 제안 서비스가 아직 없으면(재시작 직후 첫 요청) 그 최초 생성(DB 읽기)은 이벤트 루프 밖에서 —
    루프에서 만들면 그동안 같은 서버의 ``/stop``이 들어오지 못했다(외부 재확인 3차). 이미 있으면 메모리 읽기뿐."""
    from .deps import build_off_loop, get_suggestion_service  # noqa: PLC0415

    await build_off_loop(get_suggestion_service)
    return get_routine_engine()


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
def list_routines() -> list[dict]:
    names = _names()
    return [_payload(r, names) for r in get_routine_store().list()]


@router.post("/routines", status_code=201)
def create_routine(body: dict = Body(...)) -> dict:
    store = get_routine_store()
    routine = _build(body, store.new_id())
    store.save(routine)
    return _payload(routine, _names())


@router.get("/routines/next")
def next_routines(limit: int = Query(3, ge=1, le=10)) -> list[dict]:
    """'다음 실행' 카드 — 켜진 시각 루틴의 가까운 순서.

    조용한 시간이 켜져 있고 그 회차가 시간대 안이면(시작 포함·끝 제외 — 실행 판정과 같다) ``quiet_skip``과
    표시 말 '조용한 시간이라 건너뛰었어요'를 붙인다(UI 평가 8차 10/17: 규칙 카드는 '건너뛰어요'인데 이 카드는 '실행'이라 했다).
    폰·키오스크는 ``mode_label``을 그대로 보인다.

    한 번 건너뛰기(2026-10-18): 항목마다 ``skipped``·``skip_label``·``skip_action_label`` — ``POST /routines/next/skip``.
    건너뛴 항목에는 선택 필드 ``next_after_skip_at``·``next_after_skip_day_label``(그다음 회차, 2026-10-24)을 더한다 —
    그 회차도 조용한 시간이면 붙이지 않는다."""
    return _with_quiet(get_routine_engine().next_runs(limit=limit))


def _with_quiet(items: list[dict]) -> list[dict]:
    from datetime import datetime  # noqa: PLC0415

    from rpi.services.quiet_hours import window_contains  # noqa: PLC0415

    from .deps import get_quiet_hours  # noqa: PLC0415

    try:
        quiet = get_quiet_hours().settings()
    except Exception:  # noqa: BLE001 — 표시용이다. 모르면 붙이지 않는다
        return items
    if not quiet.get("enabled"):
        return items
    for item in items:
        try:
            at = datetime.fromisoformat(item["at"])
        except (KeyError, TypeError, ValueError):
            continue
        if window_contains(quiet["start"], quiet["end"], at):
            item["quiet_skip"] = True
            item["mode_label"] = "조용한 시간이라 건너뛰었어요"
        # 건너뛴 회차 다음 회차도 조용한 시간이면 그때도 하지 않는다 — '다음은 …'이라고 말하지 않게 뺀다.
        try:
            after = datetime.fromisoformat(item["next_after_skip_at"])
        except (KeyError, TypeError, ValueError):
            continue
        if window_contains(quiet["start"], quiet["end"], after):
            item.pop("next_after_skip_at", None)
            item.pop("next_after_skip_day_label", None)
    return items


def _set_skip(body: dict, skip: bool) -> dict:
    from rpi.routines.engine import RoutineSkipError  # noqa: PLC0415

    routine_id = body.get("routine_id")
    if not isinstance(routine_id, str) or not routine_id:
        raise HTTPException(status_code=422, detail="어느 루틴인지 routine_id를 보내 주세요")
    try:
        item = get_routine_engine().set_skip(routine_id, body.get("at"), skip)
    except RoutineSkipError as exc:
        raise HTTPException(status_code=exc.status, detail=exc.message) from exc
    return _with_quiet([item])[0]


@router.post("/routines/next/skip")
def skip_next_routine(body: dict = Body(...)) -> dict:
    """'오늘은 건너뛰기' — ``{"routine_id", "at"}``(``/routines/next`` 항목 그대로)의 **그 회차 한 번만** 하지 않는다.
    카드도 자동 실행도 없이 기록만 남고 다음 회차부터는 원래대로. 지난 회차·이미 시작한 회차·다음 회차와 다른 시각은 409
    (건너뛰기는 실행을 멈추지 않는다 — 정지는 ``/stop``). 응답은 바뀐 ``/routines/next`` 항목. 재시작해도 남는다."""
    return _set_skip(body, True)


@router.post("/routines/next/unskip")
def unskip_next_routine(body: dict = Body(...)) -> dict:
    """건너뛰기 되돌리기 — 본문·거절은 ``/routines/next/skip``과 같다. 건너뛰지 않았어도 200(같은 결과)."""
    return _set_skip(body, False)


@router.get("/routines/templates")
async def routine_templates() -> list[dict]:
    """추천 템플릿(사용자 데이터 아님, ``is_template: true``). 저장하려면 POST /routines."""
    return template_payloads()


# ── 사용 기록 → 루틴 초안(2026-10-14, 4번) — 저장만 한다(실행·카드·자동 실행 허용 없음) ──


def _candidate_error(exc) -> HTTPException:
    return HTTPException(status_code=exc.status, detail=exc.message)


@router.get("/routines/candidates")
async def routine_candidates() -> list[dict]:
    """가전 사용 기록으로 만든 루틴 초안(가전·버튼 순서가 채워짐). 제안을 쉬는 동안은 빈 목록."""
    from rpi.routines.wiring import get_routine_candidates  # noqa: PLC0415

    return await asyncio.to_thread(lambda: get_routine_candidates().list())


@router.post("/routines/candidates/{key}/save", status_code=201)
async def save_routine_candidate(key: str, body: dict = Body(...)) -> dict:
    """``{"name": ..., "run": "manual" | "ask_at_time"}`` — 승인 루틴으로 **저장만** 한다."""
    from rpi.routines.candidates import SAVE_NOTICE, CandidateError  # noqa: PLC0415
    from rpi.routines.wiring import get_routine_candidates  # noqa: PLC0415

    try:
        routine = await asyncio.to_thread(lambda: get_routine_candidates().save(key, body))
    except CandidateError as exc:
        raise _candidate_error(exc) from exc
    return {"routine": _payload(routine, _names()), "executed": False, "notice": SAVE_NOTICE}


@router.post("/routines/candidates/{key}/decline")
async def decline_routine_candidate(key: str) -> dict:
    """'괜찮아요' — 저장하지 않고 일정 기간(14일) 이 초안을 다시 보이지 않는다."""
    from rpi.routines.candidates import CandidateError  # noqa: PLC0415
    from rpi.routines.wiring import get_routine_candidates  # noqa: PLC0415

    try:
        until = await asyncio.to_thread(lambda: get_routine_candidates().decline(key))
    except CandidateError as exc:
        raise _candidate_error(exc) from exc
    return {"ok": True, "quiet_until": until.isoformat()}


@router.get("/routines/runs")
async def routine_runs() -> list[dict]:
    runner = (await _routine_engine()).runner
    return [run.as_dict() for run in runner.runs()] if runner is not None else []


@router.get("/routines/runs/{run_id}")
async def routine_run(run_id: str) -> dict:
    runner = (await _routine_engine()).runner
    run = runner.get(run_id) if runner is not None else None
    if run is None:
        raise HTTPException(status_code=404, detail="루틴 실행 기록을 찾을 수 없어요")
    return run.as_dict()


@router.post("/routines/runs/{run_id}/stop")
async def stop_routine_run(run_id: str) -> dict:
    """남은 단계를 보내지 않는다. 지금 누르는 중이면 긴급 정지도 보낸다."""
    runner = (await _routine_engine()).runner
    stopped = await asyncio.to_thread(runner.stop, run_id) if runner is not None else False
    if not stopped:
        raise HTTPException(status_code=409, detail="진행 중인 루틴 실행이 아니에요")
    return {"ok": True}


@router.get("/routines/log")
async def routine_trigger_log() -> list[dict]:
    """트리거 기록(카드 만듦·알림·조건 불만족·지금 못 만듦). 최근 50건."""
    return (await _routine_engine()).recent_log()


# ── 자동 실행 허용 규칙(2026-10-13, 시연 v4) ─────────────────────────────────
# 규칙은 제안 카드에서만 생긴다(빈 폼 없음). 목록에서는 끄기·켜기(다시 허용)·설정값 바꾸기·삭제만.


def _auto_error(exc) -> HTTPException:
    return HTTPException(status_code=exc.status, detail=exc.message)


@router.get("/routines/auto-rules")
async def list_auto_rules() -> list[dict]:
    from rpi.routines.wiring import get_auto_rule_engine  # noqa: PLC0415

    engine = await asyncio.to_thread(get_auto_rule_engine)
    return await asyncio.to_thread(engine.list_payloads)


@router.get("/routines/auto-rules/runs")
async def auto_rule_runs() -> list[dict]:
    """자동 실행 기록(최근 50건, 최신 먼저) — 보냄·막힘(이유)·중복·비상정지와 장치별 결과 문장."""
    from rpi.routines.wiring import get_auto_rule_engine  # noqa: PLC0415

    return (await asyncio.to_thread(get_auto_rule_engine)).recent_runs()


@router.put("/routines/auto-rules/{rule_id}")
async def update_auto_rule(rule_id: str, body: dict = Body(...)) -> dict:
    """설정값만 바꾼다. 바꾸면 자동 실행이 꺼지고 다시 허용(확인 화면)해야 켜진다."""
    from rpi.routines.auto_rules import AutoRuleError  # noqa: PLC0415
    from rpi.routines.wiring import get_auto_rule_engine  # noqa: PLC0415

    engine = await asyncio.to_thread(get_auto_rule_engine)
    report: dict = {}
    try:
        rule = await asyncio.to_thread(engine.update, rule_id, body, report)
    except AutoRuleError as exc:
        raise _auto_error(exc) from exc
    return {**engine.payload(rule), "in_flight_notice": report.get("in_flight_notice")}


@router.post("/routines/auto-rules/{rule_id}/enable")
async def enable_auto_rule(rule_id: str, body: dict = Body(...)) -> dict:
    """끄기 ``{"enabled": false}`` · 다시 허용 ``{"enabled": true, "fingerprint": <목록의 fingerprint>}``."""
    from rpi.routines.auto_rules import AutoRuleError  # noqa: PLC0415
    from rpi.routines.wiring import get_auto_rule_engine  # noqa: PLC0415

    enabled = body.get("enabled")
    if not isinstance(enabled, bool):
        raise HTTPException(status_code=422, detail="켜기/끄기 값은 true 또는 false로 보내 주세요")
    engine = await asyncio.to_thread(get_auto_rule_engine)
    # 3차 평가 H2: 요청을 시작할 때의 정지 세대 — 처리하는 사이 전체 정지가 끝났으면 늦은 저장이 규칙을 다시 켜지 않는다.
    start_generation = engine.generation()
    # 4차 평가 H-N1: 끄기가 이미 전송을 시작한 자동 실행과 겹쳤으면 그 명령은 취소되지 않는다고 함께 알린다.
    report: dict = {}
    try:
        rule = await asyncio.to_thread(engine.set_enabled, rule_id, enabled, body.get("fingerprint"),
                                       start_generation, report)
    except AutoRuleError as exc:
        raise _auto_error(exc) from exc
    return {**engine.payload(rule), "in_flight_notice": report.get("in_flight_notice")}


@router.delete("/routines/auto-rules/{rule_id}")
async def delete_auto_rule(rule_id: str) -> dict:
    from rpi.routines.auto_rules import AutoRuleError  # noqa: PLC0415
    from rpi.routines.wiring import get_auto_rule_engine  # noqa: PLC0415

    engine = await asyncio.to_thread(get_auto_rule_engine)
    report: dict = {}
    try:
        await asyncio.to_thread(engine.delete, rule_id, report)
    except AutoRuleError as exc:
        raise _auto_error(exc) from exc
    return {"ok": True, "in_flight_notice": report.get("in_flight_notice")}


@router.post("/suggestions/{suggestion_id}/approve-and-allow")
async def approve_and_allow(suggestion_id: str, request: Request, body: dict = Body(...)) -> dict:
    """'이번에 실행하고 다음부터 자동으로' — 카드의 허용 내용(``auto_rule_offer.fingerprint``)을 확인한 뒤
    이번 실행은 종전 승인 경로로 제출하고, 같은 내용을 자동 실행 규칙으로 저장한다.

    물리 누름이 있는 카드는 422(자동 실행 불가), 허용 내용이 화면과 다르면 409(저장·실행 둘 다 안 함).

    3차 평가 H2: 요청을 시작할 때의 정지 세대를 저장 단계까지 넘긴다. 이번 실행을 제출한 뒤 전체 정지가 끼면 규칙은
    켜지지 않고, 응답은 이번 실행(``job_id``)과 자동 허용 결과(``auto_allow: {ok: false, reason}``)를 나눠 돌려준다.

    재요청 영수증(검토 10/19): 본문에 선택 ``client_request_id``(``[A-Za-z0-9_-]{1,64}``, 실행 요청과 같은 규칙)를 받는다.
    같은 번호의 재요청은 대기 중 제안 확인보다 먼저 영수증을 보고 **같은 묶음 응답**(job_id·rule·auto_allow)을 돌려준다
    (다시 실행·저장하지 않음, ``GET /jobs/by-request/{id}``로도 실행 번호를 찾을 수 있다). 번호 없이 다시 보냈는데 이 카드의
    실행이 이미 접수돼 있으면 같은 ``job_id``와 저장된 자동 허용 결과, 그 규칙의 **지금 상태**를 돌려준다."""
    from rpi.routines.wiring import get_auto_rule_engine  # noqa: PLC0415

    from .deps import build_off_loop, get_suggestion_service  # noqa: PLC0415
    from .job_receipts import (  # noqa: PLC0415
        CLIENT_REQUEST_ID_PATTERN,
        AdmissionPendingError,
        approve_allow_receipts_of,
        ledger_of,
        valid_client_request_id,
    )

    client_request_id = body.get("client_request_id")
    if client_request_id is not None and not (isinstance(client_request_id, str)
                                              and valid_client_request_id(client_request_id)):
        raise HTTPException(status_code=422, detail="client_request_id must match " + CLIENT_REQUEST_ID_PATTERN)
    await build_off_loop(get_suggestion_service)  # 최초 생성은 루프 밖에서(외부 재확인 3차)
    svc = get_suggestion_service()
    engine = await asyncio.to_thread(get_auto_rule_engine)
    start_generation = engine.generation()
    receipts = approve_allow_receipts_of(request.app)
    jobs = ledger_of(request.app)
    try:
        result = await asyncio.to_thread(receipts.requests.admit, client_request_id, _approve_and_allow_once,
                                         svc, engine, receipts, suggestion_id, body, start_generation)
    except AdmissionPendingError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if client_request_id is not None:
        job_id = result["job_id"]
        await asyncio.to_thread(jobs.admit, client_request_id, lambda: job_id)  # 실행 번호 조회에도 남긴다
    return result


@router.post("/suggestions/{suggestion_id}/approve-and-adopt")
async def approve_and_adopt(suggestion_id: str, body: dict = Body(...)) -> dict:
    """습관 카드에서 '이번에 하고, 매일 이 시간에'(2026-10-25 — 묻기에서 맡기기로 가는 다리).

    본문 ``candidate_key``는 카드의 ``adopt_offer.candidate_key`` 그대로 — 지금 초안과 다르면 409(실행·저장 둘 다 안 함).
    이번 실행은 종전 승인 경로로 제출하고, 초안을 '매일 그 시각에 물어보기' 루틴으로 저장한다. 낮은 위험 LG 가전 동작이면
    그 루틴을 자동 실행으로 맡긴다(시각 규칙 — 조용한 시간·비상정지·지문 검사는 종전 그대로). 물리 누름은 묻기까지만.
    응답은 실행(``job_id``)과 저장(``adopt``)·맡기기(``auto_allow``) 결과를 나눠 돌려준다 — 실행은 됐는데 저장이 안 될 수 있다."""
    from rpi.intent.rules import UnknownIntentError  # noqa: PLC0415
    from rpi.intent.suggestions import UnknownSuggestionError  # noqa: PLC0415
    from rpi.routines.auto_rules import AutoRuleError  # noqa: PLC0415
    from rpi.routines.candidates import CandidateError  # noqa: PLC0415
    from rpi.routines.wiring import get_auto_rule_engine, get_routine_candidates  # noqa: PLC0415

    from .deps import build_off_loop, get_suggestion_service  # noqa: PLC0415

    await build_off_loop(get_suggestion_service)
    svc = get_suggestion_service()
    engine = await asyncio.to_thread(get_auto_rule_engine)
    start_generation = engine.generation()

    def once() -> dict:
        suggestion = next((s for s in svc.pending() if s.suggestion_id == suggestion_id), None)
        if suggestion is None:
            raise HTTPException(status_code=404, detail="suggestion not found")
        candidates = get_routine_candidates()
        draft = candidates.for_habit(suggestion.purpose, suggestion.appliance_id)
        if draft is None or body.get("candidate_key") != draft["key"]:
            raise HTTPException(status_code=409, detail="저장할 내용이 바뀌었어요 — 다시 확인하고 눌러 주세요")
        try:
            job_id = svc.approve_submit(suggestion_id)
        except UnknownSuggestionError as exc:
            raise HTTPException(status_code=404, detail="suggestion not found") from exc
        except UnknownIntentError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except RuntimeError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        try:
            routine = candidates.save(draft["key"], {"run": "ask_at_time", "name": draft.get("suggested_name")})
        except CandidateError as exc:
            return {"job_id": job_id, "routine_id": None, "adopt": {"ok": False, "reason": exc.message},
                    "auto_allow": None}
        result = {"job_id": job_id, "routine_id": routine.routine_id, "adopt": {"ok": True, "reason": None},
                  "auto_allow": None}
        if adopt_auto(draft):
            offer = engine.routine_offer(routine)
            if offer is None:
                result["auto_allow"] = {"ok": False, "reason": "이 동작은 자동으로 맡길 수 없어요 — 매일 물어볼게요"}
            else:
                try:
                    engine.allow_from_offer(offer, start_generation)
                    result["auto_allow"] = {"ok": True, "reason": None}
                except AutoRuleError as exc:
                    result["auto_allow"] = {"ok": False, "reason": exc.message}
        return result

    return await asyncio.to_thread(once)


def adopt_auto(draft: dict) -> bool:
    steps = draft.get("steps") or []
    return bool(steps) and steps[0].get("kind") == "thinq_command"


def _rule_by_key(engine, rule_key: tuple):
    scenario_id, target_appliance_id, action = rule_key
    return next((r for r in engine.store.list() if r.scenario_id == scenario_id
                 and r.target_appliance_id == target_appliance_id and r.action == action), None)


#: 이 카드의 실행은 접수했지만 자동 허용 결과를 모를 때(그냥 승인으로 실행했거나 결과를 남기기 전에 실패).
ALLOW_RESULT_UNKNOWN = "이번 실행은 이미 접수되었어요. 자동 실행은 켜지지 않았을 수 있어요 — 자동 실행 목록에서 확인해 주세요"


def _approve_and_allow_once(svc, engine, receipts, suggestion_id: str, body: dict, start_generation) -> dict:
    """approve-and-allow 한 번(루프 밖 스레드). 같은 요청 번호로는 한 번만 불린다(영수증 장부)."""
    from rpi.commands import ControlRoute  # noqa: PLC0415
    from rpi.intent.rules import UnknownIntentError  # noqa: PLC0415
    from rpi.intent.suggestions import UnknownSuggestionError  # noqa: PLC0415
    from rpi.routines.auto_rules import PHYSICAL_REFUSED, AutoRuleError  # noqa: PLC0415

    suggestion = next((s for s in svc.pending() if s.suggestion_id == suggestion_id), None)
    if suggestion is None:
        # 이미 승인돼 대기 목록에서 빠진 카드 — 접수한 실행이 있으면 응답 유실 뒤 재요청으로 보고 같은 결과를 돌려준다.
        job_id = svc.accepted_job(suggestion_id)
        if job_id is None:
            raise HTTPException(status_code=404, detail="suggestion not found")
        stored = receipts.for_suggestion(suggestion_id)
        if stored is None or stored["job_id"] != job_id:
            return {"job_id": job_id, "rule": None, "auto_allow": {"ok": False, "reason": ALLOW_RESULT_UNKNOWN}}
        current = _rule_by_key(engine, stored["rule_key"])
        return {"job_id": job_id, "rule": engine.payload(current) if current is not None else None,
                "auto_allow": stored["auto_allow"]}
    draft = engine.offer_for(suggestion)
    if draft is None:
        physical = not suggestion.commands or any(c.route is ControlRoute.PHYSICAL for c in suggestion.commands)
        raise HTTPException(status_code=422, detail=PHYSICAL_REFUSED if physical
                            else "이 제안은 다음부터 자동으로 정할 수 없어요 — 이번만 실행해 주세요")
    if body.get("offer_fingerprint") != draft.fingerprint():
        raise HTTPException(status_code=409, detail="허용할 내용이 바뀌었어요 — 다시 확인하고 승인해 주세요")
    try:
        job_id = svc.approve_submit(suggestion_id)
    except UnknownSuggestionError as exc:
        raise HTTPException(status_code=404, detail="suggestion not found") from exc
    except UnknownIntentError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    rule_key = (draft.scenario_id, draft.target_appliance_id, draft.action)
    try:
        rule = engine.allow_from_offer(draft, start_generation)
    except AutoRuleError as exc:
        # 이번 실행은 이미 제출했다(결과는 job으로) — 자동 허용만 실패. 규칙은 켜지지 않았다.
        current = _rule_by_key(engine, rule_key)
        auto_allow = {"ok": False, "reason": exc.message}
        receipts.remember(suggestion_id, job_id=job_id, rule_key=rule_key, auto_allow=auto_allow)
        return {"job_id": job_id, "rule": engine.payload(current) if current is not None else None,
                "auto_allow": auto_allow}
    auto_allow = {"ok": True, "reason": None}
    receipts.remember(suggestion_id, job_id=job_id, rule_key=rule_key, auto_allow=auto_allow)
    return {"job_id": job_id, "rule": engine.payload(rule), "auto_allow": auto_allow}


@router.get("/routines/{routine_id}")
def get_routine(routine_id: str) -> dict:
    return _payload(_require(routine_id), _names())


#: 읽은 뒤 다른 요청이 같은 루틴을 바꿨을 때(HIGH 재확인 2차 M-RR1) — 화면에 그대로 보여도 되는 문장.
ROUTINE_CHANGED_DETAIL = "다른 곳에서 이 루틴이 바뀌었어요 — 목록을 새로 고친 뒤 다시 저장해 주세요"


@router.put("/routines/{routine_id}")
def update_routine(routine_id: str, body: dict = Body(...)) -> dict:
    """전체 교체. 단계·실행 방식이 바뀌면 이미 떠 있는 카드의 승인은 무효(재승인).

    HIGH 재확인 2차 M-RR1: 읽은 루틴이 저장 순간에도 그대로일 때만 교체한다(저장소의 한 연산). 그 사이 지워졌으면 404
    (되살리지 않음), 다른 요청이 바꿨으면 409(끝난 변경을 옛 판으로 덮지 않음)."""
    from rpi.routines.store import RoutineConflictError  # noqa: PLC0415

    current = _require(routine_id)
    routine = _build(body, routine_id, created_at=current.created_at)
    try:
        get_routine_store().replace(routine, expected=current)
    except RoutineNotFoundError as exc:
        raise HTTPException(status_code=404, detail="루틴을 찾을 수 없어요") from exc
    except RoutineConflictError as exc:
        raise HTTPException(status_code=409, detail=ROUTINE_CHANGED_DETAIL) from exc
    if _definition(current) != _definition(routine):
        _revoke_time_rules(routine_id)
    return _payload(routine, _names())


def _definition(routine) -> tuple:
    """시각 규칙이 묶이는 루틴 내용 — 이름·아이콘만 바뀌면 허용을 그대로 둔다."""
    return (routine.steps, routine.trigger, routine.conditions, routine.mode, routine.enabled)


def _revoke_time_rules(routine_id: str, deleted: bool = False) -> None:
    """루틴을 바꾸거나 지웠다 — 그 루틴의 '다음부터도 자동으로'(시각 규칙)를 끈다(2026-10-16). 실패는 기록만 — 남은
    규칙은 실행 직전 재검사(루틴과 다르면 꺼짐)에 걸린다."""
    from rpi.routines.auto_rules import ROUTINE_CHANGED_REASON, ROUTINE_DELETED_REASON  # noqa: PLC0415
    from rpi.routines.wiring import get_auto_rule_engine  # noqa: PLC0415

    try:
        get_auto_rule_engine().revoke_for_routine(
            routine_id, ROUTINE_DELETED_REASON if deleted else ROUTINE_CHANGED_REASON)
    except Exception:  # noqa: BLE001
        log.exception("revoking time auto rules for routine %s failed", routine_id)


@router.delete("/routines/{routine_id}")
def delete_routine(routine_id: str) -> dict:
    try:
        get_routine_store().delete(routine_id)
    except RoutineNotFoundError as exc:
        raise HTTPException(status_code=404, detail="루틴을 찾을 수 없어요") from exc
    _revoke_time_rules(routine_id, deleted=True)
    return {"ok": True}


@router.post("/routines/{routine_id}/enable")
def enable_routine(routine_id: str, body: dict = Body(...)) -> dict:
    enabled = body.get("enabled")
    if not isinstance(enabled, bool):
        raise HTTPException(status_code=422, detail="켜기/끄기 값은 true 또는 false로 보내 주세요")
    from dataclasses import replace  # noqa: PLC0415

    # HIGH 재확인 2차 M-RR1: 최신 루틴의 enabled만 바꾼다 — 읽기·바꾸기·저장이 저장소의 한 연산이라, 그 사이 끝난 편집을
    # 옛 객체로 되돌리지 않고, 지워졌으면 404(되살리지 않음).
    now = get_clock().now()
    try:
        routine = get_routine_store().update(routine_id, lambda r: replace(r, enabled=enabled, updated_at=now))
    except RoutineNotFoundError as exc:
        raise HTTPException(status_code=404, detail="루틴을 찾을 수 없어요") from exc
    return _payload(routine, _names())


@router.post("/routines/{routine_id}/trigger")
async def trigger_routine(routine_id: str) -> dict:
    """'지금 실행' — 승인 루틴은 **카드를 만든다**(실행은 카드 승인 뒤), 알림 루틴은 알림만."""
    engine = await _routine_engine()
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
