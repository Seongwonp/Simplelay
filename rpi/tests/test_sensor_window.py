"""누름 관측 구간(인계 2026-10-06 노트북-3 §A — H1·H2).

실제 진입점(`rpi4.act_main._build_executor`, ``SIMPLELAY_SENSORS_ENABLED=true``)과 같은 배선으로
시험한다. 하드웨어 라이브러리(ADS1115·sounddevice)만 가짜 모듈로 바꿔 끼우고, 실제
``Ads1115Reader``·``SounddeviceReader``·``SensorVerifier()``(기본 설정) 생성 경로를 그대로 탄다.
기준선을 미리 채우는 준비 호출은 없다.

임계값·창 길이는 전부 기본값(추측, 실측 필요)이다 — 여기서는 판정 경로만 확인한다.
"""

from __future__ import annotations

import sys
import threading
import time
import types

import numpy as np
import pytest

from rpi.controller import ClosedLoopController, ExecutionStatus
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.verifier.audio_sensor import FakeAudioReader
from rpi.verifier.config import CurrentSensorConfig, SensorConfig

_ZERO_V = 2.5
_SENS_V_PER_A = 0.185
_CHUNK = 512
_RATE = 16_000


# ── 가짜 하드웨어 세계 ─────────────────────────────────────────────────────────


class _World:
    """전류(가전 쪽 ACS712)와 마이크 스트림을 함께 쥔 가짜 세계."""

    def __init__(self) -> None:
        self.amps = 0.0
        self.adc_error: Exception | None = None
        self.stream: "_FakeInputStream | None" = None

    # ADS1115 AnalogIn.voltage
    def voltage(self) -> float:
        if self.adc_error is not None:
            raise self.adc_error
        return _ZERO_V + self.amps * _SENS_V_PER_A

    # sounddevice 콜백(실제로는 PortAudio 스레드가 부른다)
    def emit(self, pcm: np.ndarray) -> None:
        assert self.stream is not None
        self.stream.callback(pcm.reshape(-1, 1).astype(np.float32), len(pcm), None, None)

    def tone(self, n: int = 3) -> None:
        for _ in range(n):
            self.emit(FakeAudioReader.tone(1500))
            time.sleep(0.005)

    def silence(self, n: int = 3) -> None:
        for _ in range(n):
            self.emit(FakeAudioReader.silence())
            time.sleep(0.005)


class _FakeInputStream:
    def __init__(self, world: _World, callback, **_kwargs) -> None:
        self.callback = callback
        self.active = False
        self.closed = False
        world.stream = self

    def start(self) -> None:
        self.active = True

    def stop(self) -> None:
        self.active = False

    def close(self) -> None:
        self.active = False
        self.closed = True


def _install_fake_hardware(monkeypatch, world: _World) -> None:
    """board·busio·adafruit_ads1x15·sounddevice를 가짜 모듈로 바꾼다."""
    board = types.ModuleType("board")
    board.SCL, board.SDA = "SCL", "SDA"
    busio = types.ModuleType("busio")
    busio.I2C = lambda scl, sda: object()

    pkg = types.ModuleType("adafruit_ads1x15")
    pkg.__path__ = []  # 패키지로 보이게
    ads1115 = types.ModuleType("adafruit_ads1x15.ads1115")

    class ADS1115:
        def __init__(self, i2c, data_rate=None) -> None:
            self.gain = 1

    ads1115.ADS1115 = ADS1115
    ads1115.P0, ads1115.P1, ads1115.P2, ads1115.P3 = 0, 1, 2, 3
    analog_in = types.ModuleType("adafruit_ads1x15.analog_in")

    class AnalogIn:
        def __init__(self, ads, channel) -> None:
            pass

        @property
        def voltage(self) -> float:
            return world.voltage()

    analog_in.AnalogIn = AnalogIn
    pkg.ads1115 = ads1115
    pkg.analog_in = analog_in

    sd = types.ModuleType("sounddevice")
    sd.InputStream = lambda callback, **kw: _FakeInputStream(world, callback, **kw)

    for name, mod in {
        "board": board,
        "busio": busio,
        "adafruit_ads1x15": pkg,
        "adafruit_ads1x15.ads1115": ads1115,
        "adafruit_ads1x15.analog_in": analog_in,
        "sounddevice": sd,
    }.items():
        monkeypatch.setitem(sys.modules, name, mod)


class _PressGrbl(MockGrblClient):
    """누를 때 세계를 바꾸는 모션 대역. ``on_press(world, n)``이 누름 동안의 신호를 만든다."""

    def __init__(self, world: _World, on_press) -> None:
        super().__init__()
        self.world = world
        self.on_press = on_press

    def press(self, command) -> None:
        super().press(command)
        self.on_press(self.world, len(self.commands))


def _real_press(world: _World, _n: int) -> None:
    """버튼이 실제로 눌린 누름: 누름 동안 전류가 오르고 버튼음이 난다."""
    world.amps += 0.1
    world.tone(3)
    time.sleep(0.02)
    world.amps -= 0.1


@pytest.fixture
def world(monkeypatch):
    for name in ("SIMPLELAY_L3_MODE", "SIMPLELAY_MOTION_MODE", "SIMPLELAY_OUTLET_PORT",
                 "SIMPLELAY_DEMO_PACING"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("SIMPLELAY_SENSORS_ENABLED", "true")
    # 영전류 2.5 V는 gain 2(±2.048 V) 밖이라 기동이 거절된다(평가 M2, test_sensor_config_check.py).
    # 여기서는 2.5 V를 읽을 수 있는 gain 1(±4.096 V)로 둔다 — 실제 분압 회로·gain은 실측 필요.
    monkeypatch.setenv("SIMPLELAY_CURRENT_ADC_GAIN", "1")
    monkeypatch.delenv("SIMPLELAY_CURRENT_ZERO_V", raising=False)
    w = _World()
    _install_fake_hardware(monkeypatch, w)
    return w


def _entry_point_controller(monkeypatch, world: _World, on_press):
    """act_main._build_executor와 같은 배선으로 폐루프 컨트롤러를 만든다(모션만 대역)."""
    import rpi4.act_main as act_main

    grbl = _PressGrbl(world, on_press)
    safety = MockSafetyController()
    monkeypatch.setattr(act_main, "_build_motion", lambda **_kw: (grbl, safety))
    executor = act_main._build_executor(object(), object())  # type: ignore[arg-type]
    controller = executor._controller
    return controller, grbl, safety, controller._alerts


def _close(controller) -> None:
    inner = getattr(controller._verifier, "_inner", controller._verifier)
    close = getattr(inner, "close", None)
    if callable(close):
        close()


# ── 1. 기본 설정 첫 실행(H1) ──────────────────────────────────────────────────


def test_first_run_with_default_config_succeeds_on_first_press(monkeypatch, world):
    controller, grbl, safety, _alerts = _entry_point_controller(monkeypatch, world, _real_press)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    assert result.status is ExecutionStatus.SUCCEEDED, result
    assert result.buttons[0].attempts == 1
    assert len(grbl.commands) == 1
    assert result.buttons[0].verification.confidence == pytest.approx(1.0)
    assert safety.reasons == []


# ── 2. 오래된 소리(H2) ────────────────────────────────────────────────────────


def test_stale_sound_queued_before_the_press_is_not_press_evidence(monkeypatch, world):
    def press_without_sound(w: _World, _n: int) -> None:
        w.amps += 0.1
        w.silence(3)
        time.sleep(0.02)
        w.amps -= 0.1

    controller, grbl, _safety, _alerts = _entry_point_controller(monkeypatch, world, press_without_sound)
    # 누르기 전(관측 구간 밖)에 큐에 쌓인 버튼음 같은 소리
    world.tone(4)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    verification = result.buttons[0].verification
    assert "audio=❌" in verification.detail, verification.detail
    # 전류만 성공 → 0.55(현재 가중치, 실측 필요)
    assert result.status is ExecutionStatus.SUCCEEDED
    assert verification.confidence == pytest.approx(0.55)
    assert len(grbl.commands) == 1


# ── 3. 누름과 무관한 전류 상승 ────────────────────────────────────────────────


def test_other_load_already_on_before_the_press_does_not_inflate_the_delta(monkeypatch, world):
    """누르기 전부터 다른 부하(0.5 A)가 켜져 있다 — 기준선은 누르기 직전 값이어야 한다."""
    world.amps = 0.5
    controller, _grbl, _safety, _alerts = _entry_point_controller(monkeypatch, world, _real_press)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    assert result.status is ExecutionStatus.SUCCEEDED
    assert result.buttons[0].attempts == 1
    # 누름 기여(100 mA)만 보인다 — 다른 부하 500 mA가 섞이지 않는다
    assert "Δ100.0mA" in result.buttons[0].verification.detail, result.buttons[0].verification.detail


def test_load_step_before_press_without_press_response_is_not_a_press(monkeypatch, world):
    """누르기 전에 다른 부하가 켜졌고 누름에는 반응이 없다(소리만 남) → 전류 증거 없음."""
    world.amps = 0.5

    def press_sound_only(w: _World, _n: int) -> None:
        w.tone(3)

    controller, grbl, safety, _alerts = _entry_point_controller(monkeypatch, world, press_sound_only)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert "current=❌" in result.buttons[0].verification.detail
    assert len(grbl.commands) == 3  # 정상적인 재시도 경로(단절이 아니다)


def test_step_load_between_primed_window_and_press_is_not_attributed_to_the_press():
    """창이 이미 차 있어도(옛 준비 방식) 누르기 전의 부하 증가를 누름으로 세지 않는다."""

    class _Reader:
        amps = 0.0

        def read_voltage(self) -> float:
            return _ZERO_V + self.amps * _SENS_V_PER_A

    class _SilentAudio(FakeAudioReader):
        def __init__(self) -> None:
            super().__init__([FakeAudioReader.silence()])

    from rpi.verifier.sensors import SensorVerifier

    current = _Reader()
    verifier = SensorVerifier(
        config=SensorConfig(current=CurrentSensorConfig(window_size=5)),
        current_reader=current,  # type: ignore[arg-type]
        audio_reader=_SilentAudio(),
    )
    for _ in range(6):
        verifier.verify("BT-05")  # 기준선 0 A로 채움
    current.amps = 0.5  # 누르기 전에 다른 부하가 켜짐
    controller = ClosedLoopController(
        grbl=MockGrblClient(), verifier=verifier, alerts=MockAlertSink(), safety=MockSafetyController()
    )
    result = controller.execute(["BT-05"])
    verifier.close()
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert "current=❌" in result.buttons[0].verification.detail


# ── 4. 센서 단절 ─────────────────────────────────────────────────────────────


def test_adc_failure_during_the_press_stops_without_retrying(monkeypatch, world):
    def press_then_adc_dies(w: _World, _n: int) -> None:
        w.tone(2)
        w.adc_error = OSError("[Errno 121] Remote I/O error")
        time.sleep(0.02)

    controller, grbl, safety, alerts = _entry_point_controller(monkeypatch, world, press_then_adc_dies)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert len(grbl.commands) == 1  # 단절은 다시 눌러 확인하지 않는다
    assert any("unavailable" in r for r in safety.reasons), safety.reasons
    assert alerts.failures == [("BT-05", 1)]
    assert any("current" in e for e in result.buttons[0].errors)


def test_adc_unreadable_before_the_press_never_presses(monkeypatch, world):
    world.adc_error = OSError("[Errno 121] Remote I/O error")
    controller, grbl, safety, _alerts = _entry_point_controller(monkeypatch, world, _real_press)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert grbl.commands == []
    assert any("unavailable" in r for r in safety.reasons), safety.reasons


def test_microphone_with_no_frames_is_disconnected_not_silence(monkeypatch, world):
    def press_mic_dead(w: _World, _n: int) -> None:
        w.amps += 0.1
        time.sleep(0.03)  # 콜백이 오지 않는다(USB 마이크 빠짐)
        w.amps -= 0.1

    controller, grbl, safety, _alerts = _entry_point_controller(monkeypatch, world, press_mic_dead)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert len(grbl.commands) == 1
    assert any("unavailable" in r for r in safety.reasons), safety.reasons
    assert any("microphone" in e for e in result.buttons[0].errors), result.buttons[0].errors


def test_microphone_stream_stopped_is_disconnected(monkeypatch, world):
    def press_stream_stops(w: _World, _n: int) -> None:
        w.amps += 0.1
        w.tone(2)
        w.stream.active = False  # PortAudio가 스트림을 멈춤(장치 제거)
        time.sleep(0.02)
        w.amps -= 0.1

    controller, grbl, safety, _alerts = _entry_point_controller(monkeypatch, world, press_stream_stops)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert len(grbl.commands) == 1
    assert any("unavailable" in r for r in safety.reasons), safety.reasons


def test_zero_current_and_silence_are_normal_negatives_not_disconnect(monkeypatch, world):
    def press_nothing_happens(w: _World, _n: int) -> None:
        w.silence(3)

    controller, grbl, safety, _alerts = _entry_point_controller(monkeypatch, world, press_nothing_happens)
    try:
        result = controller.execute(["BT-05"])
    finally:
        _close(controller)
    assert result.status is ExecutionStatus.SAFETY_STOPPED
    assert len(grbl.commands) == 3  # 보정 재시도 후 정지 — 기존 경로
    assert not any("unavailable" in r for r in safety.reasons), safety.reasons
    assert "current=❌" in result.buttons[0].verification.detail
    assert "audio=❌" in result.buttons[0].verification.detail


# ── 5. 마이크 큐: 가득 차면 오래된 것을 버리고 최신을 남긴다 ─────────────────


def test_sounddevice_queue_keeps_the_newest_frames_when_full(monkeypatch, world):
    from rpi.verifier.audio_sensor import SounddeviceReader
    from rpi.verifier.config import AudioSensorConfig

    reader = SounddeviceReader(AudioSensorConfig())
    for i in range(300):
        world.emit(np.full(_CHUNK, i / 1000.0, dtype=np.float32))
    first = reader.read_frame()
    reader.close()
    # 옛 구현은 큐가 차면 새 프레임을 버려 0번 프레임이 남았다
    assert first[0] > 0.0
    assert first[0] == pytest.approx((300 - AudioSensorConfig().queue_frames) / 1000.0)


def test_sounddevice_frames_carry_monotonic_timestamps(monkeypatch, world):
    from rpi.verifier.audio_sensor import SounddeviceReader
    from rpi.verifier.config import AudioSensorConfig

    reader = SounddeviceReader(AudioSensorConfig())
    before = time.monotonic()
    for _ in range(3):
        world.emit(FakeAudioReader.silence())
    frames = reader.drain()
    reader.close()
    assert len(frames) == 3
    assert all(before <= f.t <= time.monotonic() for f in frames)
    assert [f.t for f in frames] == sorted(f.t for f in frames)


def test_window_threads_do_not_leak(monkeypatch, world):
    before = threading.active_count()
    controller, _grbl, _safety, _alerts = _entry_point_controller(monkeypatch, world, _real_press)
    try:
        controller.execute(["BT-05", "BT-06"])
    finally:
        _close(controller)
    time.sleep(0.05)
    assert threading.active_count() <= before
