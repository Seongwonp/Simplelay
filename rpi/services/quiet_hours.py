"""조용한 시간(2026-10-14, 사용자 승인 5번 — 정책 b '건너뛰기').

매일 정해진 시간대(사용자 설정, 기본 꺼짐·22:00~07:00)와 기존 '제안 잠시 쉬기'(1·2시간)를 한 판정으로 묶는다.
조용한 동안 쉬는 것(실제 범위만 말한다 — '모든 알림이 조용해진다'고 하지 않는다):

- 새 제안 카드(습관·환경·시나리오·루틴 시각/다가옴/끝난 뒤 트리거). 떠 있던 카드는 내린다(쌓인 제안을 나중에 한꺼번에 알리지 않는다).
- 일반 안내 소리 — 제안 도착 낭독·자동 실행 결과 낭독(키오스크).
- **아직 시작하지 않은 자동 실행** — 그 시간에 온 사건은 건너뛰고 기록에 남긴다("조용한 시간이라 자동 실행하지 않았어요").
  시간이 끝나도 다시 실행하지 않는다(사건은 처리한 것으로 남는다).

그대로인 것: 사용자가 직접 요청한 실행(직접 실행·루틴 '지금 실행' 카드와 그 승인), 정지 조작, 이미 진행 중인 작업, 실패·정지 상태의
화면·기록 표시, 비상정지·실패·위험 신호 소리(정책 미정 — 기존 동작 유지, 사용자 확인 필요).
"""

from __future__ import annotations

import json
import logging
import re
import threading
from datetime import datetime, time as dtime

log = logging.getLogger(__name__)

SETTING_KEY = "quiet_hours"
DEFAULT = {"enabled": False, "start": "22:00", "end": "07:00"}
SKIP_REASON = "조용한 시간이라 자동 실행하지 않았어요"
SCOPE_TEXT = "새 제안과 일반 안내 소리만 쉬어요. 아직 시작하지 않은 자동 실행은 건너뛰고 나중에 다시 하지 않아요."

_HHMM = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


class QuietHoursError(ValueError):
    """설정 값이 맞지 않는다. 메시지는 화면에 보일 문장(422)."""


def _parse(value) -> dtime:
    if not isinstance(value, str) or not _HHMM.fullmatch(value.strip()):
        raise QuietHoursError("시각은 22:00처럼 24시간 형식으로 적어 주세요")
    hour, minute = value.strip().split(":")
    return dtime(int(hour), int(minute))


def window_contains(start: str, end: str, now: datetime) -> bool:
    s, e = _parse(start), _parse(end)
    t = now.time().replace(second=0, microsecond=0, tzinfo=None)
    if s < e:
        return s <= t < e
    return t >= s or t < e  # 자정을 넘는 시간대(22:00~07:00)


class QuietHours:
    """설정은 서버에 영속(DB 설정 키 하나), 재시작 뒤 유지. DB가 없으면 메모리."""

    def __init__(self, load=None, save=None) -> None:
        self._save = save
        self._lock = threading.Lock()
        self._settings = dict(DEFAULT)
        if load is not None:
            try:
                raw = load()
                data = json.loads(raw) if raw else None
                if isinstance(data, dict):
                    self._settings = self._validated(data)
            except (ValueError, TypeError):
                log.exception("quiet hours setting unreadable; using default (off)")

    @staticmethod
    def _validated(data: dict) -> dict:
        enabled = data.get("enabled")
        if not isinstance(enabled, bool):
            raise QuietHoursError("켜기/끄기 값은 true 또는 false로 보내 주세요")
        start, end = data.get("start"), data.get("end")
        _parse(start), _parse(end)
        if start.strip() == end.strip():
            raise QuietHoursError("시작과 끝 시각이 같아요")
        return {"enabled": enabled, "start": start.strip(), "end": end.strip()}

    def settings(self) -> dict:
        with self._lock:
            return dict(self._settings)

    def update(self, body) -> dict:
        if not isinstance(body, dict):
            raise QuietHoursError("설정 형식이 맞지 않아요")
        settings = self._validated({**self.settings(), **body})
        with self._lock:
            if self._save is not None:
                self._save(json.dumps(settings, ensure_ascii=False))
            self._settings = settings
        return dict(settings)

    def schedule_active(self, now: datetime) -> bool:
        s = self.settings()
        return bool(s["enabled"]) and window_contains(s["start"], s["end"], now)

    def status(self, now: datetime, pause_until: datetime | None) -> dict:
        """폰·키오스크가 같은 상태를 보이도록 하나의 모양으로. ``reason``: schedule(매일 시간대)·pause(잠시 쉬기)·None."""
        s = self.settings()
        schedule = bool(s["enabled"]) and window_contains(s["start"], s["end"], now)
        paused = pause_until is not None and now < pause_until
        return {**s, "active": schedule or paused,
                "reason": "schedule" if schedule else "pause" if paused else None,
                "pause_until": pause_until.isoformat() if paused else None,
                "scope": SCOPE_TEXT}
