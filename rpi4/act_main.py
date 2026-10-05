"""RPi4 entry point — opens a UART serial connection to RPi5 and runs ActExecutor.

This is the actual "Act" board per docs/protocol.md: it receives an
already-resolved button sequence from RPi5 and runs it through the closed
loop. It does not talk to ESP32 and does not resolve intent — that is
main.py/UartBridge's job, which (despite living in this package) actually
runs on RPi5. See the note at the top of main.py.

Environment variables:
  SIMPLELAY_UART_PORT             serial device path  (default: /dev/ttyAMA0)
  SIMPLELAY_UART_BAUD             baud rate           (default: 115200)
  SIMPLELAY_SENSORS_ENABLED       "true" → SensorVerifier (ADS1115 전류 +
                                  마이크 음향 퓨전 검증). 기본 false = mock —
                                  센서 하드웨어 없이도 실행 경로가 살아있어야
                                  하므로 (SIMPLELAY_GPIO_ENABLED와 같은 관례)
  SIMPLELAY_DANGER_SOUND_ENABLED  "true" → 위험소리(경보음) 상시 감지 태스크
                                  가동, 감지 시 RPi5로 alert 자체발신
  SIMPLELAY_MOTION_MODE           "mock"(기본) | "serial". serial이면 줄 단위 JSON
                                  모션 MCU 어댑터(rpi/controller/serial_motion.py,
                                  **실물 미검증**)를 쓴다
  SIMPLELAY_MOTION_PORT           serial 모드의 MCU 시리얼 장치 경로 (기본값 없음)
  SIMPLELAY_MOTION_BAUD           serial 모드의 보드레이트 (기본값 없음 — MCU 펌웨어가 정한다)
  SIMPLELAY_MOTION_*              기구·누름·타임아웃 값. 전부 기본 없음, 비어 있으면
                                  누름을 거절한다(serial_motion.MOTION_ENV_NAMES,
                                  kinematics.ENV_NAMES)
                                  시작 때 MCU가 status에 답하지 않으면(포트 열기로 리셋·부팅 중·케이블)
                                  배경에서 1→2→4…30 s 간격으로 연결을 다시 시도한다. 연결 확인 전의
                                  execute는 ``{"type":"error","reason":"motion_not_ready","detail":…}``로
                                  바로 거절한다(누름을 시도하지 않는다).
  SIMPLELAY_MOTION_HEARTBEAT_MS   "off"면 시작 때 경고 — 2 s 넘는 동작은 MCU 워치독에 끊긴다
  SIMPLELAY_RECORDER_PATH         설정하면 누름 주변 원시 기록기를 켠다(기본 꺼짐).
                                  .csv면 CSV, 그 밖은 JSONL로 **이어 쓴다**. 누름 호출
                                  앞뒤(press_start/press_end)와 모션 MCU 이벤트(mcu_*)를
                                  같은 시각축에 찍는다(rpi/verifier/recorder.py)
  SIMPLELAY_RECORDER_PRE_S        창 모드: press_start 전 보존(초). POST_S와 함께 준다.
  SIMPLELAY_RECORDER_POST_S       비우면 전부 기록(파일이 계속 커진다) — 창 길이는 측정 필요
  SIMPLELAY_RECORDER_ADC_GAIN     전류(ADS1115) gain. 없으면 전류는 합성(mock_current)
  SIMPLELAY_RECORDER_ADC_CHANNEL  ADS1115 채널 0~3 (기본 0)
  SIMPLELAY_RECORDER_AUDIO        "true"면 마이크를 연다. 아니면 합성(mock_audio)
  (전력은 콘센트 모듈이 있으면 그 스트림, 없으면 합성 mock_power. 합성 입력은 시작 로그에 경고로 남는다)
  SIMPLELAY_L3_MODE               L3(가전 동작) 검증기. "off"(기본) = 없음 → 결과 프레임의
                                  operation_confirmed는 null. "mock" = MockPowerSensor 합성
                                  파형으로 판정(operation_source=mock, 실제 근거 아님).
                                  "real" = 콘센트 모듈 전력 스트림으로 판정. SIMPLELAY_OUTLET_PORT가
                                  없으면 **시작을 거절**(실물 미검증 — 2026-10-05 가짜 출력으로만 시험)
  SIMPLELAY_OUTLET_PORT           콘센트 모듈(ESP32 CT·릴레이, firmware-outlet) USB 시리얼 장치. 기본 없음.
                                  "fake"면 가짜 출력(rpi/tools/fake_outlet.py) — 판정은 모의로 표시
  SIMPLELAY_OUTLET_BAUD           콘센트 모듈 보드레이트(fake가 아니면 필수, 펌웨어 HOST_SERIAL_BAUD와 같게)
  SIMPLELAY_OUTLET_RELAY_ON_START "1"이면 연결 뒤 relay_on을 보낸다. 기본은 보내지 않는다 — 모듈 부팅 기본이
                                  릴레이 꺼짐(fail-safe)이라, 켜기는 사람이 정한 설정으로만
  SIMPLELAY_OUTLET_STALE_MS       전력 샘플 끊김 판단(기본 1000). 넘으면 L3는 '센서를 읽지 못함'으로 안전 정지
  SIMPLELAY_OUTLET_HEARTBEAT_MS   모듈로 ping 간격(기본 1000, 0/off = 끔)
  SIMPLELAY_TAIL_*                잔여 전류 꼬리 기준(rpi/verifier/power_tail.py TAIL_ENV_NAMES, 전부 측정 필요).
                                  L3 확인 뒤 progress {phase:"power_tail"}와 기록기 power_tail 행으로 남긴다
  SIMPLELAY_L3_MOCK_OUTCOME       mock 모드의 합성 결과 "confirmed"(기본) | "unconfirmed"
  SIMPLELAY_MOTION_LOG_PATH       설정하면 모션 MCU와 주고받은 **원시 줄**을 이어 쓴다(기본 꺼짐).
                                  형식은 `python -m rpi.tools.jog --log`와 같고(보냄 ``>>``,
                                  받음 ``<<``) 두 번째 칸이 ``mono_ns=<monotonic ns>``다. 실행마다
                                  ``## job_start {"sequence_id":…}`` / ``## job_end …`` 줄을 찍는다.
                                  원시 기록기(SIMPLELAY_RECORDER_PATH)에도 같은 순간 ``job_start``·
                                  ``job_end`` 이벤트(note에 sequence_id)를 찍어 둘을 이을 수 있다.
  SIMPLELAY_ACT_PROGRESS          "0"이면 누름마다의 progress 프레임을 보내지 않는다(기본 보냄).
  SIMPLELAY_HOLD_STOP_CONFIRM_S   정지 버튼을 누른 뒤 전력 하강을 기다리는 시간(기본 5, 설계 초기값)
  SIMPLELAY_HOLD_MAX_S            정지 버튼 위 최대 대기(기본 1800, 설계 초기값)
  SIMPLELAY_HOLD_PRESS_GAP_S      정지 버튼 연속 누름 간격(기본 0.6, 설계 초기값)
  SIMPLELAY_HOLD_MOCK_RUN_S       mock 모션일 때 모의 가전 동작 시간(기본 30)
  SIMPLELAY_HOLD_MOCK_STOP        honor(기본) | ignore — 모의 가전이 정지 버튼에 반응하는지
                                  (정지 대기·보관·확인 주행: rpi4/services/stop_hold.py, 실물 미검증.
                                  serial 모드는 전력 리더가 없어 정지 판정이 늘 '미확인'이다)

Usage:
  python -m rpi4.act_main
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import sys
import threading
from collections.abc import Callable
from typing import TYPE_CHECKING, TextIO

from rpi.controller import ClosedLoopController
from rpi.controller.mock import MockAlertSink, MockGrblClient, MockSafetyController
from rpi.controller.ports import GrblClient, SafetyController
from rpi.services.demo_failure import DemoFailureState, FailureInjectionVerifier
from rpi.verifier import MockVerifier, Verifier

from .services.act_executor import ActExecutor

if TYPE_CHECKING:
    from rpi.tools.jog import LineLog
    from rpi.verifier.recorder import LiveRecorder

SERIAL_PORT = os.getenv("SIMPLELAY_UART_PORT", "/dev/ttyAMA0")
BAUD_RATE = int(os.getenv("SIMPLELAY_UART_BAUD", "115200"))


def _flag(name: str) -> bool:
    return os.getenv(name, "false").strip().lower() == "true"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
    stream=sys.stdout,
)
log = logging.getLogger(__name__)


def _build_verifier() -> Verifier:
    """SIMPLELAY_SENSORS_ENABLED=true면 실제 센서 퓨전 검증, 아니면 mock.

    SensorVerifier의 하드웨어 리더(Ads1115Reader·SounddeviceReader)는 생성
    시점에 장치를 연다 — 센서가 없는 보드에서 기본값이 mock이어야 실행
    경로 자체가 죽지 않는다.
    """
    if _flag("SIMPLELAY_SENSORS_ENABLED"):
        from rpi.verifier import SensorVerifier

        log.info("SensorVerifier active — ADS1115 current + microphone fusion")
        return SensorVerifier()
    log.info("MockVerifier active (set SIMPLELAY_SENSORS_ENABLED=true for real sensors)")
    return MockVerifier(outcomes=[True] * 1000)


def _open_motion_transport(port: str, baud: int):
    """실기기 시리얼 전송. 테스트는 이 함수를 바꿔 끼운다."""
    from rpi.controller.serial_motion import PySerialLineTransport

    return PySerialLineTransport(port, baud)


#: 연결 재시도 간격(초). 마지막 값에서 멈춰 그 간격으로 계속한다. 호스트 박자라 기구 값이 아니다.
MOTION_CONNECT_BACKOFF_S = (1.0, 2.0, 4.0, 8.0, 16.0, 30.0)


class MotionConnectRetry:
    """시작 때 연결 확인에 실패한 모션 MCU를 배경 스레드에서 다시 연결한다.

    ``client.connect()``가 성공할 때까지 backoff 간격으로 부른다(설정 누락은 재시도로 풀리지 않아
    부르지 않는다). 그동안 ``client.not_ready_reason()``이 이유를 돌려주고 ActExecutor가 execute를
    ``motion_not_ready``로 거절한다 — 조용히 누름마다 실패하지 않는다.
    """

    def __init__(self, client, backoff_s: tuple[float, ...] | None = None) -> None:
        self._client = client
        self._backoff_s = backoff_s or MOTION_CONNECT_BACKOFF_S
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True, name="motion-connect-retry")
        self.attempts = 0
        self.connected = threading.Event()

    def start(self) -> "MotionConnectRetry":
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()

    def join(self, timeout: float | None = None) -> None:
        self._thread.join(timeout)

    def _loop(self) -> None:
        from rpi.controller.serial_motion import MotionError

        index = 0
        while True:
            wait = self._backoff_s[min(index, len(self._backoff_s) - 1)]
            index += 1
            if self._stop.wait(wait):
                return
            self.attempts += 1
            try:
                status = self._client.connect()
            except (MotionError, RuntimeError, OSError) as exc:
                log.warning("motion MCU still not ready (retry %d, next in %.0fs): %s", self.attempts,
                            self._backoff_s[min(index, len(self._backoff_s) - 1)], exc)
                continue
            log.info("motion MCU connected on retry %d: state=%s homed=%s", self.attempts, status.state, status.homed)
            self.connected.set()
            return


#: act_main이 띄운 연결 재시도(없으면 None). 종료 때 멈춘다. 시험이 들여다본다.
_motion_retry: MotionConnectRetry | None = None


def _motion_readiness(grbl: object) -> "Callable[[], str | None] | None":
    """모션 어댑터가 준비 이유를 알려 주면 그 함수를(없으면 None — mock은 늘 준비됨)."""
    reason = getattr(grbl, "not_ready_reason", None)
    return reason if callable(reason) else None


def _build_motion_log() -> "tuple[LineLog, TextIO] | None":
    """SIMPLELAY_MOTION_LOG_PATH가 있으면 모션 MCU 원시 줄 기록을 연다(기본 꺼짐).

    켜짐/꺼짐과 경로를 항상 시작 로그에 남긴다. jog CLI의 줄 형식을 그대로 쓰되 시각
    칸은 monotonic ns — 원시 기록기·progress 프레임과 같은 시각축이다.
    """
    path = os.getenv("SIMPLELAY_MOTION_LOG_PATH", "").strip()
    if not path:
        log.info("motion line log off (set SIMPLELAY_MOTION_LOG_PATH to append raw MCU serial lines)")
        return None
    import pathlib

    from rpi.tools.jog import LineLog

    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    stream = open(target, "a", encoding="utf-8")
    log.info("motion line log ON -> %s (>> sent, << received, ## job markers; mono_ns time base)", target)
    return LineLog(stream, monotonic=True), stream


def _job_observer(recorder: "LiveRecorder | None", line_log: "LineLog | None"):
    """ActExecutor의 job_start/job_end를 모션 줄 기록과 원시 기록기에 같은 sequence_id로 찍는다."""
    if recorder is None and line_log is None:
        return None
    import json

    def observe(event: str, fields: dict) -> None:
        if line_log is not None:
            line_log.write("##", f"{event} {json.dumps(fields, ensure_ascii=False)}")
        if recorder is not None:
            note = f"sequence_id={fields.get('sequence_id')}"
            if "outcome" in fields:
                note += f" outcome={fields['outcome']}"
            recorder.recorder.mark(event, note)

    return observe


def _build_motion(on_event=None, line_log: "LineLog | None" = None) -> tuple[GrblClient, SafetyController]:
    """SIMPLELAY_MOTION_MODE=serial이면 모션 MCU 어댑터, 아니면(기본) mock.

    serial 어댑터는 **실물 미검증**이다. 포트·보드레이트가 없으면 시작을
    거절한다(추측한 장치로 열지 않는다). 기구·누름·타임아웃 값이 비어 있으면
    시작은 하되 누름마다 거절하고, 무엇이 비었는지 시작 로그에 남긴다.
    """
    mode = os.getenv("SIMPLELAY_MOTION_MODE", "mock").strip().lower() or "mock"
    if mode == "mock":
        log.info("MockGrblClient active (set SIMPLELAY_MOTION_MODE=serial for the motion MCU)")
        if line_log is not None:
            log.warning("motion line log has no MCU lines in mock mode (job markers only)")
        return MockGrblClient(), MockSafetyController()
    if mode != "serial":
        raise RuntimeError(f"unknown SIMPLELAY_MOTION_MODE={mode!r} (mock | serial)")

    from rpi.controller.serial_motion import (
        MotionConfig,
        MotionConfigError,
        MotionError,
        MotionSafetyController,
        SerialMotionClient,
        heartbeat_off_warning,
    )

    port = os.getenv("SIMPLELAY_MOTION_PORT", "").strip()
    baud_raw = os.getenv("SIMPLELAY_MOTION_BAUD", "").strip()
    if not port or not baud_raw:
        raise RuntimeError(
            "SIMPLELAY_MOTION_MODE=serial에는 SIMPLELAY_MOTION_PORT와 "
            "SIMPLELAY_MOTION_BAUD가 필요합니다(기본값 없음)"
        )
    config = MotionConfig.from_env()
    transport = _open_motion_transport(port, int(baud_raw))
    if line_log is not None:
        from rpi.tools.jog import LoggingTransport

        transport = LoggingTransport(transport, line_log)
    client = SerialMotionClient(transport, config, on_event=on_event)
    missing = config.missing_for_press()
    if missing:
        log.warning("motion config incomplete — every press will be refused: %s", ", ".join(missing))
    warning = heartbeat_off_warning(config)
    if warning:
        log.warning("%s", warning)
    global _motion_retry
    if _motion_retry is not None:
        _motion_retry.stop()
        _motion_retry = None
    try:
        status = client.connect()
        log.info("motion MCU on %s: state=%s homed=%s (실물 미검증 어댑터)", port, status.state, status.homed)
    except MotionConfigError as exc:
        # 설정 누락은 다시 시도해도 풀리지 않는다 — 준비 안 됨으로 남긴다.
        log.error("motion MCU status check impossible on %s: %s", port, exc)
    except (MotionError, RuntimeError, OSError) as exc:
        # 연결 확인 실패 = 준비 안 됨. 배경에서 다시 연결하고, 그동안 execute는 motion_not_ready로 거절한다.
        log.error("motion MCU status check failed on %s: %s — retrying in background", port, exc)
        _motion_retry = MotionConnectRetry(client).start()
    return client, MotionSafetyController(client)


def _optional_float(name: str) -> float | None:
    raw = os.getenv(name, "").strip()
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError as exc:
        raise RuntimeError(f"{name} 값을 숫자로 읽을 수 없습니다: {raw!r}") from exc


def _build_recorder(outlet=None) -> "LiveRecorder | None":
    """SIMPLELAY_RECORDER_PATH가 있으면 원시 기록기를 연다(기본 꺼짐).

    켜짐/꺼짐과 경로를 항상 시작 로그에 남긴다. 합성으로 대체된 입력은 경고로 남긴다 —
    기록 파일에서도 source가 ``mock_*``라 실측과 섞이지 않는다.
    """
    path = os.getenv("SIMPLELAY_RECORDER_PATH", "").strip()
    if not path:
        log.info("press recorder off (set SIMPLELAY_RECORDER_PATH to record raw samples around presses)")
        return None

    from rpi.verifier.recorder import LiveRecorder

    pre_s = _optional_float("SIMPLELAY_RECORDER_PRE_S")
    post_s = _optional_float("SIMPLELAY_RECORDER_POST_S")
    channel_raw = os.getenv("SIMPLELAY_RECORDER_ADC_CHANNEL", "0").strip() or "0"
    try:
        live = LiveRecorder(
            path,
            pre_s=pre_s,
            post_s=post_s,
            adc_gain=_optional_float("SIMPLELAY_RECORDER_ADC_GAIN"),
            adc_channel=int(channel_raw),
            audio=_flag("SIMPLELAY_RECORDER_AUDIO"),
            **({"power_sensor": outlet.sensor(), "power_mock": bool(outlet.mock),
                "power_reason": "콘센트 모듈(가짜 출력)" if outlet.mock else "콘센트 모듈 USB 시리얼"}
               if outlet is not None else {}),
        )
    except ValueError as exc:
        raise RuntimeError(f"recorder config invalid: {exc}") from exc
    window = f"window pre_s={pre_s} post_s={post_s}" if live.recorder.windowed else "no window (records everything)"
    log.info("press recorder ON -> %s (%s)", live.path, window)
    for choice in live.sources:
        if choice.mock:
            log.warning("press recorder source %s is MOCK (synthetic, not measured): %s", choice.kind, choice.reason)
        else:
            log.info("press recorder source %s is real: %s", choice.kind, choice.reason)
    return live


def _open_outlet_transport(port: str, baud: int):
    """콘센트 모듈 실기기 시리얼 전송. 테스트는 이 함수를 바꿔 끼운다."""
    from rpi.controller.serial_motion import PySerialLineTransport

    return PySerialLineTransport(port, baud)


#: act_main이 띄운 가짜 콘센트 모듈(SIMPLELAY_OUTLET_PORT=fake). 시험이 들여다본다.
_fake_outlet = None


def _build_outlet():
    """SIMPLELAY_OUTLET_PORT가 있으면 콘센트 모듈 링크를 연다(없으면 None). **실물 미검증.**

    fake면 가짜 출력에 붙고 링크를 ``mock=True``로 표시한다. 연결 확인(부팅 배너·status)에 실패해도
    시작은 한다 — 샘플이 오지 않으면 L3가 '센서를 읽지 못함'으로 멈추므로 숨겨지지 않는다.
    """
    global _fake_outlet
    port = os.getenv("SIMPLELAY_OUTLET_PORT", "").strip()
    if not port:
        log.info("outlet module off (set SIMPLELAY_OUTLET_PORT for the ESP32 CT/relay module)")
        return None
    from rpi.verifier.outlet import OutletConfig, OutletError, OutletLink

    config = OutletConfig.from_env()
    if port.lower() == "fake":
        from rpi.tools.fake_outlet import open_fake_outlet

        pipe, _fake_outlet = open_fake_outlet()
        link = OutletLink(pipe.host, config, mock=True).start()
        log.warning("outlet module is FAKE (synthetic power, rpi/tools/fake_outlet.py) — "
                    "L3 results are marked mock")
    else:
        baud_raw = os.getenv("SIMPLELAY_OUTLET_BAUD", "").strip()
        if not baud_raw:
            raise RuntimeError("SIMPLELAY_OUTLET_PORT에는 SIMPLELAY_OUTLET_BAUD가 필요합니다(기본값 없음)")
        try:
            baud = int(baud_raw)
        except ValueError as exc:
            raise RuntimeError(f"SIMPLELAY_OUTLET_BAUD 값을 정수로 읽을 수 없습니다: {baud_raw!r}") from exc
        link = OutletLink(_open_outlet_transport(port, baud), config).start()
        log.info("outlet module link on %s @ %d (실물 미검증)", port, baud)
    ready = link.wait_ready(3.0)
    if ready is None:
        log.error("outlet module did not answer (no ready banner / status) — power data will be "
                  "'stale' until it does")
    else:
        log.info("outlet module ready: %s", ready)
    if os.getenv("SIMPLELAY_OUTLET_RELAY_ON_START", "").strip() == "1":
        try:
            link.relay_on()
            log.warning("outlet relay ON at start (SIMPLELAY_OUTLET_RELAY_ON_START=1)")
        except OutletError as exc:
            log.error("outlet relay_on at start failed: %s", exc)
    else:
        log.warning("outlet relay left as the module booted (default OFF = appliance unpowered); "
                    "set SIMPLELAY_OUTLET_RELAY_ON_START=1 to switch it on at start")
    return link


def _build_operation_verifier(outlet=None):
    """SIMPLELAY_L3_MODE로 L3 검증기를 고른다(기본 off). real은 콘센트 모듈이 없으면 거절한다."""
    from rpi.controller.power_operation import OutletOperationVerifier, operation_verifier_from_env

    fake = _fake_outlet if outlet is not None and getattr(outlet, "mock", False) else None
    verifier = operation_verifier_from_env(
        outlet=outlet, on_sequence_done=fake.start_run if fake is not None else None)
    if verifier is None:
        log.info("L3 operation verifier off (set SIMPLELAY_L3_MODE=mock to rehearse; "
                 "result frames carry operation_confirmed=null)")
    elif isinstance(verifier, OutletOperationVerifier):
        if verifier.mock:
            log.warning("L3 operation verifier reads the FAKE outlet — results are marked mock")
        else:
            log.warning("L3 operation verifier reads the outlet module power stream (실물 미검증)")
    else:
        log.warning("L3 operation verifier is MOCK (synthetic power, outcome=%s) — "
                    "not evidence of real appliance operation", verifier.outcome)
    return verifier


def _build_hold(grbl: object, raw_grbl: object, outlet=None):
    """정지 대기·확인 주행 부품. mock 모션이면 모의 가전까지, 실제 어댑터면 move_to·press만.
    콘센트 모듈이 있으면 실제 어댑터의 가전 켜짐 확인을 그 전력으로 한다."""
    from rpi.controller.mock import MockGrblClient as _Mock

    from .services.stop_hold import mock_hold_hardware, real_hold_hardware

    if isinstance(raw_grbl, _Mock):
        log.info("stop hold: MOCK motion + mock appliance (SIMPLELAY_HOLD_MOCK_*)")
        return mock_hold_hardware()
    if outlet is not None:
        from rpi.verifier.power_tail import TailConfig

        from .services.outlet_watch import OutletRunProbe

        tail_config = TailConfig.from_env()
        log.warning("stop hold: real motion adapter + outlet power probe (실물 미검증)")
        return real_hold_hardware(grbl, raw_grbl,
                                  probe_factory=lambda plan: OutletRunProbe(outlet, tail_config))
    log.warning("stop hold: real motion adapter (move_to/press), no power reader — "
                "stop judgement stays 'unconfirmed' (실물 미검증)")
    return real_hold_hardware(grbl, raw_grbl)


def _build_executor(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    recorder: "LiveRecorder | None" = None,
    motion_log: "LineLog | None" = None,
    outlet=None,
) -> ActExecutor:
    """Wire up the executor with current adapters.

    GrblClient는 기본 mock. SIMPLELAY_MOTION_MODE=serial이면 모션 MCU 어댑터
    (실물 미검증)를 꽂는다. Verifier는 env로 실물 전환 가능. L3는 SIMPLELAY_L3_MODE.
    """
    # 데모 실패 주입(POST /demo/inject-failure → UART inject_failure)이 UART
    # 모드에서도 통하도록, RPi5와 동일하게 verifier를 래핑하고 같은 상태를
    # ActExecutor에 넘긴다 — 결선 리허설 장면이 실기기 구성에서도 성립한다.
    failure_state = DemoFailureState()
    # 시리얼을 열기 전에 끝나는 설정 검사가 좋지만, 모션보다 먼저 확인해 real L3 거절이
    # 모터 연결 시도보다 앞서게 한다.
    operation = _build_operation_verifier(outlet)
    if recorder is None:
        # 줄 기록이 없으면 종전 호출 모양 그대로
        grbl, safety = _build_motion(**({"line_log": motion_log} if motion_log is not None else {}))
        readiness = _motion_readiness(grbl)
        raw_grbl = grbl
    else:
        from rpi.verifier.recorder import RecordingGrblClient, motion_event_hook

        # 모션 MCU 이벤트(mcu_press_start 등)는 어댑터 훅으로, 호스트 호출 시각은 래퍼로 찍는다.
        grbl, safety = _build_motion(on_event=motion_event_hook(recorder.recorder),
                                     **({"line_log": motion_log} if motion_log is not None else {}))
        readiness = _motion_readiness(grbl)
        raw_grbl = grbl
        grbl = RecordingGrblClient(grbl, recorder.recorder)
    controller = ClosedLoopController(
        grbl=grbl,
        verifier=FailureInjectionVerifier(_build_verifier(), failure_state),
        alerts=MockAlertSink(),
        safety=safety,
        operation=operation,
    )
    from .services.act_executor import progress_enabled_from_env

    log.info("progress frames %s (SIMPLELAY_ACT_PROGRESS; old RPi5 ignores them)",
             "ON" if progress_enabled_from_env() else "off")
    extra: dict = {}
    if readiness is not None:
        extra["readiness"] = readiness
    if outlet is not None and operation is not None and hasattr(operation, "last_verdict"):
        from rpi.verifier.power_tail import TailConfig

        from .services.outlet_watch import OutletTailHook

        extra["after_result"] = OutletTailHook(outlet, operation, config=TailConfig.from_env(),
                                               recorder=recorder.recorder if recorder is not None else None)
    executor = ActExecutor(
        reader=reader,
        writer=writer,
        controller=controller,
        failure_state=failure_state,
        job_observer=_job_observer(recorder, motion_log),
        hold=_build_hold(grbl, raw_grbl, outlet),
        **extra,
    )
    if outlet is not None:
        _wire_outlet_estop(outlet, executor)
    return executor


def _wire_outlet_estop(outlet, executor: ActExecutor) -> None:
    """콘센트 모듈 ``estop`` 이벤트 → 실행기 정지 경로(이벤트 루프 스레드로 넘긴다).

    모듈은 이미 스스로 릴레이를 열었다. 여기서는 구동부 정지와 RPi5 알림만 한다.
    실행 중인 이벤트 루프가 없으면(시험 등) 배선하지 않고 경고만 남긴다.
    """
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        log.warning("outlet estop events not wired to the executor (no running event loop)")
        return

    def on_event(doc: dict) -> None:
        if doc.get("event") != "estop":
            return
        source = doc.get("source") if isinstance(doc.get("source"), str) else "button"
        try:
            loop.call_soon_threadsafe(executor.handle_outlet_estop, source)
        except RuntimeError:  # 루프가 닫힌 뒤
            log.error("outlet estop arrived after the event loop closed — drive stop not requested")

    outlet.add_listener(on_event)


def _maybe_start_danger_monitor(executor: ActExecutor) -> "asyncio.Task[None] | None":
    """위험소리 감지 태스크 — 코드·테스트는 완성돼 있었지만 그동안 어느
    엔트리포인트도 기동하지 않아 /alerts가 실기기에서도 절대 울리지 않았다.

    검증용과 별개의 SounddeviceReader 인스턴스를 연다 — 같은 마이크에 입력
    스트림 2개가 공존하는지는 실기기에서 확인 필요(문제 시 프레임 팬아웃
    공유 리더로 교체).
    """
    if not _flag("SIMPLELAY_DANGER_SOUND_ENABLED"):
        log.info(
            "DangerSoundMonitor off (set SIMPLELAY_DANGER_SOUND_ENABLED=true to enable)"
        )
        return None

    from rpi.verifier import SensorConfig
    from rpi.verifier.audio_sensor import SounddeviceReader

    from .services.danger_sound_monitor import DangerSoundMonitor

    reader = SounddeviceReader(SensorConfig().audio)
    monitor = DangerSoundMonitor(reader, executor)
    log.info("DangerSoundMonitor active — continuous alarm-sound detection")
    return asyncio.create_task(monitor.run())


async def _run() -> None:
    log.info("Opening %s at %d baud", SERIAL_PORT, BAUD_RATE)
    try:
        import serial_asyncio  # type: ignore[import-untyped]
    except ImportError:
        log.error(
            "pyserial-asyncio not installed.\n"
            "Install with:  pip install pyserial-asyncio\n"
            "Then retry:    python -m rpi4.act_main"
        )
        sys.exit(1)

    reader, writer = await serial_asyncio.open_serial_connection(
        url=SERIAL_PORT,
        baudrate=BAUD_RATE,
    )
    log.info("Serial open — waiting for RPi5 execute commands")
    outlet = _build_outlet()
    recorder = _build_recorder(outlet)
    motion_log = _build_motion_log()
    try:
        executor = _build_executor(reader, writer, recorder, motion_log[0] if motion_log else None,
                                   outlet=outlet)
    except BaseException:
        if outlet is not None:
            outlet.close()
        if recorder is not None:
            recorder.close()
        if motion_log is not None:
            motion_log[1].close()
        raise
    if recorder is not None:
        recorder.start()
    monitor_task = _maybe_start_danger_monitor(executor)
    try:
        await executor.run()
    finally:
        # run()이 취소가 아닌 이유(EOF 등)로 빠져나왔을 때도 진행 중이던
        # 물리 실행을 방치하지 않는다 — 이미 멈췄으면 즉시 반환한다.
        with contextlib.suppress(asyncio.CancelledError):
            await executor.shutdown()
        if monitor_task is not None:
            monitor_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await monitor_task
        if _motion_retry is not None:
            _motion_retry.stop()
        if recorder is not None:
            recorder.close()
        if motion_log is not None:
            motion_log[1].close()
        if outlet is not None:
            outlet.close()
        if _fake_outlet is not None:
            _fake_outlet.close()


if __name__ == "__main__":
    asyncio.run(_run())
