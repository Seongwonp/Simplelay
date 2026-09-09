"""실행(job) 이력 — "무엇을·언제·몇 번 재시도해서·어떻게 끝났는지"의 기록.

두 가지 목적:
1. 사용자에게 공감지능의 근거를 보여준다 — 패턴 학습이 어떤 이력에서
   나오는지, 폐루프가 실제로 몇 번 재시도로 회복했는지(앱 타임라인 화면).
2. 발표용 실험 데이터의 축적 기반 — 실기기 검증 기간의 성공률·재시도
   횟수 통계를 여기서 뽑는다.

저장은 UsageLog와 같은 패턴: SIMPLELAY_DB_PATH가 있으면 SQLite
(persistence.SqliteJobHistory), 없으면 인메모리(개발·테스트).
"""

from __future__ import annotations

import csv
import io
import threading
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum
from typing import Protocol

# 실행 모드는 **실행 경로의 성질**이라 컨트롤러 계층에 산다. 여기서
# 다시 정의하면 같은 이름의 enum이 둘이 되어 `is` 비교가 조용히 어긋난다.
from rpi.controller import ExecutionMode


class Termination(str, Enum):
    """왜 끝났나.

    ``status``만으로는 **사용자가 멈춘 실행**과 **재시도를 소진한 실행**이
    뭉개진다. 실험에서 둘은 전혀 다른 표본이고(정지 지연 vs 실패율),
    보호자에게도 전혀 다른 소식이다.
    """

    COMPLETED = "completed"
    STOPPED_BY_USER = "stopped_by_user"
    RETRIES_EXHAUSTED = "retries_exhausted"
    UNKNOWN = "unknown"


@dataclass(frozen=True)
class ButtonAttempt:
    button: str
    success: bool
    attempts: int


@dataclass(frozen=True)
class JobHistoryEntry:
    job_id: str
    finished_at: datetime
    purpose: str | None  # 버튼 직접 실행(수동 조작)은 목적 문자열이 없다
    status: str  # succeeded | safety_stopped | failed
    buttons: tuple[ButtonAttempt, ...]
    # ── 실험 계측 (F4) — 실기기 실험을 시작하면 바로 필요해지는 것들 ──
    #: 어떤 가전에서 했나. 가전마다 성공률이 다르므로 분모를 가르는 열쇠다.
    appliance_id: str | None = None
    execution_mode: ExecutionMode = ExecutionMode.UNKNOWN
    #: 시작 시각. 없으면 소요시간을 뺄 수 없다(옛 기록은 None).
    started_at: datetime | None = None
    termination: Termination = Termination.UNKNOWN
    #: 어떤 보정으로 맞춘 좌표에서 나온 결과인가. 좌표를 다시 맞추면
    #: 성공률이 통째로 달라지므로, 버전을 함께 남기지 않으면 나중에
    #: 그 숫자가 어느 조건의 것이었는지 해석할 수 없다.
    calibration_profile_version: str | None = None

    @property
    def retry_count(self) -> int:
        """전체 재시도 횟수 — 폐루프가 회복을 위해 추가로 누른 횟수의 합."""
        return sum(max(0, b.attempts - 1) for b in self.buttons)

    @property
    def duration(self) -> timedelta | None:
        if self.started_at is None:
            return None
        return self.finished_at - self.started_at


class JobHistoryStore(Protocol):
    def append(self, entry: JobHistoryEntry) -> None: ...

    def recent(self, limit: int = 50) -> tuple[JobHistoryEntry, ...]: ...


class InMemoryJobHistory:
    """개발·테스트용 — 프로세스 메모리에 최근 N건만 유지."""

    def __init__(self, max_entries: int = 200) -> None:
        self._lock = threading.Lock()
        self._entries: deque[JobHistoryEntry] = deque(maxlen=max_entries)

    def append(self, entry: JobHistoryEntry) -> None:
        with self._lock:
            self._entries.append(entry)

    def recent(self, limit: int = 50) -> tuple[JobHistoryEntry, ...]:
        with self._lock:
            items = list(self._entries)
        return tuple(reversed(items))[:limit]  # 최신순


# ── 실험 기록 내보내기 ──────────────────────────────────────────────────────

#: CSV로 나가는 열. **허용 목록**이다 -- 새 필드가 늘어도 여기 적지 않으면
#: 나가지 않는다. 주소·API 키·가정 식별정보·원문 음성은 이 목록에 없다.
_CSV_COLUMNS = (
    "job_id",
    "appliance_id",
    "purpose",
    "execution_mode",
    "status",
    "termination",
    "started_at",
    "finished_at",
    "duration_seconds",
    "calibration_profile_version",
    "retry_count",
    "buttons",
)


def history_csv(entries: tuple[JobHistoryEntry, ...]) -> str:
    """실행 이력을 CSV 한 장으로.

    실기기 실험(H1)의 근거 데이터가 여기서 나온다. 뽑을 수 있어야 하는 것:
    첫 시도 성공률, 재시도 후 최종 성공률, 실행 시간, 정지 지연, 실제/모의
    구분. 그래서 버튼별 시도 수까지 한 열에 싣는다(``해동:ok:2``).

    분모를 섞지 않도록 ``execution_mode``를 항상 함께 낸다 -- 이 열이 없으면
    mock 실행이 실제 성공률에 섞여 들어간다.
    """
    buffer = io.StringIO()
    # 기본 lineterminator는 CRLF다. 리눅스 기기에서 열 CSV라 LF로 고정한다.
    writer = csv.writer(buffer, lineterminator="\n")
    writer.writerow(_CSV_COLUMNS)
    for entry in entries:
        duration = entry.duration
        writer.writerow(
            [
                entry.job_id,
                entry.appliance_id or "",
                entry.purpose or "",
                entry.execution_mode.value,
                entry.status,
                entry.termination.value,
                entry.started_at.isoformat() if entry.started_at else "",
                entry.finished_at.isoformat(),
                f"{duration.total_seconds():.1f}" if duration else "",
                entry.calibration_profile_version or "",
                entry.retry_count,
                " ".join(
                    f"{b.button}:{'ok' if b.success else 'fail'}:{b.attempts}"
                    for b in entry.buttons
                ),
            ]
        )
    return buffer.getvalue()
