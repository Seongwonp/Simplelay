"""루틴 저장소 — DB(``SIMPLELAY_DB_PATH``)가 있으면 SQLite, 없으면 메모리.

다른 저장소와 같은 관례다: 개발 PC·테스트는 메모리라 파일 상태가 새지 않고,
실기기는 재시작해도 사용자가 만든 루틴이 남는다. 읽을 수 없는 행은 건너뛰고
로그만 남긴다 -- 한 줄이 깨졌다고 루틴 전체가 사라지면 안 된다.
"""

from __future__ import annotations

import json
import logging
import threading
from uuid import uuid4

from .model import SCHEMA_VERSION, Routine, RoutineValidationError, routine_from_document

log = logging.getLogger(__name__)


class RoutineNotFoundError(KeyError):
    pass


class RoutineStore:
    def __init__(self, db=None) -> None:
        self._db = db
        self._lock = threading.Lock()
        self._routines: dict[str, Routine] = {}
        if db is not None:
            for routine_id, document in db.routine_documents():
                try:
                    self._routines[routine_id] = routine_from_document(json.loads(document))
                except (ValueError, KeyError, TypeError, RoutineValidationError):
                    log.exception("routine %s unreadable; skipped", routine_id)

    @staticmethod
    def new_id() -> str:
        return f"rt-{uuid4().hex[:10]}"

    def list(self) -> tuple[Routine, ...]:
        with self._lock:
            return tuple(self._routines.values())

    def get(self, routine_id: str) -> Routine | None:
        with self._lock:
            return self._routines.get(routine_id)

    def require(self, routine_id: str) -> Routine:
        routine = self.get(routine_id)
        if routine is None:
            raise RoutineNotFoundError(routine_id)
        return routine

    def save(self, routine: Routine) -> Routine:
        with self._lock:
            if self._db is not None:
                self._db.save_routine(
                    routine.routine_id,
                    json.dumps(routine.to_dict(), ensure_ascii=False),
                    SCHEMA_VERSION,
                    routine.updated_at.isoformat() if routine.updated_at else None,
                )
            self._routines[routine.routine_id] = routine
            return routine

    def delete(self, routine_id: str) -> None:
        with self._lock:
            if routine_id not in self._routines:
                raise RoutineNotFoundError(routine_id)
            if self._db is not None:
                self._db.delete_routine(routine_id)
            del self._routines[routine_id]
