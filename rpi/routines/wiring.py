"""루틴을 제안 서비스·실행 서비스·ThinQ 이벤트·공간 상태에 붙인다.

제안 서비스가 (다시) 만들어질 때마다 ``wire_routines``가 엔진을 갈아 끼운다 --
``rpi.api.thinq_wiring``의 시나리오 엔진과 같은 방식이다. 실행 서비스의 완료
이벤트·ThinQ 이벤트 구독은 대상마다 한 번만 걸고, 그 시점의 엔진으로 보낸다.
"""

from __future__ import annotations

import asyncio
import logging
from functools import lru_cache

from .engine import RoutineEngine
from .model import parse_scenario_key
from .runner import RoutineRunner
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
    runner = RoutineRunner(
        store, service, clock, care,
        on_finished=lambda run: _engine.on_routine_finished(run) if _engine else None,
    )
    engine = RoutineEngine(
        store, suggestions, service, clock, care_events=care,
        presence_machine=deps.get_presence_state_machine(),
        environment_reader=deps._read_environment,
        runner=runner,
    )
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


def get_routine_engine() -> RoutineEngine:
    from rpi.api.deps import get_suggestion_service  # noqa: PLC0415

    get_suggestion_service()
    assert _engine is not None
    return _engine


def reset_routines() -> None:
    """테스트용."""
    global _engine
    get_routine_store.cache_clear()
    _engine = None


async def routine_tick_loop(interval: float = TICK_SECONDS) -> None:
    """main.py lifespan이 띄운다. 트리거 실패가 서버를 죽이지 않는다."""
    while True:
        try:
            await asyncio.to_thread(lambda: get_routine_engine().tick())
        except Exception:  # noqa: BLE001
            log.exception("routine tick failed")
        await asyncio.sleep(interval)
