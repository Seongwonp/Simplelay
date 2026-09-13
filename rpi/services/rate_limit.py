"""슬라이딩 윈도 요청 빈도 제한 — 개발자 API 전용.

토큰 버킷까지 쓰지 않는 이유: 여기서 막으려는 것은 폭주한 클라이언트가
모션 명령을 초당 수백 번 쏘는 경우와 토큰 대입 시도다. "최근 N초에 몇
번"이면 충분히 설명되고, 테스트에서 시계를 쥐기도 쉽다.

시계는 단조 시계다 -- 시스템 시각을 바꿔 제한을 우회하거나 영구히
걸리게 만들 수 없다.
"""

from __future__ import annotations

import threading
import time
from collections import deque
from collections.abc import Callable


class SlidingWindowLimiter:
    """키마다 최근 ``window_s`` 동안의 기록을 ``limit``개까지만 허용한다."""

    def __init__(
        self,
        limit: int,
        window_s: float,
        *,
        monotonic: Callable[[], float] = time.monotonic,
        max_keys: int = 256,
    ) -> None:
        if limit < 1 or window_s <= 0:
            raise ValueError("limit은 1 이상, window_s는 0보다 커야 합니다")
        self._limit = limit
        self._window_s = window_s
        self._monotonic = monotonic
        # 키 수 상한 -- 임의 문자열 키(클라이언트 주소 등)로 메모리를
        # 끝없이 늘릴 수 없게 한다. 넘치면 가장 오래 안 쓰인 키부터 버린다.
        self._max_keys = max_keys
        self._hits: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    @property
    def limit(self) -> int:
        return self._limit

    def allow(self, key: str) -> bool:
        """허용되면 기록하고 True. 한도에 닿았으면 기록하지 않고 False."""
        with self._lock:
            hits = self._prune_locked(key)
            if len(hits) >= self._limit:
                return False
            hits.append(self._monotonic())
            return True

    def exceeded(self, key: str) -> bool:
        """기록 없이 한도 도달 여부만 본다(실패 횟수 잠금용)."""
        with self._lock:
            return len(self._prune_locked(key)) >= self._limit

    def record(self, key: str) -> None:
        """허용 판단 없이 기록만 한다(실패 1회 적립)."""
        with self._lock:
            self._prune_locked(key).append(self._monotonic())

    def _prune_locked(self, key: str) -> deque[float]:
        cutoff = self._monotonic() - self._window_s
        hits = self._hits.get(key)
        if hits is None:
            if len(self._hits) >= self._max_keys:
                self._evict_one_locked()
            hits = self._hits[key] = deque()
        while hits and hits[0] <= cutoff:
            hits.popleft()
        return hits

    def _evict_one_locked(self) -> None:
        oldest_key = min(
            self._hits,
            key=lambda k: self._hits[k][-1] if self._hits[k] else float("-inf"),
        )
        del self._hits[oldest_key]
