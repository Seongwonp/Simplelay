"""방 안 사람 감지(카메라) → '있음·자리 비움·외출·돌아옴' 판단(2026-10-25).

본체에서 도는 온디바이스 사람 감지기가 2초마다 사람 수를 작은 JSON 파일로 바꿔 쓴다
(``{"ts": 초, "persons": n, "best": 점수, "frames": 번호}``). 사진은 저장하지 않는다 —
여기서 읽는 것은 사람 수뿐이다.

판단 규칙(값은 설정, 기본은 추측 — 실측으로 조정):
- 보이면 **있음**. 한 장면만 보이고 사라지는 오탐에 화면이 깨지 않게, 비어 있던 방에서는
  **연속 ``arrive_frames``장**에 사람이 있어야 돌아온 것으로 본다.
- ``dim_after_s`` 동안 안 보이면 **자리 비움** — 키오스크 화면만 어둡게(손대면 켜진다).
- ``away_after_s`` 동안 안 보이면 **외출** — 카메라 한 대로는 '나간 순간'을 알 수 없어 오래 안 보인 것으로 본다.
- 파일이 없거나 ``stale_s``보다 오래됐으면 **모름** — 감지기가 죽었을 때 화면을 끄지 않는다.

이 판단은 화면·인사·제안까지만 쓴다. 가전 조작(승인·누름)은 이 신호로 하지 않는다 — 오탐이 물리 조작이 되면 안 된다.
"""

from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass
from typing import Callable

UNKNOWN = "unknown"
PRESENT = "present"
IDLE = "idle"
AWAY = "away"


@dataclass(frozen=True)
class RoomSnapshot:
    state: str
    persons: int
    last_seen_at: float | None
    arrived_at: float | None
    changed_at: float | None
    arrived_from: str | None = None  # 돌아오기 전 상태(idle 자리 비움 · away 외출) — 인사 문장을 가른다
    greet: bool = False  # 이 돌아옴에 인사할까 — 오래 비웠다 왔고(외출), 최근 몇 시간 안에 인사하지 않았을 때만


class RoomPresence:
    def __init__(
        self,
        *,
        now: Callable[[], float] = time.time,
        arrive_frames: int = 3,
        dim_after_s: float = 600.0,
        away_after_s: float = 3600.0,
        stale_s: float = 20.0,
        greet_gap_s: float = 3 * 3600.0,
    ) -> None:
        self._now = now
        self.arrive_frames = max(1, arrive_frames)
        self.dim_after_s = dim_after_s
        self.away_after_s = max(away_after_s, dim_after_s)
        self.stale_s = stale_s
        self.greet_gap_s = greet_gap_s
        self._greet = False
        self._last_greet: float | None = None
        self._lock = threading.Lock()
        self._state = UNKNOWN
        self._persons = 0
        self._last_seen: float | None = None
        self._arrived: float | None = None
        self._changed: float | None = None
        self._arrived_from: str | None = None
        self._streak = 0
        self._last_frame: object = None

    def observe(self, reading: dict | None) -> str | None:
        """감지기 한 줄을 반영한다. 상태가 바뀌면 새 상태를, 아니면 None."""
        now = self._now()
        with self._lock:
            before = self._state
            fresh = (
                isinstance(reading, dict)
                and isinstance(reading.get("ts"), (int, float))
                and now - float(reading["ts"]) <= self.stale_s
            )
            if not fresh:
                self._streak = 0
                self._persons = 0
                self._set(UNKNOWN, now)
                return self._state if self._state != before else None
            frame = reading.get("frames", reading.get("ts"))
            if frame == self._last_frame:  # 같은 장면을 두 번 세지 않는다
                self._settle(now)
                return self._state if self._state != before else None
            self._last_frame = frame
            persons = int(reading.get("persons") or 0)
            self._persons = persons
            if persons > 0:
                self._streak += 1
                if self._state == PRESENT or self._streak >= self.arrive_frames:
                    self._last_seen = now
                    if self._state in (IDLE, AWAY):
                        self._arrived = now
                        self._arrived_from = self._state
                        # 잠깐 자리 비움에서 돌아오면 화면만 켜고 말하지 않는다(10/25 사용자 — 찍힐 때마다 인사는 이상하다).
                        self._greet = self._state == AWAY and (
                            self._last_greet is None or now - self._last_greet >= self.greet_gap_s)
                        if self._greet:
                            self._last_greet = now
                    self._set(PRESENT, now)
            else:
                self._streak = 0
            self._settle(now)
            return self._state if self._state != before else None

    def _settle(self, now: float) -> None:
        if self._last_seen is None:
            # 켜진 뒤 아직 한 번도 확실히 못 봤다 — 비어 있는 방으로 시작한다(돌아오면 인사).
            if self._state == UNKNOWN:
                self._set(IDLE, now)
            return
        gone = now - self._last_seen
        if gone >= self.away_after_s:
            self._set(AWAY, now)
        elif gone >= self.dim_after_s:
            self._set(IDLE, now)

    def _set(self, state: str, now: float) -> None:
        if state != self._state:
            self._state = state
            self._changed = now

    def snapshot(self) -> RoomSnapshot:
        with self._lock:
            return RoomSnapshot(self._state, self._persons, self._last_seen, self._arrived, self._changed,
                                self._arrived_from, self._greet)


def greeting_for(when, name: str | None = None) -> str:
    """오래 비웠다 돌아왔을 때 한 줄 인사(10/25 사용자 표). 평일 저녁은 하루를 위로하고, 주말·일요일 저녁은 따로.

    ``when``은 돌아온 시각(지역 시각 datetime). 이름이 있으면 앞에 '○○님,'."""
    hour = when.hour
    weekend = when.weekday() >= 5
    if 5 <= hour < 10:
        line = "좋은 주말 아침이에요." if weekend else "좋은 아침이에요."
    elif 10 <= hour < 17:
        line = "주말 잘 보내고 계세요?" if weekend else "어서 오세요."
    elif 17 <= hour < 23:
        if when.weekday() == 6:
            line = "내일부터 또 한 주예요. 오늘은 푹 쉬세요."
        elif weekend:
            line = "즐거운 주말 보내셨어요? 편히 쉬세요."
        else:
            line = "오늘 하루도 고생 많으셨어요!"
    else:
        line = "늦었네요. 푹 쉬세요." if weekend else "늦게까지 고생 많으셨어요. 푹 쉬세요."
    return f"{name}님, {line}" if name else line


def read_reading(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None
