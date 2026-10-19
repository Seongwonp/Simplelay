"""사람이 '확인함' — 못 한 일·알림을 사람이 봤다는 표시를 **본체 한 곳**에 둔다(사용자 보고 버그 2026-10-19).

왜: 폰 홈의 '못 한 일 … 기록 보기' 경고는 폰 안에만 기억하는 '알림함을 연 시점'으로만 사라졌다 — 기록을 보고 돌아와도
그대로였다. 키오스크는 '지난 일'을 '확인'하거나 '움직였어요/안 움직였어요'로 답해도 키오스크 메모리에만 남아, 폰에서는
여전히 못 한 일이었고 키오스크 가전 칸의 표시·확인 필요 안내도 다음 실행 때까지 남았다. 이제 확인은 본체에 적고 모든 기기가
같은 값을 읽는다. 새 실패가 생기면 그 일은 아직 확인 전이라 다시 뜬다.

## ``/acks`` 계약 (검토 2026-10-19 #2·#3·#4·#10 반영 — 바뀐 점)

사람이 **실제로 본 것만** '봤다'로 적는다. 예전 계약은 (a) 실행 하나에 답해도 그 순간까지의 모든 못 한 일을 '봤다'로 올렸고,
(b) 폰 '기록 보기'는 폰이 받아 오지 않은 실패·실행까지 '봤다'로 적었고, (c) 기준이 본체 시계라 RTC 없는 본체의 시계가
뒤로 가면 새 실패가 처음부터 숨었다.

``POST /acks`` 요청(하나 이상):

- ``care_seen_id``: 알림함을 연 기기가 본 가장 새 알림 번호(종전 그대로).
- ``failures_seen_id``: 화면에 보인 **못 한 일 알림의 가장 새 번호**(보호자 알림 번호, 늘기만 하는 DB 번호). 이 번호까지의
  못 한 일만 '봤다'. 본체에 있는 가장 새 번호를 넘지 않게 줄인다.
- ``seen_job_ids``: 화면에 보인 실행 기록 번호 목록(최대 ``JOB_LIMIT``) — 그 번호만 '봤다'.
- ``seen_until_job_id``: 화면에 보인 **가장 새 실행 기록 번호** — 그 기록과 그보다 오래된 최근 기록만 '봤다'.
  본체 기록에 없는 번호면 아무 실행도 적지 않는다.
- ``failures_seen: true``(옛 폰, 호환): 위 커서가 함께 오면 그 커서까지만. 커서가 없으면 종전처럼 본체에 있는 가장 새 못 한 일
  알림·최근 실행 기록 전체까지(옛 앱의 동작 — 새 앱은 커서를 싣는다).
- ``job_id`` + ``answer``(seen·moved·not_moved): **그 실행 하나만** 바꾼다. 못 한 일 표시(``failures_seen_id``)는 건드리지 않는다
  (다른 실행의 실패를 아무도 안 봤는데 사라지면 안 된다).

응답(``GET``·``POST`` 같음):

- ``care_seen_id``: int — 종전 그대로.
- ``failures_seen_id``: int — 이 번호까지의 못 한 일 알림(``FAILURE_CARE_KINDS``)은 봤다. **새 기준**(번호 비교, 시계 무관).
- ``failures_seen_until``: 시각 | null — 옛 앱 호환용 파생값. 저장하지 않고 응답마다 알림 목록으로 만든다: 본 알림 중 가장 늦은
  시각과, 아직 안 본 못 한 일 알림 중 가장 이른 시각 바로 앞 중 **이른 쪽**. 시계가 뒤로 가도 안 본 실패를 덮지 않는다(본 것이
  다시 보이는 쪽으로만 틀린다).
- ``job_answers``: 실행 번호 → 답(최근 ``JOB_LIMIT``건). 여러 단계 실행의 기록 번호(``base-N``)를 적으면 ``/status``의 실행 번호
  (``base``)도 '봤다'로 함께 적는다(키오스크 가전 칸 표시가 같은 확인으로 내려가게, #10).

저장값: settings 한 칸(JSON) — ``care_seen_id``·``failures_seen_id``·``job_answers``. 옛 저장값의 ``failures_seen_until``(시각)은
읽지 않는다(번호로 바꿀 수 없다 — 배포 뒤 한 번 옛 못 한 일이 다시 보일 수 있다. 숨기는 쪽보다 다시 보이는 쪽이 안전하다).

위험 소리·비상 정지·안부 신호는 못 한 일 표시로 지우지 않는다(알림함을 열어야 지워진다 — 다른 실패를 확인한 것이 위험
알림까지 지우면 안 된다). ``seen``은 이미 남긴 답(움직임 여부)을 덮지 않는다.

``SIMPLELAY_DB_PATH``가 있으면 저장해 재시작 뒤에도 남는다. 없으면 메모리(개발 PC·시험).
메모리에 먼저 적용하고 저장한다 — 저장이 실패해도 이번 세션에는 적용된다(로그만 남긴다).
"""

from __future__ import annotations

import json
import logging
import re
import threading
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from rpi.intent.ports import Clock

log = logging.getLogger(__name__)

SETTING_KEY = "person_acks_v1"
ANSWERS = ("seen", "moved", "not_moved")
JOB_LIMIT = 200
#: '못 한 일'로 묶는 보호자 알림 종류 — 폰 홈 경고의 '못 한 일' 갈래와 같다.
FAILURE_CARE_KINDS = frozenset({"execution_failed", "appliance_done_undelivered"})
#: 여러 단계 실행의 기록 번호 — ``<실행 번호 12자리 16진>-<단계>``(``service_commands._history_job_id``).
_STEP_JOB_ID = re.compile(r"^([0-9a-f]{12})-\d+$")


def base_job_id(job_id: str) -> str | None:
    """여러 단계 실행의 기록 번호(``base-N``)면 ``/status``의 실행 번호(``base``), 아니면 None."""
    m = _STEP_JOB_ID.match(job_id)
    return m.group(1) if m else None


@dataclass(frozen=True)
class AckSnapshot:
    care_seen_id: int = 0
    #: 이 보호자 알림 번호까지의 못 한 일은 봤다(번호 — 본체 시계와 무관하게 늘기만 한다).
    failures_seen_id: int = 0
    job_answers: dict[str, str] = field(default_factory=dict)

    def job_acked(self, job_id: str | None) -> bool:
        return job_id is not None and job_id in self.job_answers

    def failure_covered(self, event_id: int, kind: str) -> bool:
        """이 보호자 알림을 사람이 봤나(알림함 또는 못 한 일 표시)."""
        if event_id <= self.care_seen_id:
            return True
        return kind in FAILURE_CARE_KINDS and event_id <= self.failures_seen_id


def legacy_failures_seen_until(snap: AckSnapshot, events: Iterable) -> datetime | None:
    """옛 앱 호환용 ``failures_seen_until``(시각) — 저장하지 않고 알림 목록(``event_id``·``kind``·``occurred_at``)으로 만든다.

    옛 앱은 ``occurred_at <= until``이면 못 한 일을 '봤다'로 본다. 본 알림 중 가장 늦은 시각과, 아직 안 본 못 한 일 중 가장 이른
    시각 바로 앞 중 이른 쪽을 준다 — 시계가 뒤로 가 안 본 실패의 시각이 더 이르더라도 덮지 않는다."""
    if snap.failures_seen_id <= 0:
        return None
    seen_latest: datetime | None = None
    unseen_earliest: datetime | None = None
    for e in events:
        if e.event_id <= snap.failures_seen_id:
            if seen_latest is None or e.occurred_at > seen_latest:
                seen_latest = e.occurred_at
        elif e.kind in FAILURE_CARE_KINDS:
            if unseen_earliest is None or e.occurred_at < unseen_earliest:
                unseen_earliest = e.occurred_at
    if seen_latest is None:
        return None
    if unseen_earliest is not None:
        return min(seen_latest, unseen_earliest - timedelta(microseconds=1))
    return seen_latest


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
            answers = {
                str(k): str(v) for k, v in (data.get("job_answers") or {}).items() if v in ANSWERS
            }
            # 옛 저장값의 failures_seen_until(시각)은 읽지 않는다 — 모듈 머리말 참고.
            return AckSnapshot(
                care_seen_id=max(0, int(data.get("care_seen_id") or 0)),
                failures_seen_id=max(0, int(data.get("failures_seen_id") or 0)),
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
        failures_seen_id: int | None = None,
        seen_job_ids: Iterable[str] = (),
        job_id: str | None = None,
        answer: str | None = None,
    ) -> AckSnapshot:
        """한 번에 적용한다. 번호 둘은 늘기만 한다. 실행 답은 그 실행(과 여러 단계면 실행 번호)만 바꾼다."""
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
                    base = base_job_id(jid)
                    if base is not None:
                        answers.setdefault(base, "seen")
                if job_id is not None:
                    previous = answers.pop(job_id, None)
                    # '봤다'는 이미 남긴 움직임 답을 덮지 않는다(맨 뒤로만 옮긴다).
                    answers[job_id] = previous if answer == "seen" and previous in ("moved", "not_moved") else (
                        answer or "seen")
                    base = base_job_id(job_id)
                    if base is not None:
                        answers.setdefault(base, "seen")
                while len(answers) > JOB_LIMIT:
                    answers.pop(next(iter(answers)))
                failures = old.failures_seen_id if failures_seen_id is None else max(
                    old.failures_seen_id, failures_seen_id)
                seen = old.care_seen_id if care_seen_id is None else max(old.care_seen_id, care_seen_id)
                new = AckSnapshot(care_seen_id=seen, failures_seen_id=failures, job_answers=answers)
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
                        "failures_seen_id": snap.failures_seen_id,
                        "job_answers": snap.job_answers,
                    },
                    ensure_ascii=False,
                ),
            )
        except Exception:  # noqa: BLE001 - 저장 실패여도 이번 세션에는 적용된다
            log.exception("person acks save failed")
