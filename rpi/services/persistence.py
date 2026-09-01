"""SQLite 영속화 — 사용 이력(패턴 학습)과 노드 등록을 서버 재시작에도 유지.

그동안 전부 인메모리라 systemd 재시작 한 번이면 패턴 학습 데모와 키오스크에서
등록한 ESP32 IP가 전부 증발했다. ``SIMPLELAY_DB_PATH`` 환경변수로 켠다
(scripts/simplelay.service 참고). 미설정이면 기존처럼 인메모리로 동작한다 —
개발 PC·테스트에서 상태가 파일로 새어 테스트끼리 오염되는 것을 막기 위한
기존 관례(SIMPLELAY_GPIO_ENABLED 등 env 게이트)와 같은 방식이다.

FastAPI는 요청을 스레드풀에서 처리하고 실행 job도 별도 스레드라, 커넥션은
``check_same_thread=False`` + 자체 락으로 직렬화한다(트래픽 규모상 충분).

의도적으로 저장하지 않는 것: pending 제안(주기 스케줄러가 이력에서 재생성),
last_result(재시작 후의 '이전 실행 결과'는 클라이언트에 오히려 혼란).
"""

from __future__ import annotations

import sqlite3
import threading
from datetime import datetime
from pathlib import Path

import json

from rpi.intent.models import UsageOutcome, UsageRecord
from rpi.intent.ports import SuppressionStore, UsageLog

import logging

from .history import ButtonAttempt, JobHistoryEntry

_log = logging.getLogger(__name__)


class SimpleLayDb:
    def __init__(self, path: str) -> None:
        Path(path).expanduser().parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(path, check_same_thread=False)
        self._lock = threading.Lock()
        with self._lock:
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS usage_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    occurred_at TEXT NOT NULL,  -- ISO-8601, timezone 포함
                    purpose TEXT NOT NULL,
                    outcome TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS nodes (
                    appliance_id TEXT PRIMARY KEY,
                    base_url TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS suppressions (
                    purpose TEXT PRIMARY KEY  -- '다시 추천 안 함'한 루틴
                );
                CREATE TABLE IF NOT EXISTS care_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,         -- 보호자 알림 종류
                    message TEXT NOT NULL,
                    purpose TEXT,               -- 관련 루틴 (없을 수 있음)
                    time_band TEXT,             -- 안부 신호 시간대 (dedupe 열쇠)
                    occurred_at TEXT NOT NULL   -- ISO-8601, timezone 포함
                );
                CREATE TABLE IF NOT EXISTS appliances (
                    appliance_id TEXT PRIMARY KEY,  -- 폰에서 등록한 커스텀 가전
                    payload_json TEXT NOT NULL      -- {name, icon, rows, cols, buttons}
                );
                CREATE TABLE IF NOT EXISTS job_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL,
                    finished_at TEXT NOT NULL,  -- ISO-8601, timezone 포함
                    purpose TEXT,               -- 버튼 직접 실행은 NULL
                    status TEXT NOT NULL,
                    buttons_json TEXT NOT NULL  -- [{button, success, attempts}]
                );
                """
            )
            self._conn.commit()

    # ── 사용 이력 (패턴 학습) ────────────────────────────────────────────────

    def append_usage(self, record: UsageRecord) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO usage_log (occurred_at, purpose, outcome)"
                " VALUES (?, ?, ?)",
                (
                    record.occurred_at.isoformat(),
                    record.purpose,
                    record.outcome.value,
                ),
            )
            self._conn.commit()

    def usage_records(self) -> tuple[UsageRecord, ...]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT occurred_at, purpose, outcome FROM usage_log ORDER BY id"
            ).fetchall()
        return tuple(
            UsageRecord(
                datetime.fromisoformat(occurred_at), purpose, UsageOutcome(outcome)
            )
            for occurred_at, purpose, outcome in rows
        )

    # ── 노드 등록 (appliance_id → ESP32 base_url) ───────────────────────────

    def save_node(self, appliance_id: str, base_url: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO nodes (appliance_id, base_url) VALUES (?, ?)"
                " ON CONFLICT(appliance_id) DO UPDATE SET base_url = excluded.base_url",
                (appliance_id, base_url),
            )
            self._conn.commit()

    def delete_node(self, appliance_id: str) -> None:
        with self._lock:
            self._conn.execute(
                "DELETE FROM nodes WHERE appliance_id = ?", (appliance_id,)
            )
            self._conn.commit()

    def nodes(self) -> dict[str, str]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT appliance_id, base_url FROM nodes"
            ).fetchall()
        return dict(rows)

    # ── 보호자 알림 이력 ─────────────────────────────────────────────────────

    def append_care_event(
        self, kind: str, message: str, purpose, occurred_at, time_band=None
    ) -> int:
        with self._lock:
            cursor = self._conn.execute(
                "INSERT INTO care_events"
                " (kind, message, purpose, time_band, occurred_at)"
                " VALUES (?, ?, ?, ?, ?)",
                (kind, message, purpose, time_band, occurred_at.isoformat()),
            )
            self._conn.commit()
            return int(cursor.lastrowid)

    def care_event_exists_on(self, kind, purpose, day, time_band=None) -> bool:
        # 같은 (kind, purpose, time_band, 현지 날짜) 이벤트 존재 여부 —
        # 메모리 링(200건)이 밀려나거나 재시작해도 dedupe가 유지되도록 DB에
        # 직접 묻는다 (교차 리뷰 #10). occurred_at은 서버 현지 tz의 ISO라
        # 날짜 prefix 비교가 곧 현지 날짜 비교다. NULL 비교는 IS로.
        with self._lock:
            row = self._conn.execute(
                "SELECT 1 FROM care_events"
                " WHERE kind = ? AND occurred_at LIKE ?"
                "   AND purpose IS ? AND time_band IS ?"
                " LIMIT 1",
                (kind, day.isoformat() + "%", purpose, time_band),
            ).fetchone()
            return row is not None

    def care_events(self, limit: int = 200) -> tuple:
        from .care_events import CareEvent  # noqa: PLC0415 — 순환 회피

        with self._lock:
            rows = self._conn.execute(
                "SELECT id, kind, message, purpose, time_band, occurred_at"
                " FROM care_events ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        # 오래된 것 → 최신 순으로 돌려준다 (store의 링 버퍼가 append 순서를 가정)
        return tuple(
            CareEvent(
                event_id=row[0],
                kind=row[1],
                message=row[2],
                purpose=row[3],
                time_band=row[4],
                occurred_at=datetime.fromisoformat(row[5]),
            )
            for row in reversed(rows)
        )

    # ── 커스텀 가전 (appliance_id → 정의 JSON) ──────────────────────────────

    def save_appliance(self, appliance) -> None:
        from .appliance_registry import ApplianceDef  # noqa: PLC0415 — 순환 회피

        assert isinstance(appliance, ApplianceDef)
        payload = json.dumps(
            {
                "name": appliance.name,
                "icon": appliance.icon,
                "rows": appliance.rows,
                "cols": appliance.cols,
                "buttons": [
                    {"id": b.id, "label": b.label, "x": b.x, "y": b.y}
                    for b in appliance.buttons
                ],
            },
            ensure_ascii=False,
        )
        with self._lock:
            self._conn.execute(
                "INSERT INTO appliances (appliance_id, payload_json) VALUES (?, ?)"
                " ON CONFLICT(appliance_id) DO UPDATE"
                " SET payload_json = excluded.payload_json",
                (appliance.appliance_id, payload),
            )
            self._conn.commit()

    def delete_appliance(self, appliance_id: str) -> None:
        with self._lock:
            self._conn.execute(
                "DELETE FROM appliances WHERE appliance_id = ?", (appliance_id,)
            )
            self._conn.commit()

    def appliances(self) -> tuple:
        from .appliance_registry import ApplianceButtonDef, ApplianceDef  # noqa: PLC0415

        with self._lock:
            rows = self._conn.execute(
                "SELECT appliance_id, payload_json FROM appliances"
            ).fetchall()
        result = []
        for appliance_id, payload_json in rows:
            try:
                data = json.loads(payload_json)
                result.append(
                    ApplianceDef(
                        appliance_id=appliance_id,
                        name=data["name"],
                        icon=data.get("icon", "custom"),
                        rows=int(data["rows"]),
                        cols=int(data["cols"]),
                        buttons=tuple(
                            ApplianceButtonDef(
                                id=b["id"],
                                label=b["label"],
                                x=int(b["x"]),
                                y=int(b["y"]),
                            )
                            for b in data["buttons"]
                        ),
                        is_custom=True,
                    )
                )
            except Exception:
                # 한 행이 손상돼도 나머지 가전은 살아야 한다 (교차 리뷰 #16)
                _log.exception("skipping corrupt appliance row %r", appliance_id)
        return tuple(result)

    # ── 실행(job) 이력 ──────────────────────────────────────────────────────

    def append_job_history(self, entry: JobHistoryEntry) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO job_history"
                " (job_id, finished_at, purpose, status, buttons_json)"
                " VALUES (?, ?, ?, ?, ?)",
                (
                    entry.job_id,
                    entry.finished_at.isoformat(),
                    entry.purpose,
                    entry.status,
                    json.dumps(
                        [
                            {
                                "button": b.button,
                                "success": b.success,
                                "attempts": b.attempts,
                            }
                            for b in entry.buttons
                        ],
                        ensure_ascii=False,
                    ),
                ),
            )
            self._conn.commit()

    def recent_job_history(self, limit: int = 50) -> tuple[JobHistoryEntry, ...]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT job_id, finished_at, purpose, status, buttons_json"
                " FROM job_history ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return tuple(
            JobHistoryEntry(
                job_id=job_id,
                finished_at=datetime.fromisoformat(finished_at),
                purpose=purpose,
                status=status,
                buttons=tuple(
                    ButtonAttempt(b["button"], b["success"], b["attempts"])
                    for b in json.loads(buttons_json)
                ),
            )
            for job_id, finished_at, purpose, status, buttons_json in rows
        )

    # ── 제안 억제(다시 추천 안 함) ───────────────────────────────

    def add_suppression(self, purpose: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT OR IGNORE INTO suppressions (purpose) VALUES (?)",
                (purpose.strip(),),
            )
            self._conn.commit()

    def remove_suppression(self, purpose: str) -> None:
        with self._lock:
            self._conn.execute(
                "DELETE FROM suppressions WHERE purpose = ?", (purpose.strip(),)
            )
            self._conn.commit()

    def suppressions(self) -> frozenset[str]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT purpose FROM suppressions"
            ).fetchall()
        return frozenset(row[0] for row in rows)

    def close(self) -> None:
        with self._lock:
            self._conn.close()


class SqliteJobHistory:
    """JobHistoryStore 포트의 SQLite 구현 — 재시작에도 이력 유지."""

    def __init__(self, db: SimpleLayDb) -> None:
        self._db = db

    def append(self, entry: JobHistoryEntry) -> None:
        self._db.append_job_history(entry)

    def recent(self, limit: int = 50) -> tuple[JobHistoryEntry, ...]:
        return self._db.recent_job_history(limit)


class SqliteSuppressionStore(SuppressionStore):
    """SuppressionStore 포트의 SQLite 구현 -- 인메모리와 같은 계약."""

    def __init__(self, db: SimpleLayDb) -> None:
        self._db = db

    def mute(self, purpose: str) -> None:
        self._db.add_suppression(purpose)

    def unmute(self, purpose: str) -> None:
        self._db.remove_suppression(purpose)

    def muted(self) -> frozenset[str]:
        return self._db.suppressions()


class SqliteUsageLog(UsageLog):
    """UsageLog 포트의 SQLite 구현 — InMemoryUsageLog와 같은 계약."""

    def __init__(self, db: SimpleLayDb) -> None:
        self._db = db

    def append(self, record: UsageRecord) -> None:
        self._db.append_usage(record)

    def records(self) -> tuple[UsageRecord, ...]:
        return self._db.usage_records()
