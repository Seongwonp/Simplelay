"""브라우저 디지털 트윈(개념 모션) 화면용 읽기 전용 상태 요약.

SimulatorController.snapshot()의 통신 프레임과 모의 실행기 내부 누름 기록만
정리한다. 새 결과를 만들지 않는다 -- 성공·실패는 RPi4 → RPi5 ``result`` 프레임이
있을 때만 옮겨 적고, 없으면 ``None``이다. 버튼별 성공 여부도 추정하지 않는다
(통신 결과는 시퀀스 전체의 success/retry 하나뿐이다).
"""
from __future__ import annotations

from typing import Any

NOTE = ("개념 모션용 요약입니다. 누름 기록은 모의 실행기 내부 관측이고, "
        "결과는 통신 result 프레임이 있을 때만 표시합니다.")


def _latest_execute(frames: list[dict]) -> tuple[int, dict] | None:
    for i in range(len(frames) - 1, -1, -1):
        f = frames[i]
        msg = f.get("message") or {}
        if f.get("direction") == "hub_to_act" and msg.get("type") == "execute":
            return i, msg
    return None


def attribute_presses(sequence: list[str], presses: list[str]) -> dict[str, Any]:
    """누름 기록(재시도 포함)을 시퀀스 단계에 순서대로 대응시킨다.

    같은 이름이 연달아 오는 시퀀스(예: 10초, 10초)에서는 재시도와 다음 단계를
    구분할 근거가 없다. 다음 단계로 대응시키되 ``attribution='ambiguous'``로
    표시한다. 기록이
    시퀀스와 맞지 않으면 ``'mismatch'``이고 그 뒤 누름은 단계에 붙이지 않는다.
    """
    attempts = [0] * len(sequence)
    log: list[dict[str, Any]] = []
    i = 0
    attribution = "sequential"
    for n, label in enumerate(presses):
        step: int | None = None
        if attribution != "mismatch" and i < len(sequence):
            nxt = i + 1 < len(sequence) and sequence[i + 1] == label
            if attempts[i] == 0 and sequence[i] == label:
                step = i
            elif attempts[i] > 0 and sequence[i] == label and not nxt:
                step = i
            elif attempts[i] > 0 and nxt:
                if sequence[i] == label:
                    # 재시도일 수도, 다음 단계일 수도 있다. 다음 단계로 두되 표시한다.
                    attribution = "ambiguous"
                i += 1
                step = i
            else:
                attribution = "mismatch"
        if step is not None:
            attempts[step] += 1
        log.append({"n": n, "label": label, "step_index": step,
                    "attempt": attempts[step] if step is not None else None})
    steps = [{"index": k, "label": lab, "attempts": attempts[k]}
             for k, lab in enumerate(sequence)]
    return {"steps": steps, "press_log": log, "attribution": attribution}


def build_twin_state(snapshot: dict[str, Any]) -> dict[str, Any]:
    frames = list(snapshot.get("frames") or [])
    local = snapshot.get("act_local") or {}
    base = {
        "execution_mode": snapshot.get("execution_mode", "unknown"),
        "transport": snapshot.get("transport"),
        "running": bool(snapshot.get("running")),
        "note": NOTE,
        "job": None,
    }
    found = _latest_execute(frames)
    if found is None:
        return base
    index, execute = found
    sequence_id = execute.get("sequence_id")
    buttons = [str(b) for b in execute.get("buttons") or []]
    result = None
    abort_requested = False
    for f in frames[index + 1:]:
        msg = f.get("message") or {}
        if f.get("direction") == "hub_to_act" and msg.get("type") == "abort" and result is None:
            abort_requested = True
        if (f.get("direction") == "act_to_hub" and msg.get("type") == "result"
                and msg.get("sequence_id") == sequence_id):
            result = {"success": bool(msg.get("success")), "retry": msg.get("retry")}
    presses = [str(p) for p in local.get("presses") or []]
    local_status = local.get("status")
    # 실행기가 새 시퀀스를 시작하기 전(이전 결과가 아직 남아 있음)의 누름 기록은
    # 이전 실행의 것이다. 새 execute 프레임에 붙이지 않는다.
    stale = result is None and local_status is not None
    if stale:
        presses = []
    attributed = attribute_presses(buttons, presses)
    base["job"] = {
        "sequence_id": sequence_id,
        "buttons": buttons,
        "presses": presses,
        "press_count": len(presses),
        "result": result,
        "abort_requested": abort_requested,
        "act_local_status": None if stale else local_status,
        **attributed,
    }
    return base
