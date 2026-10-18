"""사람이 '확인함' — 못 한 일·알림을 사람이 봤다는 표시를 **본체 한 곳**에 둔다(사용자 보고 버그 2026-10-19).

왜: 폰 홈의 '못 한 일 … 기록 보기' 경고는 폰 안에만 기억하는 '알림함을 연 시점'으로만 사라졌다 — 기록을 보고 돌아와도
그대로였다. 키오스크는 '지난 일'을 '확인'하거나 '움직였어요/안 움직였어요'로 답해도 키오스크 메모리에만 남아, 폰에서는
여전히 못 한 일이었고 키오스크 가전 칸의 표시·확인 필요 안내도 다음 실행 때까지 남았다. 이제 확인은 본체에 적고 모든 기기가
같은 값을 읽는다. 새 실패가 생기면 그 일은 아직 확인 전이라 다시 뜬다.

상태 세 가지:
- ``care_seen_id``: 보호자 알림(care events)을 이 번호까지 봤다(알림함을 연 기기 — 폰). 늘기만 한다.
- ``failures_seen_until``: 이 시각(본체 시계)까지 생긴 **못 한 일** 알림(실행 실패·완료 알림 실패)은 봤다. 폰의
  '기록 보기'·키오스크의 지난 일 확인·답이 지금 시각으로 올린다. 위험 소리·비상 정지·안부 신호는 이 표시로 지우지 않는다
  (알림함을 열어야 지워진다 — 다른 실패를 확인한 것이 위험 알림까지 지우면 안 된다).
- ``job_answers``: 실행(job) 하나에 사람이 남긴 답 — ``seen``(봤다) · ``moved``(움직였다) · ``not_moved``(안 움직였다).
  최근 ``JOB_LIMIT``건만 둔다. ``seen``은 이미 남긴 답(움직임 여부)을 덮지 않는다.

``SIMPLELAY_DB_PATH``가 있으면 settings 한 칸(JSON)에 저장해 재시작 뒤에도 남는다. 없으면 메모리(개발 PC·시험).
메모리에 먼저 적용하고 저장한다 — 저장이 실패해도 이번 세션에는 적용된다(로그만 남긴다).
"""

from __future__ import annotations

import json
import logging
import threading
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime

from rpi.intent.ports import Clock

log = logging.getLogger(__name__)

SETTING_KEY = "person_acks_v1"
ANSWERS = ("seen", "moved", "not_moved")
JOB_LIMIT = 200
#: '못 한 일'로 묶는 보호자 알림 종류 — 폰 홈 경고의 '못 한 일' 갈래와 같다.
FAILURE_CARE_KINDS = frozenset({"execution_failed", "appliance_done_undelivered"})


@dataclass(frozen=True)
class AckSnapshot:
    care_seen_id: int = 0
    failures_seen_until: datetime | None = None
    job_answers: dict[str, str] = field(default_factory=dict)

    def job_acked(self, job_id: str | None) -> bool:
        return job_id is not None and job_id in self.job_answers


class PersonAckStore:
    def __init__(self, clock: Clock, db=None) -> None:
        self._clock = clock
        self._db = db
        self._lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._snap = AckSnapshot()
        if db is not None:
            self._snap = self._load(db.load_setting(SETTING_KEY))

    @staticmethod
    def _load(raw: str | None) -> AckSnapshot:
        if not raw:
            return AckSnapshot()
        try:
            data = json.loads(raw)
            until = data.get("failures_seen_until")
            answers = {
                str(k): str(v) for k, v in (data.get("job_answers") or {}).items() if v in ANSWERS
            }
            return AckSnapshot(
                care_seen_id=max(0, int(data.get("care_seen_id") or 0)),
                failures_seen_until=datetime.fromisoformat(until) if until else None,
                job_answers=answers,
            )
        except (ValueError, TypeError, AttributeError):
            # 못 읽으면 '아무것도 확인 안 함'으로 — 확인 안 한 것을 확인했다고 숨기는 쪽보다 다시 보이는 쪽이 안전하다.
            log.warning("person acks value unreadable: %r", raw)
            return AckSnapshot()

    def snapshot(self) -> AckSnapshot:
        return self._snap

    def change(
        self,
        *,
        care_seen_id: int | None = None,
        failures_seen: bool = False,
        seen_job_ids: Iterable[str] = (),
        job_id: str | None = None,
        answer: str | None = None,
    ) -> AckSnapshot:
        """한 번에 적용한다. ``failures_seen``·``answer``는 못 한 일 표시를 본체 시계의 지금까지 올린다."""
        if answer is not None and answer not in ANSWERS:
            raise ValueError(f"answer must be one of {ANSWERS}")
        if answer is not None and not job_id:
            raise ValueError("answer needs job_id")
        with self._write_lock:
            with self._lock:
                old = self._snap
                answers = dict(old.job_answers)
                for jid in seen_job_ids:
                    answers.setdefault(jid, "seen")
                if job_id is not None:
                    previous = answers.pop(job_id, None)
                    # '봤다'는 이미 남긴 움직임 답을 덮지 않는다(맨 뒤로만 옮긴다).
                    answers[job_id] = previous if answer == "seen" and previous in ("moved", "not_moved") else (
                        answer or "seen")
                while len(answers) > JOB_LIMIT:
                    answers.pop(next(iter(answers)))
                until = old.failures_seen_until
                if failures_seen or job_id is not None:
                    now = self._clock.now()
                    until = now if until is None or now > until else until
                seen = old.care_seen_id if care_seen_id is None else max(old.care_seen_id, care_seen_id)
                new = AckSnapshot(care_seen_id=seen, failures_seen_until=until, job_answers=answers)
                self._snap = new
            self._persist(new)
            return new

    def _persist(self, snap: AckSnapshot) -> None:
        if self._db is None:
            return
        try:
            self._db.save_setting(
                SETTING_KEY,
                json.dumps(
                    {
                        "care_seen_id": snap.care_seen_id,
                        "failures_seen_until": snap.failures_seen_until.isoformat()
                        if snap.failures_seen_until
                        else None,
                        "job_answers": snap.job_answers,
                    },
                    ensure_ascii=False,
                ),
            )
        except Exception:  # noqa: BLE001 - 저장 실패여도 이번 세션에는 적용된다
            log.exception("person acks save failed")
