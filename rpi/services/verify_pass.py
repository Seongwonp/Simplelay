"""확인 주행(가전 추가 ⑤, 2026-09-30) — 허브 쪽 실행·상태. **실물 미검증.**

갠트리가 Z를 올린 채 버튼 위를 하나씩 지나가고 사람이 맞는지 본다. 누르지 않는다.

- 실행 대상이 ``verify_pass``를 가지면(RPi4 링크 — 시뮬레이터·UART) 그쪽으로 보낸다.
  RPi4는 모의 모션이면 기록만, 실제 어댑터면 ``SerialMotionClient.move_to``만 쓴다.
- 로컬 모의 컨트롤러(기본 ``SIMPLELAY_ACT_MODE`` 없음)면 여기서 모의 모션으로 돈다.
- 그 밖(실행 모드를 모르는 대상)은 거절한다 — 누름 명령으로 이동을 흉내 내지 않는다.

상태는 가전마다 마지막 한 번만 기억한다(메모리). ``reached``는 모션이 도착을 응답했다는
뜻이지 버튼 위라는 확인이 아니다 — 확인은 사람이 한다.
"""

from __future__ import annotations

import logging
import threading
import uuid
from typing import Any

from rpi.controller import ExecutionMode
from rpi.services.control_arbiter import ControlArbiter

log = logging.getLogger(__name__)


#: 확인 주행이 기계 제어권을 잡을 때의 이름(ControlArbiter holder). 일반 실행(``execution``)의
#: 반납과 섞이지 않게 따로 둔다.
VERIFY_PASS_HOLDER = ControlArbiter.VERIFY_PASS


class VerifyPassUnavailable(RuntimeError):
    """이 구성에서는 확인 주행을 할 수 없다."""


class VerifyPassRunner:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._passes: dict[str, dict] = {}
        self._running = False

    def status(self, appliance_id: str) -> dict | None:
        with self._lock:
            doc = self._passes.get(appliance_id)
            return None if doc is None else _copy(doc)

    def start(self, appliance_id: str, targets: list[dict], controller: Any,
              *, wait: bool = False, arbiter: Any = None, on_success: Any = None) -> dict:
        """``arbiter``(일반 실행과 같은 ControlArbiter)를 주면 주행 내내 기계 제어권을 잡는다 —
        잡지 못하면(일반 실행·개발자 세션·정지 미확인) ControlConflictError/ControlFaultedError
        (RuntimeError)로 거절하고 움직이지 않는다(10/19 검토 #8). ``on_success``는 모든 자리에 도착했을 때 한 번 부른다."""
        mode = getattr(controller, "execution_mode", ExecutionMode.UNKNOWN)
        remote = callable(getattr(controller, "verify_pass", None))
        if not remote and mode is not ExecutionMode.MOCK:
            raise VerifyPassUnavailable("이 구성에서는 확인 주행을 할 수 없어요(모션 연결 없음)")
        with self._lock:
            if self._running:
                raise RuntimeError("다른 확인 주행이 진행 중이에요")
            if arbiter is not None:
                arbiter.acquire(VERIFY_PASS_HOLDER)  # 중재자 락은 최내곽(leaf)이라 역전이 없다
            self._running = True
            doc = {
                "pass_id": uuid.uuid4().hex[:12],
                "appliance_id": appliance_id,
                "state": "running",
                "execution_mode": None if remote else "mock",
                "route": "act_link" if remote else "local_mock",
                "detail": None,
                "steps": [dict(t, status="pending", detail=None) for t in targets],
                "note": "누르지 않고 Z를 올린 채 지나갑니다. 버튼 위인지는 눈으로 확인해 주세요.",
            }
            self._passes[appliance_id] = doc
        thread = threading.Thread(target=self._run, args=(doc, targets, controller, remote, arbiter, on_success),
                                  daemon=True, name="verify-pass")
        try:
            thread.start()
        except BaseException:
            with self._lock:
                self._running = False
                doc["state"] = "failed"
                doc["detail"] = "확인 주행을 시작하지 못했어요"
            if arbiter is not None:
                arbiter.release(VERIFY_PASS_HOLDER)
            raise
        if wait:
            thread.join(30)
        return self.status(appliance_id) or {}

    def _update_step(self, doc: dict, event: dict) -> None:
        index = event.get("index")
        with self._lock:
            if isinstance(index, int) and 0 <= index < len(doc["steps"]):
                step = doc["steps"][index]
                step["status"] = event.get("status", step["status"])
                step["detail"] = event.get("detail")
            mode = event.get("execution_mode")
            if mode:
                doc["execution_mode"] = mode

    def _run(self, doc: dict, targets: list[dict], controller: Any, remote: bool,
             arbiter: Any = None, on_success: Any = None) -> None:
        try:
            wire = [{"button": t["button"], "x_mm": t["x_mm"], "y_mm": t["y_mm"], "kind": t["kind"]}
                    for t in targets]
            if remote:
                result = controller.verify_pass(wire, on_progress=lambda e: self._update_step(doc, e))
                for entry in result.get("targets") or []:
                    self._update_step(doc, {**entry, "execution_mode": result.get("execution_mode")})
                ok = bool(result.get("ok"))
            else:
                from rpi4.models.act_messages import VerifyTarget  # noqa: PLC0415
                from rpi4.services.stop_hold import MockHoldMotion, run_verify_pass  # noqa: PLC0415

                motion = getattr(controller, "verify_motion", None) or MockHoldMotion()
                results = run_verify_pass(
                    motion, [VerifyTarget(t["button"], t["x_mm"], t["y_mm"], t["kind"]) for t in wire],
                    lambda e: self._update_step(doc, e))
                ok = all(r["status"] == "reached" for r in results)
            with self._lock:
                doc["state"] = "done" if ok else "failed"
                doc["detail"] = ("모든 위치에 도착했다고 응답했어요 — 버튼 위였는지 확인해 주세요" if ok
                                 else "멈춘 위치가 있어요 — 조그로 고치거나 매핑을 다시 해 주세요")
            if ok and on_success is not None:
                on_success()
        except Exception as exc:  # noqa: BLE001 - 결과로 보고한다
            log.exception("verify pass failed")
            with self._lock:
                doc["state"] = "failed"
                doc["detail"] = f"확인 주행을 하지 못했어요: {exc}"
                for step in doc["steps"]:
                    if step["status"] in ("pending", "moving"):
                        step["status"] = "skipped"
        finally:
            if arbiter is not None:
                arbiter.release(VERIFY_PASS_HOLDER)
            with self._lock:
                self._running = False


def _copy(doc: dict) -> dict:
    return {**doc, "steps": [dict(s) for s in doc["steps"]]}


_runner: VerifyPassRunner | None = None
_runner_lock = threading.Lock()


def get_verify_runner() -> VerifyPassRunner:
    global _runner
    with _runner_lock:
        if _runner is None:
            _runner = VerifyPassRunner()
        return _runner
