"""루틴 저장소 — DB(``SIMPLELAY_DB_PATH``)가 있으면 SQLite, 없으면 메모리.

다른 저장소와 같은 관례다: 개발 PC·테스트는 메모리라 파일 상태가 새지 않고,
실기기는 재시작해도 사용자가 만든 루틴이 남는다. 읽을 수 없는 행은 건너뛰고
로그만 남긴다 -- 한 줄이 깨졌다고 루틴 전체가 사라지면 안 된다.

**읽기와 쓰기(2026-10-14 HIGH 재확인 2차).**

- 읽기(``list``·``get``)는 잠금 없이 불변 사본을 본다. 쓰기는 쓰기 잠금 안에서 DB에 먼저 쓰고 성공하면 사본을 통째로
  바꿔 끼운다 — 이벤트 루프의 async 라우터가 목록을 읽어도 다른 요청의 DB 쓰기를 기다리지 않는다(H-RR2와 같은 모양).
- 읽은 뒤 저장하는 변경은 **저장소의 한 연산**으로 한다(M-RR1): ``update``는 쓰기 잠금 안에서 지금(최신) 루틴을 읽어
  바꾸고, ``replace``는 호출자가 읽은 그 루틴이 아직 그대로일 때만 교체한다. 그 사이 지워졌으면
  ``RoutineNotFoundError``(404), 바뀌었으면 ``RoutineConflictError``(409) — 지운 루틴을 되살리거나 끝난 편집을 옛
  객체로 되돌리지 않는다. ``save``(그대로 덮기)는 새 루틴 만들기에만 쓴다.
"""

from __future__ import annotations

import json
import logging
import threading
from collections.abc import Callable
from types import MappingProxyType
from uuid import uuid4

from .model import SCHEMA_VERSION, Routine, RoutineValidationError, routine_from_document

log = logging.getLogger(__name__)


class RoutineNotFoundError(KeyError):
    pass


class RoutineConflictError(RuntimeError):
    """읽은 뒤 다른 요청이 그 루틴을 바꿨다 — 옛 판으로 덮지 않는다(409)."""


class RoutineStore:
    def __init__(self, db=None) -> None:
        self._db = db
        #: 쓰기 잠금 — 존재 확인·판 대조·DB 쓰기·사본 교체를 한 덩어리로(DB를 기다리는 동안 쥔다). 읽기는 잡지 않는다.
        self._lock = threading.Lock()
        routines: dict[str, Routine] = {}
        if db is not None:
            for routine_id, document in db.routine_documents():
                try:
                    routines[routine_id] = routine_from_document(json.loads(document))
                except (ValueError, KeyError, TypeError, RoutineValidationError):
                    log.exception("routine %s unreadable; skipped", routine_id)
        self._routines: MappingProxyType[str, Routine] = MappingProxyType(routines)

    @staticmethod
    def new_id() -> str:
        return f"rt-{uuid4().hex[:10]}"

    # 읽기: 잠금 없음(불변 사본)
    def list(self) -> tuple[Routine, ...]:
        return tuple(self._routines.values())

    def get(self, routine_id: str) -> Routine | None:
        return self._routines.get(routine_id)

    def require(self, routine_id: str) -> Routine:
        routine = self.get(routine_id)
        if routine is None:
            raise RoutineNotFoundError(routine_id)
        return routine

    # 쓰기: 쓰기 잠금 안에서 DB 먼저, 성공하면 사본 교체
    def _write_locked(self, routine: Routine) -> Routine:
        if self._db is not None:
            self._db.save_routine(
                routine.routine_id,
                json.dumps(routine.to_dict(), ensure_ascii=False),
                SCHEMA_VERSION,
                routine.updated_at.isoformat() if routine.updated_at else None,
            )
        routines = dict(self._routines)
        routines[routine.routine_id] = routine
        self._routines = MappingProxyType(routines)
        return routine

    def save(self, routine: Routine) -> Routine:
        """그대로 덮기(없으면 만듦) — 새 루틴 만들기 전용. 읽은 뒤 바꾸는 변경은 ``update``·``replace``."""
        with self._lock:
            return self._write_locked(routine)

    def update(self, routine_id: str, change: Callable[[Routine], Routine]) -> Routine:
        """지금(최신) 루틴에 ``change``를 적용해 저장한다 — 읽기·바꾸기·저장이 한 연산. 없으면 ``RoutineNotFoundError``."""
        with self._lock:
            current = self._routines.get(routine_id)
            if current is None:
                raise RoutineNotFoundError(routine_id)
            return self._write_locked(change(current))

    def replace(self, routine: Routine, expected: Routine) -> Routine:
        """``expected``(호출자가 읽은 그 루틴)가 아직 그대로일 때만 ``routine``으로 교체한다.
        지워졌으면 ``RoutineNotFoundError``, 그 사이 바뀌었으면 ``RoutineConflictError``."""
        with self._lock:
            current = self._routines.get(routine.routine_id)
            if current is None:
                raise RoutineNotFoundError(routine.routine_id)
            if current is not expected:
                raise RoutineConflictError(routine.routine_id)
            return self._write_locked(routine)

    def delete(self, routine_id: str) -> None:
        with self._lock:
            if routine_id not in self._routines:
                raise RoutineNotFoundError(routine_id)
            if self._db is not None:
                self._db.delete_routine(routine_id)
            routines = dict(self._routines)
            del routines[routine_id]
            self._routines = MappingProxyType(routines)
