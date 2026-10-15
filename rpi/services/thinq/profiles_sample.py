"""모의용 ThinQ 프로필·상태 샘플 — 모의 클라이언트·모의 클라우드·시험이 함께 쓴다.

**예시다.** 모양은 공식 SDK 저장소(pythinqconnect 1.0.14)가 읽는 공개 형식
(``property.<resource>.<prop>.{type, mode, value.{r, w}}``, 세탁기는 위치별 목록)을 따랐고,
값은 우리 동작 표(``bindings.py``)에 맞춰 골랐다. 구매 예정 공기청정기(LG AS186HWWA)를 포함해
**어떤 실제 모델의 프로필도 아니다** -- 실물 프로필은 도착 날 ``scripts/thinq_probe.py``로 읽고,
원본은 저장소 밖에만 둔다.
"""

from __future__ import annotations

import copy

#: 세탁기 운전 상태 값(예시). 실제 목록은 모델 프로필의 ``runState.currentState.value.r``.
WASHER_STATES = ("POWER_OFF", "INITIAL", "DETECTING", "RUNNING", "RINSING", "SPINNING",
                 "PAUSE", "END", "ERROR")


def _enum(values, *, mode=("r", "w"), write=None):
    write = values if write is None else write
    value = {}
    if "r" in mode:
        value["r"] = list(values)
    if "w" in mode:
        value["w"] = list(write)
    return {"type": "enum", "mode": list(mode), "value": value}


def air_purifier_profile(*, job_modes_w=("CLEAN", "SLEEP", "SILENT", "AUTO"),
                         wind_w=("LOW", "MID", "HIGH", "AUTO"),
                         wind_key="windStrength") -> dict:
    return {
        "property": {
            "airPurifierJobMode": {
                "currentJobMode": _enum(("CLEAN", "SLEEP", "SILENT", "AUTO"), write=job_modes_w),
            },
            "operation": {"airPurifierOperationMode": _enum(("POWER_ON", "POWER_OFF"))},
            "airFlow": {wind_key: _enum(("LOW", "MID", "HIGH", "AUTO"), write=wind_w)},
            "airQualitySensor": {
                "PM2": {"type": "number", "mode": ["r"]},
                "totalPollutionLevel": _enum(("GOOD", "NORMAL", "BAD", "VERY_BAD"), mode=("r",)),
            },
        },
    }


def dehumidifier_profile() -> dict:
    return {
        "property": {
            "operation": {"dehumidifierOperationMode": _enum(("POWER_ON", "POWER_OFF"))},
            "dehumidifierJobMode": {"currentJobMode": _enum(("RAPID_DEHUMIDIFICATION", "SMART_DEHUMIDIFICATION"))},
            "humidity": {
                "currentHumidity": {"type": "number", "mode": ["r"]},
                "targetHumidity": {"type": "range", "mode": ["r", "w"],
                                   "value": {"r": {"min": 30, "max": 70, "step": 5},
                                             "w": {"min": 30, "max": 70, "step": 5}}},
            },
        },
    }


def washer_profile(*, operation_w=("START", "STOP", "POWER_OFF", "WAKE_UP")) -> dict:
    return {
        "property": [{
            "location": {"locationName": "MAIN"},
            "runState": {"currentState": _enum(WASHER_STATES, mode=("r",))},
            "operation": {"washerOperationMode": _enum((), mode=("w",), write=operation_w)},
            "remoteControlEnable": {"remoteControlEnabled": {
                "type": "boolean", "mode": ["r"], "value": {"r": [True, False]}}},
        }],
    }


def air_purifier_state() -> dict:
    return {
        "airPurifierJobMode": {"currentJobMode": "CLEAN"},
        "operation": {"airPurifierOperationMode": "POWER_OFF"},
        "airFlow": {"windStrength": "LOW"},
        "airQualitySensor": {"PM2": 12, "totalPollutionLevel": "GOOD"},
    }


#: 모의 센서 등급별 기본값(예시 — 실제 모델의 등급 경계가 아니다). (PM2.5, PM10, 종합 지수)
_AIR_SAMPLE = {"GOOD": (8, 10, 1), "NORMAL": (20, 40, 2), "BAD": (42, 90, 3), "VERY_BAD": (80, 160, 4)}


def air_sensor_sample(level: str = "GOOD", *, pm2: int | None = None, pm10: int | None = None) -> dict:
    """모의 공기청정기 센서 칸(``airQualitySensor``) — 2026-10-15 실물 상태와 같은 키 모양(PM1·PM2·PM10·각 등급·종합).

    세 등급을 모두 ``level``로 둔다. 값은 예시이고, 판정은 값이 아니라 등급으로 한다(``rpi/services/air_quality.py``)."""
    if level not in _AIR_SAMPLE:
        raise ValueError(f"level must be one of {', '.join(_AIR_SAMPLE)}")
    base_pm2, base_pm10, total = _AIR_SAMPLE[level]
    pm2 = base_pm2 if pm2 is None else pm2
    pm10 = base_pm10 if pm10 is None else pm10
    return {"PM1": pm2, "PM2": pm2, "PM10": pm10, "PM1Level": level, "PM2Level": level, "PM10Level": level,
            "totalPollution": total, "totalPollutionLevel": level}


def dehumidifier_state() -> dict:
    return {
        "operation": {"dehumidifierOperationMode": "POWER_OFF"},
        "dehumidifierJobMode": {"currentJobMode": "SMART_DEHUMIDIFICATION"},
        "humidity": {"currentHumidity": 63, "targetHumidity": 50},
    }


def washer_state(*, current_state="INITIAL", remote=False) -> list:
    return [{
        "location": {"locationName": "MAIN"},
        "runState": {"currentState": current_state},
        "remoteControlEnable": {"remoteControlEnabled": remote},
    }]


def copy_of(value):
    return copy.deepcopy(value)
