"""정지 전용 실행 줄(2026-10-14 HIGH 재확인 2차 H-RR1).

정지(``POST /stop`` — 폰·키오스크, ``POST /dev/stop`` — 개발자)는 일반 요청과 같은 스레드 풀을 쓰지 않는다:

- FastAPI는 ``def`` 의존성·라우터를 **AnyIO 기본 토큰**(프로세스 공용 40개)으로 돌리고, ``asyncio.to_thread``는 이벤트
  루프의 **기본 실행기**(작은 스레드 묶음)를 쓴다. DB가 멈춘 동안 ``GET /history``·``POST /dnd`` 같은 요청이 쌓이면 두
  풀이 모두 DB를 기다리는 일로 차고, 그 뒤에 온 정지는 인증 의존성에서부터 줄을 섰다.
- 그래서 정지 경로는 (1) 인증·서비스 의존성을 **블로킹 없는 async**로 풀고(캐시가 차 있으면 메모리 읽기뿐),
  (2) 정지 작업은 **이 모듈의 전용 실행기**(``STOP_LANE_WORKERS``개)에서 돈다. 일반 요청은 이 실행기를 쓰지 않는다.

경계(보조 안전): 물리 비상정지(E-STOP)가 최종 권한이다. 이 줄은 소프트웨어 정지가 **공유 풀 고갈과 DB 대기에 묶이지
않게** 할 뿐이다. 이벤트 루프 자체를 멈추는 코드(async 라우터 안의 블로킹)나 서비스 잠금을 오래 쥔 코드가 있으면 정지는
여전히 늦는다 — 그런 경로는 따로 없앴다(devlog 2026-10-14 재확인 2차 §4). 시험한 조건 밖의 부하에서 상한을 보장하지 않는다.
"""

from __future__ import annotations

import asyncio
import contextvars
import functools
import inspect
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from typing import Any, TypeVar

from fastapi import Request

T = TypeVar("T")

#: 정지 전용 스레드 수. ``POST /stop`` 하나가 동시에 쓰는 작업은 셋(실행 정지·개발자 세션·자동 실행 규칙)이고 뒤이어
#: 하나(루틴)다 — 연타 두 번을 겹쳐 받을 만큼만 둔다. 일반 요청은 이 실행기를 쓰지 않는다.
STOP_LANE_WORKERS = 6

_executor = ThreadPoolExecutor(max_workers=STOP_LANE_WORKERS, thread_name_prefix="simplelay-stop")


async def run_on_stop_lane(fn: Callable[..., T], /, *args: Any, **kwargs: Any) -> T:
    """``fn``을 정지 전용 실행기에서 돌린다(``asyncio.to_thread``와 같은 모양, 공유 풀을 쓰지 않음)."""
    loop = asyncio.get_running_loop()
    call = functools.partial(contextvars.copy_context().run, fn, *args, **kwargs)
    return await loop.run_in_executor(_executor, call)


async def resolve_without_shared_pool(request: Request, dependency: Callable[[], T],
                                      build: Callable[[], T] | None = None) -> T:
    """``Depends(dependency)``를 공유 풀 없이 푼다 — 정지 경로의 의존성 전용.

    - 시험·구성이 ``app.dependency_overrides``로 바꿔 끼웠으면 그것을 쓴다(``Depends``와 같은 뜻).
    - ``lru_cache`` 싱글턴이 이미 만들어졌으면 캐시 읽기(메모리)라 루프에서 바로 부른다.
    - 아직 없으면(기동 직후 첫 요청) 만드는 일은 입출력이 있을 수 있어 정지 전용 실행기에서 한다.
    """
    overrides = getattr(request.app, "dependency_overrides", None) or {}
    override = overrides.get(dependency)
    if override is not None:
        value = override()
        return await value if inspect.isawaitable(value) else value
    fn = build or dependency
    info = getattr(fn, "cache_info", None)
    if info is None or info().currsize:
        return fn()
    return await run_on_stop_lane(fn)
