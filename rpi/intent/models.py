"""Data models for usage learning and proactive suggestions."""

from dataclasses import dataclass
from datetime import datetime, time
from enum import Enum

from rpi.controller.models import ExecutionMode


class UsageSource(str, Enum):
    DIRECT = "direct"
    SUGGESTION = "suggestion"
    DEMO = "demo"
    UNKNOWN = "unknown"


class UsageOutcome(str, Enum):
    SUCCEEDED = "succeeded"
    FAILED = "failed"


@dataclass(frozen=True)
class UsageRecord:
    occurred_at: datetime
    purpose: str
    outcome: UsageOutcome
    # 어떤 가전에서 한 일인지. 같은 말도 가전이 다르면 다른 루틴이므로,
    # 패턴 제안이 대상을 들고 다니려면 여기서부터 남아야 한다.
    # 옛 이력이나 가전 개념이 없는 경로(rpi4 브리지)는 None.
    appliance_id: str | None = None
    execution_mode: ExecutionMode = ExecutionMode.UNKNOWN
    source: UsageSource = UsageSource.UNKNOWN

    def __post_init__(self) -> None:
        if not self.purpose.strip():
            raise ValueError("purpose must not be blank")
        if self.occurred_at.tzinfo is None:
            raise ValueError("occurred_at must be timezone-aware")


@dataclass(frozen=True)
class TimeBand:
    """Configured local-time band; equal bounds represent the full day."""

    name: str
    start: time
    end: time

    def __post_init__(self) -> None:
        if not self.name.strip():
            raise ValueError("time band name must not be blank")

    def contains(self, value: time) -> bool:
        local_time = value.replace(tzinfo=None)
        start = self.start.replace(tzinfo=None)
        end = self.end.replace(tzinfo=None)
        if start == end:
            return True
        if start < end:
            return start <= local_time < end
        return local_time >= start or local_time < end


@dataclass(frozen=True)
class PatternConfig:
    minimum_occurrences: int
    time_bands: tuple[TimeBand, ...]
    window_days: int = 28
    minimum_days: int = 3
    #: 습관 카드를 시간대 시작이 아니라 **평소 시각(쓴 시각의 가운데 값) 이만큼 전**부터 묻는다(2026-10-25). None이면
    #: 종전처럼 시간대 시작부터.
    ask_lead_minutes: int | None = None

    def __post_init__(self) -> None:
        if self.minimum_occurrences < 1:
            raise ValueError("minimum_occurrences must be at least 1")
        if self.window_days < 1 or not 1 <= self.minimum_days <= self.window_days:
            raise ValueError("minimum_days must be between 1 and window_days")
        if not self.time_bands:
            raise ValueError("at least one time band is required")
        names = [band.name for band in self.time_bands]
        if len(names) != len(set(names)):
            raise ValueError("time band names must be unique")


@dataclass(frozen=True)
class PatternCandidate:
    purpose: str
    time_band: str
    occurrences: int
    # 같은 가전의 기록만 모은다. 다른 가전의 횟수를 합산하지 않는다.
    appliance_id: str | None = None
    distinct_days: int = 0
    window_days: int = 28
    usual_time: str | None = None
    spread_minutes: float = 0
    window_start: str | None = None
    window_end: str | None = None
    confident: bool = True
    paused_until: datetime | None = None
    pause_reason: str | None = None
    ask_shift_minutes: int = 0
    ask_time: str | None = None
    recent_days: tuple[str, ...] = ()
    available_until: datetime | None = None
    available_from: datetime | None = None


class SuggestionStatus(str, Enum):
    PENDING = "pending"
    APPROVED = "approved"


@dataclass(frozen=True)
class ProactiveSuggestion:
    suggestion_id: str
    purpose: str
    time_band: str
    occurrences: int
    created_at: datetime
    status: SuggestionStatus = SuggestionStatus.PENDING
    # 미리보기용. 승인 전 의도 해석이 실패했거나 리졸버가 주입되지 않았으면 빈 튜플 —
    # 실제 실행 시퀀스는 approve() 시점에 다시 해석되며 이 값과 다를 수 있다.
    steps: tuple[str, ...] = ()
    # 패턴의 최근 사용일 또는 환경 상태 등 "왜 지금"의 근거.
    reason: str = ""
    # 이 제안이 조작할 가전. 화면이 그리는 버튼 지도와 실제 실행 대상이
    # 어긋나지 않게 하는 계약이다. 환경 제안은 제안기가, 패턴 제안은
    # 사용 이력이 알려준다. 둘 다 모르면(가전 없이 쌓인 옛 이력) None --
    # 그때만 클라이언트가 현재 선택 가전으로 폴백한다.
    appliance_id: str | None = None
    # 서버 시계 기준. 조회뿐 아니라 승인 시에도 검사한다.
    expires_at: datetime | None = None
    is_demo: bool = False
    revised_from: str | None = None
    #: 시나리오 제안(U1): 승인에 **그대로 묶이는** 확정 명령들(rpi.commands.Command).
    #: 비어 있으면 종전 물리 제안이다. 승인 뒤 목적을 다시 해석하지 않는다.
    commands: tuple = ()
    #: 명령마다 사용자가 본 한 줄(승인에 함께 묶인다).
    command_summaries: tuple[str, ...] = ()
    scenario_id: str | None = None
    #: 사용자 루틴(2026-09-30): 루틴 카드이거나, 습관 카드가 같은 버튼 순서의 루틴 이름을
    #: 빌려 쓸 때 채운다. 화면은 이름을 제목으로 쓴다. 실행 내용은 바뀌지 않는다.
    routine_id: str | None = None
    routine_name: str | None = None
    #: 사용자가 직접 요청해 생긴 카드(루틴 '지금 실행', 2026-10-14). 조용한 시간에도 만들고 내리지 않는다.
    user_started: bool = False
    #: 카드를 만들 때 본 대상 가전 설정(검토 10/19 #1) — ``((가전 ID, 판 번호, 보정 버전, ThinQ 기기 ID), …)``. 명령 지문은
    #: 대상 이름·동작·버튼 이름뿐이라 다시 보정하거나 ThinQ 기기를 바꿔도 같았다. 승인 때 지금 설정과 다르면 재승인.
    #: 비어 있으면(가전 목록을 모르는 실행기) 대조하지 않는다.
    target_snapshot: tuple = ()
    habit_time: str | None = None
    habit_start: datetime | None = None
    #: '왜 지금' 신호(2026-10-26) — ``((사람 말 이름, 맞음), …)``, 최대 4개. 카드를 만들 때 실제로 본 신호만(지어내지 않는다).
    signals: tuple = ()
    #: 화면·소리로 묻는 말(2026-10-26) — "제습기를 켤까요?". None이면 화면이 목적 문장에서 만든다(습관 카드).
    question: str | None = None
    #: ``action``(승인하면 실행) · ``advice``(조언 — 실행 없음, '알겠어요'·'괜찮아요'만, 2026-10-26).
    kind: str = "action"
