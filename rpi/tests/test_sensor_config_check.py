"""전류 센서 설정 일관성 검사(2026-10-07, 인계 노트북-3 §D M2).

영전류 2.5 V(ACS712 5 V 전원의 VCC/2)와 ADS1115 gain 2(±2.048 V) 기본값은 함께 쓸 수 없다 — 영점이
측정 범위 밖이라 전류를 0 A로도 읽지 못한다. 실제 분압 회로는 팀원 확인 전이라 값은 **실측 필요**이고,
센서를 켤 때(SIMPLELAY_SENSORS_ENABLED=true)만 기동 전에 거절한다. 기본(mock) 기동은 그대로다.
"""

from __future__ import annotations

import pytest

from rpi.verifier.config import (
    CurrentSensorConfig,
    SensorConfigError,
    check_current_sensor_config,
    current_sensor_config_from_env,
)


def test_default_zero_point_outside_gain2_range_is_refused_in_korean():
    with pytest.raises(SensorConfigError) as exc:
        check_current_sensor_config(CurrentSensorConfig())
    message = str(exc.value)
    assert "영전류" in message and "2.5" in message and "2.048" in message
    assert "실측 필요" in message


@pytest.mark.parametrize("cfg", [
    CurrentSensorConfig(ads_gain=1),                               # ±4.096 V — 2.5 V 영점이 범위 안
    CurrentSensorConfig(zero_current_voltage=1.65, ads_gain=2),    # 3.3 V 분압 가정
])
def test_consistent_configs_pass(cfg):
    check_current_sensor_config(cfg)


@pytest.mark.parametrize("cfg, words", [
    (CurrentSensorConfig(ads_gain=3), "gain"),
    (CurrentSensorConfig(ads_gain=1, channel=4), "채널"),
    (CurrentSensorConfig(zero_current_voltage=0.0, ads_gain=1), "영전류"),
    (CurrentSensorConfig(ads_gain=1, sensitivity_mv_per_a=0.0), "감도"),
    (CurrentSensorConfig(ads_gain=1, valid_voltage_range=(0.5, 2.0)), "정상 전압 범위"),   # 영점 2.5 V를 안 품는다
    (CurrentSensorConfig(ads_gain=1, valid_voltage_range=(1.0, 5.0)), "정상 전압 범위"),   # 4.096 V 넘음
])
def test_impossible_configs_are_refused(cfg, words):
    with pytest.raises(SensorConfigError, match=words):
        check_current_sensor_config(cfg)


def test_env_overrides_zero_point_and_gain():
    cfg = current_sensor_config_from_env({"SIMPLELAY_CURRENT_ZERO_V": "1.65", "SIMPLELAY_CURRENT_ADC_GAIN": "1"})
    assert cfg.zero_current_voltage == 1.65 and cfg.ads_gain == 1
    assert current_sensor_config_from_env({}) == CurrentSensorConfig()
    with pytest.raises(SensorConfigError, match="SIMPLELAY_CURRENT_ADC_GAIN"):
        current_sensor_config_from_env({"SIMPLELAY_CURRENT_ADC_GAIN": "two"})


def test_act_main_refuses_sensor_start_with_the_default_pair(monkeypatch):
    from rpi4 import act_main

    monkeypatch.setenv("SIMPLELAY_SENSORS_ENABLED", "true")
    for name in ("SIMPLELAY_CURRENT_ZERO_V", "SIMPLELAY_CURRENT_ADC_GAIN"):
        monkeypatch.delenv(name, raising=False)
    # 장치를 열기 전에 거절한다(하드웨어 라이브러리가 없어도 같은 메시지).
    with pytest.raises(SensorConfigError, match="영전류"):
        act_main._build_verifier()


def test_default_mock_start_is_not_checked(monkeypatch):
    from rpi.verifier import MockVerifier
    from rpi4 import act_main

    monkeypatch.delenv("SIMPLELAY_SENSORS_ENABLED", raising=False)
    assert isinstance(act_main._build_verifier(), MockVerifier)
