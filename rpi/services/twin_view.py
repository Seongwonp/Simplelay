"""브라우저 디지털 트윈(개념 모션) 화면용 읽기 전용 상태 요약.

SimulatorController.snapshot()의 통신 프레임과 모의 실행기 내부 누름 기록만
정리한다. 새 결과를 만들지 않는다 -- 성공·실패는 RPi4 → RPi5 ``result`` 프레임이
있을 때만 옮겨 적고, 없으면 ``None``이다. 버튼별 성공 여부도 추정하지 않는다
(통신 결과는 시퀀스 전체의 success/retry 하나뿐이다).
"""
from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from rpi.controller.kinematics import ENV_NAMES, CoreXYConfig

NOTE = ("개념 모션용 요약입니다. 누름 기록은 모의 실행기 내부 관측이고, "
        "결과는 통신 result 프레임이 있을 때만 표시합니다.")


def _latest_execute(frames: list[dict], pinned: dict | None = None) -> tuple[int, dict] | None:
    for i in range(len(frames) - 1, -1, -1):
        f = frames[i]
        msg = f.get("message") or {}
        if f.get("direction") == "hub_to_act" and msg.get("type") == "execute":
            return i, msg
    # 긴 재시도로 trace에서 execute 프레임이 밀려났으면 시뮬레이터가 따로 고정한
    # 마지막 execute 프레임을 쓴다. 남은 프레임은 모두 그 뒤의 것이다.
    msg = (pinned or {}).get("message") or {}
    if (pinned or {}).get("direction") == "hub_to_act" and msg.get("type") == "execute":
        return -1, msg
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
    found = _latest_execute(frames, snapshot.get("last_execute_frame"))
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
    corrections = list(local.get("press_corrections") or [])
    local_status = local.get("status")
    # 실행기가 새 시퀀스를 시작하기 전(이전 결과가 아직 남아 있음)의 누름 기록은
    # 이전 실행의 것이다. 새 execute 프레임에 붙이지 않는다.
    stale = result is None and local_status is not None
    if stale:
        presses = []
        corrections = []
    attributed = attribute_presses(buttons, presses)
    for entry in attributed["press_log"]:
        # 실행기가 기록한 재시도 보정 요청(정성 값, 거리 없음). 없으면 None.
        n = entry["n"]
        entry["correction"] = corrections[n] if n < len(corrections) else None
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


# ── 하드웨어 요약(공식 사양 + 미설정 항목) ─────────────────────────────────────
# 값은 하드웨어 기술 조사 보고서 A-1·A-2·D절의 공식 표기만 옮긴다. 추정값을 더하지 않는다.

OFFICIAL_SPECS: tuple[dict[str, str], ...] = (
    {"item": "모터", "value": "DFRobot FIT0482 ×3 (CoreXY A · B + Z 누름)", "source": "A-1"},
    {"item": "정격 전압", "value": "6.0 V", "source": "A-1"},
    {"item": "무부하 속도", "value": "310 rpm @6 V — 속도 상한 표시용, 화면 타이밍에 쓰지 않음", "source": "A-1"},
    {"item": "정격 속도", "value": "180 rpm @6 V (정격 토크 0.35 kg·cm, 정격 전류 170 mA)", "source": "A-1"},
    {"item": "감속비", "value": "50:1", "source": "A-1"},
    {"item": "엔코더 공칭 분해능", "value": "700 counts/출력축 회전 (x1 기준 공칭, 디코딩 배율 미측정)", "source": "A-1·D"},
    {"item": "드라이버", "value": "JMOD-MOTOR-1 ×2 (TB6612FNG, 2채널, 채널당 최대 1.2 A — 보드 문서)", "source": "A-2"},
    {"item": "정지 방식(IC 제어표)", "value": "PWM=L → short brake(권선 단락) · IN1=IN2=L, PWM=H → stop(High-Z 공회전)", "source": "A-2"},
)

CHANNEL_ASSIGNMENT = {
    "plan": "보드1: 모터 A · B / 보드2: Z + 예비",
    "confirmed": False,
    "note": "미확정 — 드라이버 채널 배정·핀 배선·제어 MCU는 팀 확정 전입니다.",
}

HARDWARE_NOTE = ("공식 사양은 제조사 표기, 미설정 항목은 실측·제작자 제공 전이라 비어 있는 설정입니다. "
                 "화면 모션 속도는 이 값들로 계산하지 않습니다(개념 모션).")


def build_hardware_summary(env: Mapping[str, str] | None = None) -> dict[str, Any]:
    """``CoreXYConfig.from_env()``의 설정 상태와 공식 사양을 함께 요약한다."""
    config_error = None
    try:
        config = CoreXYConfig.from_env(env)
    except ValueError as exc:
        config, config_error = CoreXYConfig(), str(exc)
    configured, unset = [], []
    for name, env_name in ENV_NAMES.items():
        value = getattr(config, name)
        (unset if value is None else configured).append(
            {"name": name, "env": env_name, **({} if value is None else {"value": value})})
    return {
        "official": [dict(s) for s in OFFICIAL_SPECS],
        "upper_bound_rpm": 310,
        "rated_rpm": 180,
        "nominal_counts_x1": 700,
        "gear_ratio": 50,
        "channel_assignment": dict(CHANNEL_ASSIGNMENT),
        "stop_modes": {"brake": "PWM=L short brake", "coast": "IN1=IN2=L stop (High-Z)"},
        "configured": configured,
        "unset": unset,
        "config_error": config_error,
        "note": HARDWARE_NOTE,
    }
