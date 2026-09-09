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
from datetime import date, datetime, timedelta

from typing import Protocol

from rpi.intent.models import PatternConfig, UsageOutcome
from rpi.intent.ports import Clock, UsageLog

KIND_EXECUTION_FAILED = "execution_failed"
KIND_EMERGENCY_STOP = "emergency_stop"
KIND_DANGER_SOUND = "danger_sound"
KIND_QUIET_ROUTINE = "quiet_routine"


# "평소"의 기준 창 — 이 기간 안에서 3일 이상 쓴 것만 루틴이다. 창이 없으면
# 겨울에 사흘 쓴 가습기가 여름에도 매일 안부 신호를 만든다(교차 리뷰 #12).
ROUTINE_WINDOW_DAYS = 14


@dataclass(frozen=True)
class CareEvent:
    event_id: int
    kind: str
    message: str
    occurred_at: datetime
    purpose: str | None = None
    # 안부 신호의 시간대 등 — 같은 purpose가 아침·저녁 두 루틴일 때 각각
    # 알리기 위한 dedupe 구성요소 (교차 리뷰 #9). API 응답에는 안 실린다.
    time_band: str | None = None


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
        self,
        kind: str,
        message: str,
        purpose: str | None = None,
        time_band: str | None = None,
    ) -> CareEvent:
        with self._lock:
            occurred_at = self._clock.now()
            if self._db is not None:
                event_id = self._db.append_care_event(
                    kind, message, purpose, occurred_at, time_band
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
                time_band=time_band,
            )
            self._memory.append(event)
            return event

    def recent(self, limit: int = 50) -> tuple[CareEvent, ...]:
        """최신순. 인메모리 링(최근 MEMORY_LIMIT건)에서 답한다 — 보호자
        알림함은 '최근에 무슨 일이 있었나'가 목적이라 이 폭이면 충분하다."""
        with self._lock:
            return tuple(reversed(list(self._memory)))[:limit]

    def has_on_date(
        self,
        kind: str,
        purpose: str | None,
        day: date,
        time_band: str | None = None,
    ) -> bool:
        """같은 날 같은 (kind, purpose, time_band) 이벤트가 이미 있나 —
        안부 신호가 60초 주기 체크마다 반복 발생하는 것을 막는 dedupe 열쇠.

        DB가 있으면 DB에서 묻는다 (교차 리뷰 #10): 메모리 링(200건)만 보면
        하루에 이벤트가 많이 쌓인 날 오전 신호가 링에서 밀려나 같은 신호가
        또 만들어지고, 재시작 직후에도 같은 구멍이 생긴다."""
        with self._lock:
            if self._db is not None:
                return self._db.care_event_exists_on(
                    kind, purpose, day, time_band
                )
            return any(
                e.kind == kind
                and e.purpose == purpose
                and e.time_band == time_band
                and e.occurred_at.date() == day
                for e in self._memory
            )


class WellnessPauseStore(Protocol):
    """일시 중지를 재시작 뒤에도 기억하는 곳 (실기기는 SQLite)."""

    def load_wellness_pause(self) -> date | None: ...

    def save_wellness_pause(self, until: date | None) -> None: ...


class WellnessPause:
    """안부 확인을 며칠 쉰다 — 집을 비운 것을 **아는** 날들.

    여행·입원·자녀 집에 며칠. 그 사이에도 안부 신호는 그대로 울리고, 보호자는
    이미 알고 있는 일로 알림을 받는다. 그런 알림이 며칠 이어지면 정작 진짜
    신호가 왔을 때 무시하게 된다 -- 안부 기능이 스스로를 무디게 만든다.

    **제안 DND와는 다른 것이다.** DND는 "지금 말 걸지 마"이고 이건 "며칠간
    조용한 게 정상이다"이다. 하나로 묶으면 방해 금지 30분이 안부 확인까지
    꺼버리거나, 여행 일주일이 제안까지 막는다.

    무기한은 두지 않는다. 꺼둔 것을 잊으면 안부 기능이 **있는 채로 없는 것과
    같아진다** -- 종료 날짜를 반드시 받고, 그날이 지나면 스스로 풀린다.
    상한도 여기에서 건다: 화면의 날짜 선택기만 막으면 그 규칙은 **화면에만**
    있는 것이라, 키오스크나 직접 호출은 10년짜리 일시 중지를 만들 수 있다.

    쉬는 것은 안부 신호뿐이다. 실행 실패·위험소리·긴급정지는 그대로 간다:
    사람이 집을 비웠다는 것은 조용한 것이 정상이라는 뜻이지, 가전이 고장 나도
    된다는 뜻이 아니다.
    """

    #: 한 번에 쉴 수 있는 최대 일수. "무기한은 두지 않는다"를 계약으로
    #: 만드는 값이다 -- 상한이 없으면 2099년까지 쉬는 것이 곧 무기한이다.
    MAX_DAYS = 90

    def __init__(
        self,
        until: date | None = None,
        store: "WellnessPauseStore | None" = None,
    ) -> None:
        self._store = store
        # 재시작해도 쉬는 상태가 남아야 한다. 메모리에만 두면 여행
        # 이틀째 기기가 재부팅되는 것만으로 남은 닷새 동안 알림이
        # 다시 오고, 그게 바로 이 기능이 없애려던 상황이다.
        if until is None and store is not None:
            until = store.load_wellness_pause()
        self._until = until

    @property
    def until(self) -> date | None:
        return self._until

    def is_active(self, today: date) -> bool:
        """종료 날짜 **당일도 포함**한다 -- "오늘까지 여행"이 자연스러운 말이다."""
        return self._until is not None and today <= self._until

    def set_until(self, until: date, today: date) -> None:
        if until < today:
            # 이미 지난 날짜로 쉬게 하면 아무 일도 안 일어나는데 화면은
            # "쉬는 중"이라고 말하게 된다.
            raise ValueError("until must not be in the past")
        if until > today + timedelta(days=self.MAX_DAYS):
            raise ValueError(
                f"until must be within {self.MAX_DAYS} days"
            )
        self._until = until
        self._persist()

    def clear(self) -> None:
        self._until = None
        self._persist()

    def _persist(self) -> None:
        if self._store is not None:
            self._store.save_wellness_pause(self._until)


class RoutineQuietChecker:
    """안부 신호 — "평소 그 시간대에 쓰던 가전이 오늘 조용하다"의 감지.

    규칙(전부 설명 가능한 임계값):
    - 루틴 판정: 과거(오늘 제외) 같은 시간대에 성공 사용이 서로 다른 날짜로
      ``minimum_occurrences``일 이상 — 패턴 제안과 같은 기준을 공유한다.
    - 조용함 판정: 그 시간대가 오늘 이미 끝났는데, 오늘 그 시간대에 해당
      purpose 사용 기록(성공·실패 불문 — 시도 자체가 활동 신호)이 없음.
    - 자정을 넘는 시간대(야간 등)는 제외한다: "어제 밤 루틴이 조용했다"는
      알림이 새벽에 도착하는 것은 안부 확인이 아니라 불안 유발이다.
    - 루틴은 최근 ROUTINE_WINDOW_DAYS(14일) 안의 사용만 인정 — 계절 지난
      루틴이 평생 알림을 만드는 것을 막는다 (교차 리뷰 #12).
    - 하루에 (purpose, 시간대)당 1회만 발생. 시간대가 dedupe 열쇠에
      포함되므로 아침·저녁 두 루틴은 각각 알린다 (교차 리뷰 #9).
    """

    def __init__(
        self,
        usage_log: UsageLog,
        clock: Clock,
        config: PatternConfig,
        care_events: CareEventStore,
        pause: "WellnessPause | None" = None,
    ) -> None:
        self._usage_log = usage_log
        self._clock = clock
        self._config = config
        self._care_events = care_events
        # 집을 비운 것을 아는 날에는 쉰다. None이면 항상 확인한다.
        self._pause = pause

    def check(self) -> tuple[CareEvent, ...]:
        now = self._clock.now()
        today = now.date()
        if self._pause is not None and self._pause.is_active(today):
            # 조용한 것이 정상인 날이다. 실패·위험소리 알림은 이
            # 게이트를 지나지 않으므로 그대로 간다.
            return ()
        window_start = today - timedelta(days=ROUTINE_WINDOW_DAYS)
        created: list[CareEvent] = []

        # 이력은 한 번만 읽고 현지화도 한 번만 — 시간대마다 전체 records()를
        # 다시 돌면 이력이 쌓일수록 60초 주기 루프가 무거워진다(교차 리뷰 #11).
        localized = [
            (record, record.occurred_at.astimezone(now.tzinfo))
            for record in self._usage_log.records()
        ]

        for band in self._config.time_bands:
            if band.start >= band.end:
                continue  # 자정 걸침(야간) — 새벽 알림 방지, docstring 참고
            if now.timetz().replace(tzinfo=None) < band.end:
                continue  # 아직 안 끝난 시간대는 판단 유보

            routine_days: dict[str, set[date]] = {}
            used_today: set[str] = set()
            for record, local in localized:
                if not band.contains(local.timetz()):
                    continue
                purpose = record.purpose.strip()
                if local.date() == today:
                    used_today.add(purpose)
                elif (
                    record.outcome is UsageOutcome.SUCCEEDED
                    and local.date() >= window_start  # 최근 창 안의 루틴만
                ):
                    routine_days.setdefault(purpose, set()).add(local.date())

            for purpose, days in sorted(routine_days.items()):
                if len(days) < self._config.minimum_occurrences:
                    continue
                if purpose in used_today:
                    continue
                if self._care_events.has_on_date(
                    KIND_QUIET_ROUTINE, purpose, today, time_band=band.name
                ):
                    continue
                created.append(
                    self._care_events.append(
                        KIND_QUIET_ROUTINE,
                        f"평소 {band.name} 시간대의 '{purpose}' 사용이 오늘은 "
                        "없었어요. 안부 전화 한번 어떨까요? "
                        "외출·여행 중이시라면 무시하셔도 돼요.",
                        purpose=purpose,
                        time_band=band.name,
                    )
                )
        return tuple(created)
