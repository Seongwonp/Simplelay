"""보호자 알림(care events) — 떨어져 있는 가족이 알아야 할 일의 기록.

실패·위험소리·긴급정지는 그동안 키오스크(가전 옆 화면)에만 표시됐다. 정작
걱정하는 보호자는 밖에 있는데, 폰에서 볼 방법이 없었다. 이 저장소가 그런
사건을 시간순으로 모으고 ``GET /care-events``로 폰에 내보낸다.

안부 신호(quiet_routine)는 그 확장이다: 가전 사용 이력 자체가 생활 신호라는
관찰 — 서울시 스마트플러그·한전 안부든든 등 실제 고독사 예방 서비스가
"전력·조도 변화가 일정 시간 없으면 담당자에게 알림"이라는 같은 원리로
운영된다. 우리는 플러그 없이 usage_log가 이미 그 데이터를 갖고 있다.
판단은 설명 가능한 임계값(루틴 요일 수·시간대)이지 AI 고도화가 아니다.

이벤트 종류(kind):
- execution_failed  실행이 완료되지 못함 (검증 실패·재시도 소진)
- emergency_stop    사용자가 긴급 정지로 멈춤
- danger_sound      위험 신호음 감지 (RPi4 자체발신의 rising edge)
- quiet_routine     평소 그 시간대에 쓰던 가전이 오늘 조용함
"""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass
from datetime import date, datetime

from rpi.intent.models import PatternConfig, UsageOutcome
from rpi.intent.ports import Clock, UsageLog

KIND_EXECUTION_FAILED = "execution_failed"
KIND_EMERGENCY_STOP = "emergency_stop"
KIND_DANGER_SOUND = "danger_sound"
KIND_QUIET_ROUTINE = "quiet_routine"


@dataclass(frozen=True)
class CareEvent:
    event_id: int
    kind: str
    message: str
    occurred_at: datetime
    purpose: str | None = None


class CareEventStore:
    """스레드 안전 — 실행 스레드(실패)·UART 읽기 루프(위험소리)·주기 루프
    (안부)·FastAPI 핸들러(조회)가 서로 다른 스레드에서 온다.

    SIMPLELAY_DB_PATH가 있으면 SQLite에 영속(재시작에도 알림 이력 유지),
    없으면 인메모리 링(개발 PC·테스트)."""

    MEMORY_LIMIT = 200

    def __init__(self, clock: Clock, db=None) -> None:
        self._clock = clock
        self._db = db
        self._lock = threading.Lock()
        self._memory: deque[CareEvent] = deque(maxlen=self.MEMORY_LIMIT)
        self._next_id = 1
        if db is not None:
            for event in db.care_events(limit=self.MEMORY_LIMIT):
                self._memory.append(event)
                self._next_id = max(self._next_id, event.event_id + 1)

    def append(
        self, kind: str, message: str, purpose: str | None = None
    ) -> CareEvent:
        with self._lock:
            occurred_at = self._clock.now()
            if self._db is not None:
                event_id = self._db.append_care_event(
                    kind, message, purpose, occurred_at
                )
            else:
                event_id = self._next_id
            self._next_id = max(self._next_id, event_id + 1)
            event = CareEvent(
                event_id=event_id,
                kind=kind,
                message=message,
                occurred_at=occurred_at,
                purpose=purpose,
            )
            self._memory.append(event)
            return event

    def recent(self, limit: int = 50) -> tuple[CareEvent, ...]:
        """최신순. 인메모리 링(최근 MEMORY_LIMIT건)에서 답한다 — 보호자
        알림함은 '최근에 무슨 일이 있었나'가 목적이라 이 폭이면 충분하다."""
        with self._lock:
            return tuple(reversed(list(self._memory)))[:limit]

    def has_on_date(self, kind: str, purpose: str | None, day: date) -> bool:
        """같은 날 같은 (kind, purpose) 이벤트가 이미 있나 — 안부 신호가
        60초 주기 체크마다 반복 발생하는 것을 막는 dedupe 열쇠."""
        with self._lock:
            return any(
                e.kind == kind
                and e.purpose == purpose
                and e.occurred_at.date() == day
                for e in self._memory
            )


class RoutineQuietChecker:
    """안부 신호 — "평소 그 시간대에 쓰던 가전이 오늘 조용하다"의 감지.

    규칙(전부 설명 가능한 임계값):
    - 루틴 판정: 과거(오늘 제외) 같은 시간대에 성공 사용이 서로 다른 날짜로
      ``minimum_occurrences``일 이상 — 패턴 제안과 같은 기준을 공유한다.
    - 조용함 판정: 그 시간대가 오늘 이미 끝났는데, 오늘 그 시간대에 해당
      purpose 사용 기록(성공·실패 불문 — 시도 자체가 활동 신호)이 없음.
    - 자정을 넘는 시간대(야간 등)는 제외한다: "어제 밤 루틴이 조용했다"는
      알림이 새벽에 도착하는 것은 안부 확인이 아니라 불안 유발이다.
    - 하루에 (purpose, 시간대)당 1회만 발생 (store.has_on_date로 dedupe).
    """

    def __init__(
        self,
        usage_log: UsageLog,
        clock: Clock,
        config: PatternConfig,
        care_events: CareEventStore,
    ) -> None:
        self._usage_log = usage_log
        self._clock = clock
        self._config = config
        self._care_events = care_events

    def check(self) -> tuple[CareEvent, ...]:
        now = self._clock.now()
        today = now.date()
        created: list[CareEvent] = []

        for band in self._config.time_bands:
            if band.start >= band.end:
                continue  # 자정 걸침(야간) — 새벽 알림 방지, docstring 참고
            if now.timetz().replace(tzinfo=None) < band.end:
                continue  # 아직 안 끝난 시간대는 판단 유보

            routine_days: dict[str, set[date]] = {}
            used_today: set[str] = set()
            for record in self._usage_log.records():
                local = record.occurred_at.astimezone(now.tzinfo)
                if not band.contains(local.timetz()):
                    continue
                purpose = record.purpose.strip()
                if local.date() == today:
                    used_today.add(purpose)
                elif record.outcome is UsageOutcome.SUCCEEDED:
                    routine_days.setdefault(purpose, set()).add(local.date())

            for purpose, days in sorted(routine_days.items()):
                if len(days) < self._config.minimum_occurrences:
                    continue
                if purpose in used_today:
                    continue
                if self._care_events.has_on_date(
                    KIND_QUIET_ROUTINE, purpose, today
                ):
                    continue
                created.append(
                    self._care_events.append(
                        KIND_QUIET_ROUTINE,
                        f"평소 {band.name} 시간대의 '{purpose}' 사용이 오늘은 "
                        "없었어요. 안부 전화 한번 어떨까요?",
                        purpose=purpose,
                    )
                )
        return tuple(created)
