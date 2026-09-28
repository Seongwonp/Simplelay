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
from datetime import date, datetime
from pathlib import Path

import json

from rpi.intent.models import UsageOutcome, UsageRecord, UsageSource
from rpi.intent.ports import SuppressionStore, UsageLog

import logging

from .history import (
    ButtonAttempt,
    ExecutionMode,
    JobHistoryEntry,
    Termination,
)

_log = logging.getLogger(__name__)

_WELLNESS_PAUSE_KEY = "wellness_pause_until"


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
                    outcome TEXT NOT NULL,
                    appliance_id TEXT           -- 대상 가전 (옛 기록은 NULL)
                );
                CREATE TABLE IF NOT EXISTS suggestion_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event_id TEXT NOT NULL UNIQUE,
                    payload_json TEXT NOT NULL
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
                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,       -- 기기 하나짜리 설정
                    value TEXT                  -- NULL이면 해제된 상태
                );
                CREATE TABLE IF NOT EXISTS job_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    job_id TEXT NOT NULL,
                    finished_at TEXT NOT NULL,  -- ISO-8601, timezone 포함
                    purpose TEXT,               -- 버튼 직접 실행은 NULL
                    status TEXT NOT NULL,
                    buttons_json TEXT NOT NULL, -- [{button, success, attempts}]
                    -- 실험 계측 (F4). 옛 기록은 NULL — 모드를 지어내지 않는다.
                    appliance_id TEXT,
                    execution_mode TEXT,
                    started_at TEXT,            -- ISO-8601, timezone 포함
                    termination TEXT,
                    calibration_profile_version TEXT,
                    stop_requested_at TEXT,      -- ISO-8601, 정지된 실행만
                    outcome TEXT                 -- success|failed|stopped|safety_stop
                );
                """
            )
            self._conn.commit()
        self._migrate()

    def _migrate(self) -> None:
        """이미 만들어진 DB에 나중에 생긴 열을 채워 넣는다.

        CREATE TABLE IF NOT EXISTS는 기존 테이블을 손대지 않으므로, 실기기에
        이미 깔린 DB는 새 열 없이 남는다. 파일을 지우게 하면 그동안 쌓인
        패턴 학습 이력이 날아가므로 ALTER로 더한다(추가 열은 NULL 허용).
        """
        with self._lock:
            columns = {
                row[1]
                for row in self._conn.execute("PRAGMA table_info(usage_log)")
            }
            if "appliance_id" not in columns:
                self._conn.execute(
                    "ALTER TABLE usage_log ADD COLUMN appliance_id TEXT"
                )
                self._conn.commit()
                _log.info("usage_log migrated: appliance_id column added")

            for column in ("execution_mode", "source"):
                if column not in columns:
                    self._conn.execute(f"ALTER TABLE usage_log ADD COLUMN {column} TEXT")
            self._conn.commit()

            job_columns = {
                row[1]
                for row in self._conn.execute("PRAGMA table_info(job_history)")
            }
            for column in (
                "appliance_id",
                "execution_mode",
                "started_at",
                "termination",
                "calibration_profile_version",
                "stop_requested_at",
                "outcome",
            ):
                if column not in job_columns:
                    self._conn.execute(
                        f"ALTER TABLE job_history ADD COLUMN {column} TEXT"
                    )
                    self._conn.commit()
                    _log.info("job_history migrated: %s column added", column)

    # ── 기기 설정 ───────────────────────────────────────────────────────────

    def load_wellness_pause(self) -> date | None:
        """안부 확인 일시 중지의 종료 날짜 (F5).

        메모리에만 두면 여행 이틀째의 재부팅 한 번으로 남은 닷새 동안
        알림이 다시 온다 -- 이 기능이 없애려던 바로 그 상황이다.
        """
        with self._lock:
            row = self._conn.execute(
                "SELECT value FROM settings WHERE key = ?",
                (_WELLNESS_PAUSE_KEY,),
            ).fetchone()
        if row is None or row[0] is None:
            return None
        try:
            return date.fromisoformat(row[0])
        except ValueError:
            # 손상된 값으로 안부 확인이 영영 꺼져 있는 것보다, 못 읽으면
            # 쉬지 않는 쪽이 안전하다.
            _log.warning("wellness pause value unreadable: %r", row[0])
            return None

    def load_setting(self, key: str) -> str | None:
        """범용 설정 한 칸 — 값 해석은 호출자가 한다."""
        with self._lock:
            row = self._conn.execute(
                "SELECT value FROM settings WHERE key = ?", (key,)
            ).fetchone()
        return None if row is None else row[0]

    def save_setting(self, key: str, value: str | None) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?)"
                " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (key, value),
            )
            self._conn.commit()

    def save_wellness_pause(self, until: date | None) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?)"
                " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (
                    _WELLNESS_PAUSE_KEY,
                    None if until is None else until.isoformat(),
                ),
            )
            self._conn.commit()

    # ── 사용 이력 (패턴 학습) ────────────────────────────────────────────────

    def append_suggestion_event(self, event: dict) -> None:
        from rpi.intent.feedback import EVENT_CAPACITY
        with self._lock, self._conn:
            self._conn.execute(
                "INSERT INTO suggestion_events (event_id, payload_json) VALUES (?, ?)",
                (event["event_id"], json.dumps(event, ensure_ascii=False)),
            )
            self._conn.execute(
                "DELETE FROM suggestion_events WHERE id NOT IN "
                "(SELECT id FROM suggestion_events ORDER BY id DESC LIMIT ?)",
                (EVENT_CAPACITY,),
            )

    def suggestion_events(self) -> list[dict]:
        from rpi.intent.feedback import EVENT_CAPACITY
        with self._lock:
            rows = self._conn.execute(
                "SELECT payload_json FROM suggestion_events ORDER BY id DESC LIMIT ?",
                (EVENT_CAPACITY,),
            ).fetchall()
        return [json.loads(row[0]) for row in reversed(rows)]

    def append_usage(self, record: UsageRecord) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO usage_log"
                " (occurred_at, purpose, outcome, appliance_id, execution_mode, source)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                (
                    record.occurred_at.isoformat(),
                    record.purpose,
                    record.outcome.value,
                    record.appliance_id,
                    record.execution_mode.value,
                    record.source.value,
                ),
            )
            self._conn.commit()

    def usage_records(self) -> tuple[UsageRecord, ...]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT occurred_at, purpose, outcome, appliance_id, execution_mode, source"
                " FROM usage_log ORDER BY id"
            ).fetchall()
        return tuple(
            UsageRecord(
                datetime.fromisoformat(occurred_at),
                purpose,
                UsageOutcome(outcome),
                appliance_id=appliance_id,
                execution_mode=ExecutionMode(execution_mode or "unknown"),
                source=UsageSource(source or "unknown"),
            )
            for occurred_at, purpose, outcome, appliance_id, execution_mode, source in rows
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

        def button_payload(b) -> dict:
            # 확장 필드는 값이 있을 때만 싣는다 — 예전 행과 모양이 같게 남아
            # 구버전 서버로 되돌려도 읽힌다.
            data = {"id": b.id, "label": b.label, "x": b.x, "y": b.y}
            if b.kind.value != "button":
                data["kind"] = b.kind.value
            for key in ("detents", "press_ms", "x_mm", "y_mm"):
                value = getattr(b, key)
                if value is not None:
                    data[key] = value
            return data

        document = {
            "name": appliance.name,
            "category": appliance.category.value,
            "rows": appliance.rows,
            "cols": appliance.cols,
            # 판 번호도 함께 남긴다 — 재시작마다 1로 돌아가면
            # 충돌 검사가 의미를 잃는다.
            "revision": appliance.revision,
            "buttons": [button_payload(b) for b in appliance.buttons],
        }
        if appliance.functions:
            document["functions"] = {
                name: list(steps) for name, steps in appliance.functions
            }
        if appliance.calibration_version:
            document["calibration_version"] = appliance.calibration_version
        payload = json.dumps(document, ensure_ascii=False)
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
        from .appliance_registry import (  # noqa: PLC0415 — 순환 회피
            ApplianceButtonDef,
            ApplianceCategory,
            ApplianceDef,
            ButtonKind,
            category_from_legacy_icon,
        )  # noqa: PLC0415

        def opt_int(value):
            return None if value is None else int(value)

        def opt_float(value):
            return None if value is None else float(value)

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
                        # 예전 행에는 category가 없다. icon에서
                        # 명시적인 표로만 되살리고, 모르면 other다 --
                        # 데이터는 하나도 잃지 않는다.
                        category=(
                            ApplianceCategory.parse(data["category"])
                            if "category" in data
                            else category_from_legacy_icon(
                                data.get("icon")
                            )
                        ),
                        rows=int(data["rows"]),
                        cols=int(data["cols"]),
                        buttons=tuple(
                            ApplianceButtonDef(
                                id=b["id"],
                                label=b["label"],
                                x=int(b["x"]),
                                y=int(b["y"]),
                                # 확장 필드가 없는 예전 행은 기본값(누름 버튼,
                                # 보정 전)으로 살아난다.
                                kind=ButtonKind.parse(b.get("kind")),
                                detents=opt_int(b.get("detents")),
                                press_ms=opt_int(b.get("press_ms")),
                                x_mm=opt_float(b.get("x_mm")),
                                y_mm=opt_float(b.get("y_mm")),
                            )
                            for b in data["buttons"]
                        ),
                        is_custom=True,
                        revision=int(data.get("revision", 0)),
                        functions=tuple(
                            (str(name), tuple(str(s) for s in steps))
                            for name, steps in (data.get("functions") or {}).items()
                        ),
                        calibration_version=data.get("calibration_version"),
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
                " (job_id, finished_at, purpose, status, buttons_json,"
                "  appliance_id, execution_mode, started_at, termination,"
                "  calibration_profile_version, stop_requested_at, outcome)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
                    entry.appliance_id,
                    entry.execution_mode.value,
                    entry.started_at.isoformat() if entry.started_at else None,
                    entry.termination.value,
                    entry.calibration_profile_version,
                    (
                        entry.stop_requested_at.isoformat()
                        if entry.stop_requested_at
                        else None
                    ),
                    entry.outcome,
                ),
            )
            self._conn.commit()

    def recent_job_history(self, limit: int = 50) -> tuple[JobHistoryEntry, ...]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT job_id, finished_at, purpose, status, buttons_json,"
                " appliance_id, execution_mode, started_at, termination,"
                " calibration_profile_version, stop_requested_at, outcome"
                " FROM job_history ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return tuple(
            JobHistoryEntry(
                job_id=row[0],
                finished_at=datetime.fromisoformat(row[1]),
                purpose=row[2],
                status=row[3],
                buttons=tuple(
                    ButtonAttempt(b["button"], b["success"], b["attempts"])
                    for b in json.loads(row[4])
                ),
                appliance_id=row[5],
                # 열이 생기기 전 기록은 NULL — 모드·종료 사유를 지어내지 않는다.
                execution_mode=ExecutionMode(row[6] or ExecutionMode.UNKNOWN.value),
                started_at=datetime.fromisoformat(row[7]) if row[7] else None,
                termination=Termination(row[8] or Termination.UNKNOWN.value),
                calibration_profile_version=row[9],
                stop_requested_at=(
                    datetime.fromisoformat(row[10]) if row[10] else None
                ),
                # 열이 생기기 전 기록은 NULL — effective_outcome이 유도한다.
                outcome=row[11],
            )
            for row in rows
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
