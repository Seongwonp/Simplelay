"""팀원 코드에서 옮긴 모션 펌웨어(`firmware-motion-corexy/`) 정적 대조 — 2026-10-10.

C 코드를 돌리지 않는다(컴파일은 PlatformIO로 따로, 동작은 실물로만 확인된다). 이 시험이 잡는 것:

1. 규약 표(`firmware-motion/protocol_table.json`)의 명령·필드·오류 코드·상태·이벤트 이름이 소스에 문자열로 있다.
2. 원작의 BLE 서버·앱 경로(NUS·앱 JSON v2·인증·키 저장)가 코드에 남지 않았고, 원작 이름은 출처 표기 줄에만 있다.
3. 원작에서 온 파일마다 출처 표기가 있다.
4. 원작의 잘못된 리밋 핀(30·100)이 돌아오지 않았다.
5. 호스트(RPi4 kinematics)가 만든 카운트를 펌웨어 식으로 되돌리면 같은 mm가 된다(같은 기구 값일 때).
6. 워치독·heartbeat 박자가 호스트 기본값과 맞는다.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from rpi.controller.kinematics import CoreXYConfig, xy_to_motor_counts

ROOT = Path(__file__).resolve().parents[2]
FW = ROOT / "firmware-motion-corexy"
TABLE = json.loads((ROOT / "firmware-motion" / "protocol_table.json").read_text(encoding="utf-8"))
SOURCES = sorted([*(FW / "src").glob("*.cpp"), *(FW / "src").glob("*.h"), *(FW / "include").glob("*.h")])
SRC_TEXT = "\n".join(p.read_text(encoding="utf-8") for p in SOURCES)
CONFIG_H = (FW / "include" / "config.h").read_text(encoding="utf-8")
ATTRIBUTION = "원작: 팀원(서예솔) Touch Bridge CoreXY 펌웨어 v3, SimpleLay용으로 통신·이름 수정"

# 솔레노이드 빌드에서는 Z 후퇴가 '끄기'라 done·not_needed만 나온다(firmware-motion README Z_MODE 표).
SOLENOID_ONLY_Z_RETRACT = {"done", "not_needed"}


def _in_source(name: str) -> bool:
    return f'"{name}"' in SRC_TEXT or f'\\"{name}\\"' in SRC_TEXT


def test_sources_exist():
    names = {p.name for p in SOURCES}
    assert {"main.cpp", "host_protocol.cpp", "CoreXYMotion.h", "QuadEncoder.h", "Tb6612Motor.h", "config.h"} <= names


def test_partial_jog_is_bench_only_and_cannot_be_used_as_a_press_target():
    core = (FW / "include" / "CoreXYMotion.h").read_text(encoding="utf-8")
    main = (FW / "src" / "main.cpp").read_text(encoding="utf-8")
    assert "#if defined(BENCH_HOME_AT_CURRENT) && BENCH_HOME_AT_CURRENT" in core
    assert "emit(MotionEvent::MOVE_PARTIAL)" in core
    assert "fault(MotionEvent::FAULT_SETTLE)" in core  # 시연 빌드에는 기존 안전 실패를 유지
    assert "g_posRefValid = false;  // 미도착 지점에서 누름은 금지" in main
    assert 'proto_reply_error(id, "z_unsupported");' in main


def test_source_mentions_every_protocol_table_name():
    names: set[str] = set(TABLE["commands"])
    for spec in TABLE["commands"].values():
        names.update(spec.get("reply", []))
        names.update(spec.get("events", []))
        names.update(spec.get("request", []))
        for fields in spec.get("request_by_mode", {}).values():
            names.update(fields)
        names.update(spec.get("request_by_mode", {}))
    names.update(TABLE["error_reply"])
    names.update(TABLE["errors"])
    names.update(TABLE["events"])
    names.update(TABLE["alarm_reasons"])
    names.update(TABLE["states"])
    names.update(TABLE["limit_inputs"])
    for fields in TABLE["events"].values():
        names.update(fields)
    names.update(SOLENOID_ONLY_Z_RETRACT)
    names.update(TABLE["z_cooldown_reply"])
    names.discard("cmd")
    missing = sorted(n for n in names if not _in_source(n))
    assert missing == []
    assert 'doc["cmd"]' in SRC_TEXT
    assert '\\"protocol\\":\\"' + TABLE["protocol"] + '\\"' in SRC_TEXT
    assert "proto_event_ready(" in (FW / "src" / "main.cpp").read_text(encoding="utf-8")


@pytest.mark.parametrize(
    "identifier",
    ["BLEServer", "BLE2902", "NUS_SERVICE_UUID", "mbedtls", "Preferences",
     "pairKey", "bleConnected", "hmacHex", "\"provision\"", "\"challenge\"", "KEYRESET\")", "handleGcode",
     "BLE_DEVICE_NAME"],
)
def test_wireless_and_app_paths_are_removed(identifier):
    assert identifier not in SRC_TEXT


def test_original_name_only_in_attribution_lines():
    files = [*SOURCES, FW / "platformio.ini"]
    for path in files:
        for line in path.read_text(encoding="utf-8").splitlines():
            if "Touch Bridge" in line or "touchbridge" in line.lower():
                assert "원작" in line, f"{path.name}: {line}"


@pytest.mark.parametrize("name", ["config.h", "CoreXYMotion.h", "QuadEncoder.h", "Tb6612Motor.h"])
def test_derived_headers_carry_attribution(name):
    assert ATTRIBUTION in (FW / "include" / name).read_text(encoding="utf-8")


def test_main_carries_attribution():
    assert ATTRIBUTION in (FW / "src" / "main.cpp").read_text(encoding="utf-8")


def _constexpr(name: str) -> float:
    match = re.search(rf"constexpr\s+\w+\s+{name}\s*=\s*([^;]+);", CONFIG_H)
    assert match, name
    expr = match.group(1).replace("f", "")
    return float(eval(expr, {"__builtins__": {}}, {}))  # 단순 상수식(7.0 * 4.0 등)만 있다


def _define(name: str) -> float:
    match = re.search(rf"^#define\s+{name}\s+([0-9.]+)f?\b", CONFIG_H, re.MULTILINE)
    assert match, name
    return float(match.group(1))


ESP32_GPIOS = set(range(0, 20)) | {21, 22, 23, 25, 26, 27} | set(range(32, 40))


def test_limit_pins_are_real_esp32_gpios():
    for name in ("PIN_LIMIT_X", "PIN_LIMIT_Y"):
        pin = int(_constexpr(name))
        assert pin in ESP32_GPIOS and pin not in range(6, 12) and pin < 34, (name, pin)
    assert "static_assert(!USE_LIMIT_SWITCHES ||" in CONFIG_H  # 컴파일 때도 막는다


def test_host_counts_round_trip_through_firmware_kinematics():
    counts_per_rev = _constexpr("ENC_COUNTS_PER_MOTOR_REV") * _constexpr("GEAR_RATIO")
    teeth, pitch = _constexpr("PULLEY_TEETH"), _constexpr("BELT_PITCH_MM")
    cpm = counts_per_rev / (teeth * pitch)
    kin = CoreXYConfig(counts_per_output_rev=counts_per_rev, pulley_teeth=int(teeth), belt_pitch_mm=pitch,
                       a_sign=1, b_sign=1)
    tol = _define("KIN_MATCH_TOL_MM")
    for x, y in [(3.0, 3.0), (10.0, 5.0), (150.5, 20.25), (199.0, 199.0)]:
        counts = xy_to_motor_counts(x, y, kin)
        a, b = round(counts.a), round(counts.b)  # serial_motion._move_request와 같은 반올림
        fx = (a + b) * 0.5 / cpm  # main.cpp cmd_move와 같은 식
        fy = (a - b) * 0.5 / cpm
        assert abs(fx - x) <= tol and abs(fy - y) <= tol, (x, y, fx, fy)


def test_watchdog_matches_host_heartbeat():
    heartbeat, watchdog = _define("HOST_HEARTBEAT_MS"), _define("HOST_WATCHDOG_MS")
    assert heartbeat == 500
    assert 3 * heartbeat <= watchdog <= 5000
    assert "HOST_WATCHDOG_MS < 3 * HOST_HEARTBEAT_MS" in CONFIG_H


def test_bringup_text_commands_are_build_flag_only():
    main = (FW / "src" / "main.cpp").read_text(encoding="utf-8")
    assert "#define BRINGUP_TEXT_COMMANDS 0" in main  # 기본 빌드는 꺼짐
    start = main.index("#if BRINGUP_TEXT_COMMANDS\nconstexpr float BRINGUP_RAW_MAX")
    end = main.index("#endif", start)
    outside = main[:start] + main[end:]
    assert "rawPwm" not in outside  # 방향 시험(PWM 직접 인가)은 bring-up 블록 안에만
    assert "setGains" not in outside
    assert "makeStep(StepType::SET_ORIGIN" not in outside  # 수동 원점 지정은 bring-up 'Z'만 큐에 넣는다
