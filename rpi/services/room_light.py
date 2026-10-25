"""방 밝기 판단(2026-10-26) — 키오스크 '자동' 화면 밝기(밝게·어둡게)가 읽는다.

본체 감지기가 2초마다 16x12 회색 한 장(192바이트)을 파일에 덮어쓴다. 여기서는 그 평균 밝기를 30초 동안
모아 평균을 내고, 두 문턱 사이(히스테리시스)에서는 이전 판단을 지킨다 — 화면이 깜빡이지 않게.
문턱은 웹캠 자동 노출 때문에 한 번 잰 값에서 고른 **추측**이다(켜짐 130~170, 꺼짐 100~120 — 측정 필요).
영상은 저장하지 않는다. 평균 숫자만 메모리에 둔다.
"""

from __future__ import annotations

import os
import time
from collections import deque
from dataclasses import dataclass
from typing import Callable

DARK = "dark"
LIGHT = "light"
UNKNOWN = "unknown"

FRAME_BYTES = 16 * 12


def read_level(path: str, now: float | None = None, stale_s: float = 20.0) -> int | None:
    """파일의 평균 밝기(0~255). 없거나 크기가 다르거나 오래됐으면(stale_s 초과) None."""
    try:
        st = os.stat(path)
        if (now if now is not None else time.time()) - st.st_mtime > stale_s:
            return None
        with open(path, "rb") as f:
            data = f.read(FRAME_BYTES + 1)
    except OSError:
        return None
    if len(data) != FRAME_BYTES:
        return None
    return round(sum(data) / FRAME_BYTES)


@dataclass(frozen=True)
class LightSnapshot:
    state: str
    level: int | None


class RoomLight:
    """밝기 표본 → 30초 이동 평균 → 히스테리시스 판단. 마지막 표본이 오래되면 '모름'."""

    def __init__(
        self,
        dark_below: float = 115.0,
        light_above: float = 135.0,
        window_s: float = 30.0,
        stale_s: float = 20.0,
        now: Callable[[], float] = time.monotonic,
    ) -> None:
        self.dark_below = dark_below
        self.light_above = light_above
        self.window_s = window_s
        self.stale_s = stale_s
        self._now = now
        self._samples: deque[tuple[float, int]] = deque()
        self._state = UNKNOWN  # 마지막으로 정한 밝음·어두움(모름일 때 되살릴 이전 값은 두지 않는다)

    def observe(self, level: int | None) -> str | None:
        """표본 하나(None = 읽지 못함). 판단이 바뀌면 새 상태, 아니면 None."""
        t = self._now()
        if level is not None:
            self._samples.append((t, int(level)))
        while self._samples and t - self._samples[0][0] > self.window_s:
            self._samples.popleft()
        before = self._state
        snap = self.snapshot()
        if snap.level is None:
            self._state = UNKNOWN
        elif snap.level < self.dark_below:
            self._state = DARK
        elif snap.level > self.light_above:
            self._state = LIGHT
        # 문턱 사이: 이전 판단 유지. 이전이 '모름'이면 아직 정하지 않는다.
        return self._state if self._state != before else None

    def _mean(self) -> int | None:
        t = self._now()
        if not self._samples or t - self._samples[-1][0] > self.stale_s:
            return None
        recent = [v for ts, v in self._samples if t - ts <= self.window_s]
        return round(sum(recent) / len(recent)) if recent else None

    def snapshot(self) -> LightSnapshot:
        level = self._mean()
        if level is None:
            return LightSnapshot(UNKNOWN, None)
        return LightSnapshot(self._state, level)
