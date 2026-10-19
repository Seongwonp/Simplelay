"""실행 요청 영수증 — 클라이언트 요청 번호(``client_request_id``) → 접수한 실행 번호(``job_id``) (검토 10/19).

실행을 접수했는데 HTTP 응답만 잃으면 클라이언트는 자기 실행 번호를 알 길이 없었다. 같은 요청 번호로 다시 보내면
**같은 실행 번호**를 돌려주고 다시 실행하지 않는다. 첫 요청이 아직 접수 중이면 그 결과를 기다린다(한 번만 실행).

- 접수에 실패하면(바쁨·해석 거절 등) 영수증을 남기지 않는다 — 같은 번호로 다시 보내면 새로 접수를 시도한다.
  그 실패를 기다리던 같은 번호의 요청은 같은 예외를 받는다.
- 메모리만(재시작하면 사라짐), 최근 ``RECEIPTS_KEPT``건. 번호는 경로와 상관없이 한 이름공간이다.
- 요청 번호가 없으면 종전 그대로(매번 새 실행).
"""

from __future__ import annotations

import re
import threading
from collections import OrderedDict
from concurrent.futures import Future
from concurrent.futures import TimeoutError as FutureTimeout
from typing import Callable

#: 영수증을 남기는 최근 요청 수.
RECEIPTS_KEPT = 256
#: 같은 번호의 첫 요청이 접수를 마칠 때까지 기다리는 상한(초). 접수(게이트 통과·스레드 시작)는 짧다.
ADMISSION_WAIT_S = 30.0
#: 허용하는 요청 번호 모양.
CLIENT_REQUEST_ID_PATTERN = r"^[A-Za-z0-9_-]{1,64}$"
_ID_RE = re.compile(CLIENT_REQUEST_ID_PATTERN)


class AdmissionPendingError(RuntimeError):
    """같은 요청 번호의 첫 요청이 상한 안에 접수를 마치지 못했다(409로 옮긴다)."""


def valid_client_request_id(value: str) -> bool:
    return bool(_ID_RE.fullmatch(value))


class JobRequestLedger:
    def __init__(self, kept: int = RECEIPTS_KEPT) -> None:
        self._kept = kept
        self._lock = threading.Lock()
        self._jobs: OrderedDict[str, str] = OrderedDict()
        self._admitting: dict[str, Future] = {}

    def job_for(self, client_request_id: str) -> str | None:
        with self._lock:
            return self._jobs.get(client_request_id)

    def wait_job_for(self, client_request_id: str, timeout: float = ADMISSION_WAIT_S) -> str | None:
        """접수가 끝난 번호면 그 실행 번호. 접수 중이면 끝날 때까지(상한) 기다린다. 실패·없음·상한 초과는 None."""
        with self._lock:
            job = self._jobs.get(client_request_id)
            if job is not None:
                return job
            pending = self._admitting.get(client_request_id)
        if pending is None:
            return None
        try:
            return pending.result(timeout=timeout)
        except Exception:  # noqa: BLE001 - 접수 실패·상한 초과는 '없음'
            return None

    def admit(self, client_request_id: str | None, submit: Callable[..., str], *args, **kwargs) -> str:
        """``submit(*args, **kwargs)``로 접수하고 실행 번호를 돌려준다. 같은 번호는 한 번만 접수한다."""
        if client_request_id is None:
            return submit(*args, **kwargs)
        with self._lock:
            job = self._jobs.get(client_request_id)
            if job is not None:
                return job
            pending = self._admitting.get(client_request_id)
            owner = pending is None
            if owner:
                pending = Future()
                self._admitting[client_request_id] = pending
        if not owner:
            try:
                return pending.result(timeout=ADMISSION_WAIT_S)
            except FutureTimeout as exc:
                raise AdmissionPendingError("같은 요청을 아직 받는 중이에요. 잠시 뒤 다시 확인해 주세요.") from exc
        try:
            job = submit(*args, **kwargs)
        except BaseException as exc:
            with self._lock:
                self._admitting.pop(client_request_id, None)
            pending.set_exception(exc)
            raise
        with self._lock:
            self._admitting.pop(client_request_id, None)
            if job:
                self._jobs[client_request_id] = job
                self._jobs.move_to_end(client_request_id)
                while len(self._jobs) > self._kept:
                    self._jobs.popitem(last=False)
        pending.set_result(job)
        return job


def ledger_of(app) -> JobRequestLedger:
    """앱마다 하나(``app.state``). 이벤트 루프 스레드에서 부른다."""
    ledger = getattr(app.state, "job_request_ledger", None)
    if ledger is None:
        ledger = JobRequestLedger()
        app.state.job_request_ledger = ledger
    return ledger


class ApproveAllowReceipts:
    """'이번에 실행하고 다음부터 자동으로'(approve-and-allow)의 묶음 응답 영수증 (검토 10/19).

    - 요청 번호별: 묶음 응답 전체(``job_id`` + ``rule`` + ``auto_allow``). 같은 번호의 재요청은 대기 중 제안 확인보다 **먼저**
      이 영수증을 보고 같은 응답을 돌려준다. 실행 번호만 담는 ``/execute`` 장부와 섞이지 않게 장부를 따로 둔다.
    - 제안별: 접수한 실행 번호와 자동 허용 결과, 그 규칙을 다시 찾을 열쇠. 번호 없는 재요청에 쓴다.
    - 메모리만(재시작하면 사라짐), 최근 ``RECEIPTS_KEPT``건.
    """

    def __init__(self, kept: int = RECEIPTS_KEPT) -> None:
        self.requests = JobRequestLedger(kept)
        self._kept = kept
        self._lock = threading.Lock()
        self._by_suggestion: OrderedDict[str, dict] = OrderedDict()

    def remember(self, suggestion_id: str, *, job_id: str, rule_key: tuple, auto_allow: dict) -> None:
        with self._lock:
            self._by_suggestion[suggestion_id] = {"job_id": job_id, "rule_key": rule_key,
                                                  "auto_allow": dict(auto_allow)}
            self._by_suggestion.move_to_end(suggestion_id)
            while len(self._by_suggestion) > self._kept:
                self._by_suggestion.popitem(last=False)

    def for_suggestion(self, suggestion_id: str) -> dict | None:
        with self._lock:
            hit = self._by_suggestion.get(suggestion_id)
            return None if hit is None else {**hit, "auto_allow": dict(hit["auto_allow"])}


def approve_allow_receipts_of(app) -> ApproveAllowReceipts:
    """앱마다 하나(``app.state``). 이벤트 루프 스레드에서 부른다."""
    receipts = getattr(app.state, "approve_allow_receipts", None)
    if receipts is None:
        receipts = ApproveAllowReceipts()
        app.state.approve_allow_receipts = receipts
    return receipts
