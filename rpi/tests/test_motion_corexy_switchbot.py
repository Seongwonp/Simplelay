"""CoreXY 펌웨어의 SwitchBot Bot 선택 빌드 계약.

실물 BLE 동작은 확인하지 않는다. 이 회귀 시험은 선택 빌드가 기본 솔레노이드 빌드와
분리되고, BLE 대기가 loop/정지를 막지 않으며, 누름 결과를 모호하게 성공 처리하지 않는
정적 계약만 지킨다.
"""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FW = ROOT / "firmware-motion-corexy"


def test_switchbot_platformio_environment_is_explicit_and_has_room_for_ble():
    ini = (FW / "platformio.ini").read_text(encoding="utf-8")
    assert "[env:esp32dev_switchbot]" in ini
    assert "-DZ_ACTUATOR_SWITCHBOT=1" in ini
    assert '-DSWITCHBOT_MAC=\\\"f5:2a:43:db:ea:28\\\"' in ini
    assert "board_build.partitions = huge_app.csv" in ini


def test_switchbot_client_is_credited_async_and_requires_notify_ack():
    header = (FW / "include" / "SwitchBotBLE.h").read_text(encoding="utf-8")
    assert "원작: 팀원(서예솔) Touch Bridge" in header
    assert "xTaskCreatePinnedToCore" in header
    assert "xQueueCreate" in header
    assert "ACK_TIMEOUT_MS" in header
    assert "SB_ERR_ACK_TIMEOUT" in header
    assert "SB_ERR_NOTIFY" in header
    assert "portENTER_CRITICAL(&stateMux)" in header  # stop과 BLE write 직전 경합을 원자적으로 판정한다.
    assert "BLEServer" not in header


def test_switchbot_main_initializes_only_the_client_and_reports_honest_outcomes():
    main = (FW / "src" / "main.cpp").read_text(encoding="utf-8")
    assert "#if Z_ACTUATOR_SWITCHBOT" in main
    assert 'BLEDevice::init("")' in main
    assert "sbble::request(sbble::PRESS)" in main
    assert "sbble::poll" in main
    assert '"switchbot_ack_timeout"' in main
    assert '"switchbot_connect_failed"' in main
    assert '"unknown"' in main
    assert '"not_pressed"' in main
    assert '"switchbot_press_sent_cannot_recall"' in main

