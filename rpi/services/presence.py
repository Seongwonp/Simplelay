"""공간 존재(presence) 상태 — "지금 그 공간에 사람이 있는가"의 단일 출처.

공간 맥락 기능의 스캐폴딩: RPi4(헤드리스 카메라)에서 돌 사람 감지기가
``POST /presence``로 결과를 밀어 넣기만 하면 되도록 서버 쪽을 미리 배선해
둔다 — 실기기 날에는 감지기 프로세스(공개 tflite 모델 + 플랫폼 AI CLI)만
붙이면 끝난다.

1차 활용: **부재 중 자동 제안 보류**. 사람이 명시적으로 없다고 판정된 동안
패턴 기반 제안을 만들지 않는다 — 아무도 없는 주방에서 키오스크가 혼자
말하고 10초 뒤 사라지는 낭비(그리고 데모 중 혼선)를 막는다.

안전 설계:
- TTL: 감지기가 죽어 갱신이 끊기면 상태가 unknown(None)으로 복귀한다 —
  죽은 감지기의 마지막 '부재' 판정이 제안을 영구 차단하면 안 된다.
- unknown은 항상 허용으로 취급 — 감지기가 아예 없는 구성(기본)에서
  기존 동작과 완전히 동일하다.
- 게이팅 자체도 SIMPLELAY_PRESENCE_GATING=true일 때만 배선된다(deps).
"""

from __future__ import annotations

import threading
from dataclasses import dataclass
from datetime import datetime

from rpi.intent.ports import Clock


@dataclass(frozen=True)
class PresenceState:
    present: bool | None  # None = 알 수 없음(감지기 없음·정보 만료)
    source: str | None
    updated_at: datetime | None


class PresenceStore:
    """스레드 안전 presence 상태. FastAPI 요청 스레드(쓰기: POST /presence)와
    제안 스케줄러(읽기)가 공유한다."""

    def __init__(self, clock: Clock, ttl_seconds: float = 60.0) -> None:
        self._clock = clock
        self._ttl = ttl_seconds
        self._lock = threading.Lock()
        self._present: bool | None = None
        self._source: str | None = None
        self._updated_at: datetime | None = None

    def set_present(self, present: bool, source: str) -> None:
        with self._lock:
            self._present = present
            self._source = source
            self._updated_at = self._clock.now()

    def current(self) -> PresenceState:
        with self._lock:
            if self._updated_at is None:
                return PresenceState(None, None, None)
            age = (self._clock.now() - self._updated_at).total_seconds()
            if age > self._ttl:
                # 감지기 갱신 두절 — 마지막 판정을 신뢰하지 않는다
                return PresenceState(None, self._source, self._updated_at)
            return PresenceState(self._present, self._source, self._updated_at)

    def allows_suggestions(self) -> bool:
        """자동 제안 생성 허용 여부 — 명시적 '부재'일 때만 보류한다.
        unknown(감지기 없음·만료)은 허용: 존재 감지는 부가 기능이지
        제안 기능의 전제가 아니다."""
        return self.current().present is not False
