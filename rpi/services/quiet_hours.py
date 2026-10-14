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
from datetime import datetime, time as dtime
from types import MappingProxyType

from rpi.services.snapshot_setting import SnapshotSetting

log = logging.getLogger(__name__)

SETTING_KEY = "quiet_hours"
DEFAULT = {"enabled": False, "start": "22:00", "end": "07:00"}
SKIP_REASON = "조용한 시간이라 자동 실행하지 않았어요"
SCOPE_TEXT = "새 제안과 일반 안내 소리만 쉬어요. 아직 시작하지 않은 자동 실행은 건너뛰고 나중에 다시 하지 않아요."
#: 업데이트 전에 켠 잠시 쉬기를 이어받은 동안(옛 범위) — 자동 실행은 막지 않는다(2026-10-14 마감 2번).
CARRIED_PAUSE_SCOPE_TEXT = "업데이트 전에 켠 잠시 쉬기라 새 제안과 일반 안내 소리만 쉬어요. 자동 실행은 그대로예요."

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
    """설정은 서버에 영속(DB 설정 키 하나), 재시작 뒤 유지. DB가 없으면 메모리.

    HIGH 재확인 H-R1(2026-10-14): 판정용 메모리 사본(불변 교체)과 영속 쓰기를 나눴다 — ``settings``는 잠금 없이 읽고,
    바꾸기는 메모리에 먼저 적용한 뒤 저장 잠금에서 DB에 쓴다(``SnapshotSetting``). 자동 실행의 시작 게이트(서비스 잠금
    안)와 전송권 확인(실행기 잠금 안)이 다른 요청의 DB 저장을 기다리지 않는다. 저장 실패면 이번 세션에만 적용되고,
    재시작하면 마지막으로 저장에 성공한 값으로 시작한다.
    """

    def __init__(self, load=None, save=None) -> None:
        self._state = SnapshotSetting(MappingProxyType(dict(DEFAULT)), save=save,
                                      encode=lambda s: json.dumps(dict(s), ensure_ascii=False),
                                      name="quiet hours")
        if load is not None:
            try:
                raw = load()
                data = json.loads(raw) if raw else None
                if isinstance(data, dict):
                    self._state.load(MappingProxyType(self._validated(data)))
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
        """지금 설정 — 잠금 없음(불변 사본). 실행 게이트·전송권 확인 안에서도 부른다."""
        return dict(self._state.value)

    def apply(self, body) -> tuple[dict, int]:
        """메모리에 바로 적용한다(입출력 없음). 일부 값만 보내도 지금 사본과 합쳐 검사한다 — 합치기·검사·교체가 한 번의
        메모리 잠금 안이라 동시에 온 두 변경이 서로를 잃지 않는다. (새 설정, 판 번호). 잘못된 값이면 바뀌지 않는다."""
        if not isinstance(body, dict):
            raise QuietHoursError("설정 형식이 맞지 않아요")
        new, version = self._state.change(lambda cur: MappingProxyType(self._validated({**cur, **body})))
        return dict(new), version

    def persist(self, version: int | None = None) -> bool | None:
        """DB 저장 — True 저장됨 · False 실패(이번 세션만 적용) · None 저장소 없음. 이벤트 루프 밖에서 부른다."""
        return self._state.persist(version)

    def persist_report(self, version: int | None = None) -> tuple[bool | None, dict]:
        """``persist``와 같고, 그 결과가 가리키는 설정 사본을 함께 — (결과, 그 사본). 응답은 이 사본과 결과를 같이
        싣는다(HIGH 재확인 2차 M-RR2: 저장을 기다리는 사이 다른 요청이 바꾼 지금 값에 이 결과를 붙이지 않는다)."""
        outcome = self._state.persist_report(version)
        return outcome.result, dict(outcome.value)

    def update(self, body) -> dict:
        """메모리 적용 + 저장(같은 스레드) — 호환용. API는 ``apply``·``persist``를 나눠 저장 결과를 응답에 싣는다."""
        settings, version = self.apply(body)
        self.persist(version)
        return settings

    def schedule_active(self, now: datetime) -> bool:
        s = self.settings()
        return bool(s["enabled"]) and window_contains(s["start"], s["end"], now)

    def status(self, now: datetime, pause_until: datetime | None, pause_scope: str | None = None,
               settings: dict | None = None) -> dict:
        """폰·키오스크가 같은 상태를 보이도록 하나의 모양으로. ``reason``: schedule(매일 시간대)·pause(잠시 쉬기)·None.

        ``pause_scope``: 잠시 쉬기 범위(``suggestions_and_auto``·``suggestions_only``). 이어받은 옛 범위 잠시 쉬기만
        켜져 있으면 ``scope`` 문장도 그 범위(자동 실행은 그대로)로 말한다.
        ``settings``: 지금 값 대신 이 설정 사본으로 계산한다(``PUT`` 응답 — ``persist_report``가 돌려준 사본).
        """
        s = dict(settings) if settings is not None else self.settings()
        schedule = bool(s["enabled"]) and window_contains(s["start"], s["end"], now)
        paused = pause_until is not None and now < pause_until
        carried_only = paused and not schedule and pause_scope == "suggestions_only"
        return {**s, "active": schedule or paused,
                "reason": "schedule" if schedule else "pause" if paused else None,
                "pause_until": pause_until.isoformat() if paused else None,
                "pause_scope": pause_scope if paused else None,
                "scope": CARRIED_PAUSE_SCOPE_TEXT if carried_only else SCOPE_TEXT}
