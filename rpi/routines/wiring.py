"""루틴을 제안 서비스·실행 서비스·ThinQ 이벤트·공간 상태에 붙인다.

제안 서비스가 (다시) 만들어질 때마다 ``wire_routines``가 엔진을 갈아 끼운다 --
``rpi.api.thinq_wiring``의 시나리오 엔진과 같은 방식이다. 실행 서비스의 완료
이벤트·ThinQ 이벤트 구독은 대상마다 한 번만 걸고, 그 시점의 엔진으로 보낸다.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from functools import lru_cache

from .engine import RoutineEngine
from .model import parse_scenario_key
from .runner import RoutineRunner, routine_done_settings_from_env, routine_done_timeouts_from_env
from .store import RoutineStore

log = logging.getLogger(__name__)

#: 시각·다가옴 트리거를 보는 주기(초). 다가옴은 공간 전이 기록을 보므로 놓치지 않는다.
TICK_SECONDS = 5.0

_engine: RoutineEngine | None = None


@lru_cache(maxsize=1)
def get_routine_store() -> RoutineStore:
    from rpi.api.deps import get_db  # noqa: PLC0415

    return RoutineStore(get_db())


def wire_routines(suggestions, service, scenario_engine=None) -> RoutineEngine:
    global _engine
    from rpi.api import deps  # noqa: PLC0415

    store = get_routine_store()
    clock = deps.get_clock()
    care = deps.get_care_events()
    _, done_timeout = routine_done_settings_from_env()
    # 끝 센서 목록은 RPi4 act_info가 오면 그것을 따른다(평가 B3) — 엔진과 러너가 같은 집합을 본다.
    done_sensors = deps.get_done_sensor_set()
    runner = RoutineRunner(
        store, service, clock, care,
        on_finished=lambda run: _engine.on_routine_finished(run) if _engine else None,
        done_log=deps.get_appliance_done_log(), done_sensors=done_sensors,
        done_timeout_seconds=done_timeout, done_timeouts=routine_done_timeouts_from_env(),
    )
    engine = RoutineEngine(
        store, suggestions, service, clock, care_events=care,
        presence_machine=deps.get_presence_state_machine(),
        environment_reader=deps._read_environment,
        runner=runner,
        done_sensors=done_sensors,
        # 시각 규칙(2026-10-16): 정해진 시각에 켜진 '다음부터도 자동으로'가 있으면 카드 대신 자동 실행 경로로.
        auto_rules=get_auto_rule_engine,
    )
    db = deps.get_db()
    if db is not None:  # 재시작해도 같은 시각 회차 카드를 다시 띄우지 않는다(2026-10-16 결함 ①)
        engine.restore_fired(db.load_setting, db.save_setting)
    scenarios = scenario_engine.catalog.current_commands if scenario_engine is not None else None

    def resolve(scenario_id):
        if parse_scenario_key(scenario_id) is not None:
            return engine.current_commands(scenario_id)
        return scenarios(scenario_id) if scenarios is not None else ()

    suggestions.set_scenario_resolver(resolve)
    suggestions.set_routine_namer(engine.habit_routine)
    suggestions.set_plan_runner(runner)

    if not getattr(service, "_simplelay_routine_listener", False):
        service.add_job_listener(lambda event: _engine.on_job_finished(event) if _engine else None)
        service._simplelay_routine_listener = True
    from rpi.api.thinq_wiring import get_thinq_client  # noqa: PLC0415

    client = get_thinq_client()
    subscribe = getattr(client, "subscribe", None)
    if subscribe is not None and not getattr(client, "_simplelay_routine_dispatch", False):
        subscribe(lambda record: _engine.on_thinq_event(record) if _engine else None)
        client._simplelay_routine_dispatch = True
    _engine = engine
    return engine


def halt_routines_if_any(reason: str = "전체 정지 요청") -> int:
    """정지 경로 **맨 앞** — 진행 중인 루틴에 정지 표시만 세운다(메모리, 입출력·로그 없음, 2026-10-16 G3).

    ``POST /stop``의 실행 정지는 RPi4 정지 보고를 기다리느라 수 초 걸릴 수 있다. 루틴 취소가 그 뒤에 오면 그 사이 루틴이
    다음 구간을 보낸다. 엔진이 없으면 아무것도 만들지 않는다. 로그는 뒤이은 `stop_routines_if_any`가 남긴다."""
    engine = _engine
    runner = getattr(engine, "runner", None) if engine is not None else None
    if runner is None:
        return 0
    return runner.halt_all(reason)


def stop_routines_if_any(reason: str = "전체 정지 요청") -> int:
    """``POST /stop``·비상정지 — 이미 만들어진 루틴 러너가 있으면 진행 중인 루틴을 모두 멈춘다(평가 B5).
    엔진이 아직 없으면 아무것도 만들지 않는다(정지 경로에서 새 객체를 띄우지 않는다)."""
    engine = _engine
    runner = getattr(engine, "runner", None) if engine is not None else None
    if runner is None:
        return 0
    return runner.stop_all(reason)


# ── 자동 실행 허용 규칙(2026-10-13, v4) ─────────────────────────────────────

_auto_engine = None
_auto_lock = threading.Lock()
AUTO_RULES_SETTING = "auto_rules"
AUTO_SEEN_SETTING = "auto_rule_seen_events"
#: 규칙 저장 세션 표시(4차 평가 M-N3) — 열린 채 다른 프로세스면 지난 종료가 깨끗하지 않았다.
AUTO_RULES_SESSION_SETTING = "auto_rules_session"


def get_auto_rule_engine():
    """자동 실행 허용 규칙 엔진. 실행 서비스가 다시 만들어지면(시험) 새로 만든다. DB가 있으면 규칙·처리한 사건이 남는다."""
    global _auto_engine
    from rpi.api import deps  # noqa: PLC0415
    from rpi.api.thinq_wiring import get_scenario_engine  # noqa: PLC0415

    from .auto_rules import AutoRuleEngine, AutoRuleStore, SeenEvents, max_event_age_from_env  # noqa: PLC0415

    service = deps.get_service()
    with _auto_lock:
        engine = _auto_engine
        if engine is not None and engine.service is service:
            return engine
        db = deps.get_db()
        clock = deps.get_clock()
        # 4차 평가 M-N3: 세션 표시 — 지난 프로세스가 깨끗이 닫히지 않았으면 켜진 규칙을 끈 채 시작한다.
        store = AutoRuleStore(load=(lambda: db.load_setting(AUTO_RULES_SETTING)) if db else None,
                              save=(lambda v: db.save_setting(AUTO_RULES_SETTING, v)) if db else None,
                              session_load=(lambda: db.load_setting(AUTO_RULES_SESSION_SETTING)) if db else None,
                              session_save=(lambda v: db.save_setting(AUTO_RULES_SESSION_SETTING, v)) if db else None,
                              now=lambda: clock.now().isoformat())
        seen = SeenEvents(load=(lambda: db.load_setting(AUTO_SEEN_SETTING)) if db else None,
                          save=(lambda v: db.save_setting(AUTO_SEEN_SETTING, v)) if db else None)
        engine = AutoRuleEngine(store, seen, service, deps.get_clock(), scenarios=get_scenario_engine,
                                care_events=deps.get_care_events(),
                                max_event_age_s=max_event_age_from_env(),
                                is_quiet=lambda: deps.get_suggestion_service().is_auto_run_quiet(),  # 이어받은 옛 범위 잠시 쉬기는 막지 않음
                                routines=get_routine_store,
                                quiet_settings=lambda: deps.get_quiet_hours().settings())
        _auto_engine = engine
    if not getattr(service, "_simplelay_auto_rule_listener", False):
        service.add_job_listener(lambda event: _auto_engine.on_job_finished(event)
                                 if _auto_engine is not None and _auto_engine.service is service else None)
        service._simplelay_auto_rule_listener = True
    return engine


def last_auto_run_if_any() -> dict | None:
    """마지막 자동 실행 결과(키오스크 알림용). 규칙 엔진을 만들지 않는다 — 아직 없으면 None."""
    engine = _auto_engine
    if engine is None:
        return None
    try:
        return engine.last_result_payload()
    except Exception:  # noqa: BLE001 -- 상태 조회를 막지 않는다
        log.exception("last auto run payload failed")
        return None


def halt_auto_rules_if_any() -> None:
    """정지 경로 맨 앞 — 아직 보내지 않은 자동 실행을 막는다(세대만 올림, 입출력 없음)."""
    engine = _auto_engine
    if engine is not None:
        engine.halt()


def stop_auto_rules_if_any(reason: str = "비상정지") -> int:
    """비상정지 — 이미 만든 자동 실행 엔진이 있으면 세대를 올리고 켜진 규칙을 끈다. 없으면 만들지 않는다."""
    engine = _auto_engine
    if engine is None:
        return 0
    return engine.emergency_stop(reason)


def close_auto_rules_if_any(timeout_s: float = 5.0) -> bool:
    """서버 종료 — 이미 만든 규칙 엔진이 있으면 남은 규칙 쓰기를 마치고 세션 표시를 닫는다(4차 평가 M-N3). 없으면 True."""
    engine = _auto_engine
    if engine is None:
        return True
    try:
        return engine.close(timeout_s)
    except Exception:  # noqa: BLE001 -- 종료 절차를 막지 않는다(표시는 열린 채 → 다음 기동이 켜진 규칙을 끈다)
        log.exception("auto rule close failed")
        return False


# ── 사용 기록 → 루틴 초안(2026-10-14, 4번) ────────────────────────────────────


@lru_cache(maxsize=1)
def get_candidate_decisions():
    """초안별 판단(저장·거절). DB가 있으면 재시작 뒤에도 남는다."""
    from rpi.api import deps  # noqa: PLC0415

    from .candidates import DECISIONS_SETTING, CandidateDecisions  # noqa: PLC0415

    db = deps.get_db()
    return CandidateDecisions(load=(lambda: db.load_setting(DECISIONS_SETTING)) if db else None,
                              save=(lambda v: db.save_setting(DECISIONS_SETTING, v)) if db else None)


@lru_cache(maxsize=1)
def get_candidate_issued():
    """쉬지 않을 때 한 번 내놓은 초안(쉬는 동안 '기존 초안'으로 보이는 것). DB가 있으면 재시작 뒤에도 남는다."""
    from rpi.api import deps  # noqa: PLC0415

    from .candidates import ISSUED_SETTING, CandidateDecisions  # noqa: PLC0415

    db = deps.get_db()
    return CandidateDecisions(load=(lambda: db.load_setting(ISSUED_SETTING)) if db else None,
                              save=(lambda v: db.save_setting(ISSUED_SETTING, v)) if db else None)


def get_routine_candidates():
    """요청마다 지금의 서비스·기록·제안 쉬기 상태로 만든다(판단만 위에서 공유)."""
    from rpi.api import deps  # noqa: PLC0415
    from rpi.intent.patterns import PatternDetector  # noqa: PLC0415
    from rpi.intent.suggestions import ProactiveSuggestionService  # noqa: PLC0415

    from .candidates import RoutineCandidates  # noqa: PLC0415

    suggestions = deps.get_suggestion_service()
    service = deps.get_service()
    clock = deps.get_clock()
    muted = suggestions.muted_purposes
    return RoutineCandidates(
        detector=PatternDetector(deps.get_usage_log(), clock, deps._PATTERN_CONFIG),
        revision_options=service.revision_options,
        registry=deps.get_appliance_registry(),
        store=get_routine_store(),
        decisions=get_candidate_decisions(),
        clock=clock,
        is_quiet=suggestions.is_quiet,  # 잠시 쉬기·매일 조용한 시간 같게(새 초안만 쉼)
        issued=get_candidate_issued(),
        is_muted=lambda purpose: ProactiveSuggestionService._is_muted(purpose, muted()),
    )


def get_routine_engine() -> RoutineEngine:
    from rpi.api.deps import get_suggestion_service  # noqa: PLC0415

    get_suggestion_service()
    assert _engine is not None
    return _engine


def reset_routines() -> None:
    """테스트용."""
    global _engine, _auto_engine
    _auto_engine = None
    get_routine_store.cache_clear()
    get_candidate_decisions.cache_clear()
    get_candidate_issued.cache_clear()
    from rpi.api import deps  # noqa: PLC0415

    deps.get_quiet_hours.cache_clear()
    deps.get_done_sensor_set.cache_clear()
    _engine = None


async def routine_tick_loop(interval: float = TICK_SECONDS) -> None:
    """main.py lifespan이 띄운다. 트리거 실패가 서버를 죽이지 않는다."""
    while True:
        try:
            await asyncio.to_thread(lambda: get_routine_engine().tick())
        except Exception:  # noqa: BLE001
            log.exception("routine tick failed")
        await asyncio.sleep(interval)
