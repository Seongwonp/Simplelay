"""누름 이벤트 주변 원시 센서 기록기 — **판정하지 않는다**.

임계값(`config.py`의 전류 문턱·음향 대역 비율·전력 상승 비율)은 전부 실측 전
추정값이다. 이 모듈은 그 값을 바꿀 근거를 모으는 쪽이다: 전류 ADC 전압·음향
프레임·소비전력 샘플을 호스트 단조 시각과 함께 그대로 남기고, 모션 쪽 누름
이벤트(press_start/press_end 등)를 같은 시각축에 찍는다.

기존 판독 인터페이스를 그대로 쓴다 — 실기기 리더를 새로 만들지 않는다.
  - 전류:  `CurrentReader.read_voltage()` (ADS1115 → 전압 V). **A로 환산하지 않는다**:
           영점 전압·감도는 실측 전 추정값이라 환산하는 순간 가정이 기록에 섞인다.
  - 음향:  `AudioReader.read_frame()` → RMS·피크·샘플 수. JSONL에서는 원시 PCM도 선택.
  - 전력:  `PowerSensor.read()` → `PowerSample(t_s, watts)` (센서 시각도 함께 남긴다).
판정기(`CurrentSensor.is_pressed`, `AudioSensor`, `fuse`, `PowerSignatureDetector`)는
import하지 않는다(테스트가 고정한다).

`rpi/bench/raw_recorder.py`(2026-09-14)와의 관계: 그쪽은 벤치에서 사람이 키보드로
누름을 찍는 CSV 도구다(ADS1115 정수 판독값까지 남김, verifier 비의존). 이 모듈은
**실행 경로에 끼우는** 기록기다 — `RecordingGrblClient`가 누름 호출 앞뒤를,
`motion_event_hook`이 모션 어댑터 이벤트를 자동으로 찍고, 전력 샘플과 JSONL을 지원하며,
누름 전후 창만 남기는 모드가 있다.

창 모드: ``pre_s``·``post_s``를 주면 샘플을 링 버퍼에 두었다가
``[press_start − pre_s, press_end + post_s]`` 안의 것만 남긴다. 창 길이는 **측정 필요**
값이라 기본은 창 없음(전부 기록)이다.

시각의 한계(측정 필요): 행 시각은 판독이 끝난 직후의 호스트 단조 시각이다. I2C 변환
지연·음향 장치 버퍼 지연·MCU 이벤트의 시리얼 지연은 포함하지 않는다.

상시 기록(`LiveRecorder`): `rpi4/act_main.py`가 ``SIMPLELAY_RECORDER_PATH``를 받으면 켠다.
실기기 리더가 없거나 켜지 않은 입력은 합성으로 대체하되 행의 source를 ``mock_*``로 적는다.

CLI:
    python -m rpi.verifier.recorder --mock --duration 2 --out data/bench/rec.jsonl
    python -m rpi.verifier.recorder --current --adc-gain 1 --audio --duration 60
원시 데이터는 저장소에 올리지 않는다. 기본 경로 ``data/bench/``는 .gitignore 대상이다.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
import threading
import time
from collections import deque
from collections.abc import Callable, Sequence
from datetime import datetime
from pathlib import Path
from typing import Any, TextIO

import numpy as np

from rpi.controller.models import PressCommand
from rpi.controller.ports import GrblClient

from .audio_sensor import AudioReader, FakeAudioReader
from .current_sensor import CurrentReader, FakeCurrentReader
from .power import MockPowerSensor, PowerSample, PowerSensor

#: CSV 열(고정). JSONL도 같은 키를 쓰고, 값이 없는 키는 뺀다.
COLUMNS: tuple[str, ...] = (
    "t_monotonic_ns",
    "source",
    "current_voltage",
    "power_watts",
    "power_sensor_t_s",
    "audio_rms",
    "audio_peak",
    "audio_samples",
    "event",
    "note",
    # 잔여 전류 꼬리(피드백 ③, 2026-10-05) — ``power_tail`` 이벤트 행에만 값이 있다. 뒤에 붙인다
    # (앞 열 순서를 읽는 기존 분석을 깨지 않게). 정의·기준은 rpi/verifier/power_tail.py(측정 필요).
    "tail_status",
    "tail_s",
    "tail_mean_w",
    "tail_max_w",
    "pre_baseline_w",
    "post_baseline_w",
)

#: ``record_power_tail``이 받는 측정값 키 → 열 이름.
_TAIL_FIELDS = {
    "status": "tail_status",
    "tail_s": "tail_s",
    "tail_mean_w": "tail_mean_w",
    "tail_max_w": "tail_max_w",
    "pre_baseline_w": "pre_baseline_w",
    "post_baseline_w": "post_baseline_w",
}

#: 이벤트 이름 규칙. 모션 어댑터 이벤트(press_command·alarm 등)도 받도록 목록이 아니라
#: 형식으로 제한한다 — CSV 한 칸을 깨는 문자만 막는다.
_EVENT_NAME = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
WINDOW_OPEN_EVENT = "press_start"
WINDOW_CLOSE_EVENT = "press_end"

DEFAULT_OUT_DIR = Path("data") / "bench"


# ── 기록 대상(싱크) ─────────────────────────────────────────────────────────


class CsvSink:
    def __init__(self, stream: TextIO, *, header: bool = True) -> None:
        self._stream = stream
        self._writer = csv.writer(stream, lineterminator="\n")
        if header:  # 기존 파일에 이어 쓸 때는 머리행을 다시 쓰지 않는다
            self._writer.writerow(COLUMNS)

    def write(self, row: dict[str, Any]) -> None:
        self._writer.writerow([_csv_cell(row.get(column)) for column in COLUMNS])

    def flush(self) -> None:
        self._stream.flush()


class JsonlSink:
    def __init__(self, stream: TextIO) -> None:
        self._stream = stream

    def write(self, row: dict[str, Any]) -> None:
        clean = {k: v for k, v in row.items() if v is not None}
        self._stream.write(json.dumps(clean, ensure_ascii=False, allow_nan=True) + "\n")

    def flush(self) -> None:
        self._stream.flush()


def _csv_cell(value: object) -> object:
    if value is None:
        return ""
    if isinstance(value, float):
        return repr(value)  # 반올림하지 않는다
    return value


# ── 기록기 ─────────────────────────────────────────────────────────────────


class PressWindowRecorder:
    """스레드 안전 기록기. ``pre_s``·``post_s``가 없으면 전부 기록한다."""

    def __init__(
        self,
        sink: CsvSink | JsonlSink,
        *,
        clock: Callable[[], int] = time.monotonic_ns,
        pre_s: float | None = None,
        post_s: float | None = None,
        keep_audio_samples: bool = False,
        ring_limit: int = 100_000,
    ) -> None:
        if (pre_s is None) != (post_s is None):
            raise ValueError("pre_s와 post_s는 함께 주거나 함께 비워야 합니다")
        for name, value in (("pre_s", pre_s), ("post_s", post_s)):
            if value is not None and not (math.isfinite(value) and value >= 0):
                raise ValueError(f"{name}는 0 이상의 유한한 수여야 합니다: {value!r}")
        self._sink = sink
        self._clock = clock
        self._windowed = pre_s is not None
        self._pre_ns = int((pre_s or 0) * 1e9)
        self._post_ns = int((post_s or 0) * 1e9)
        self._keep_audio_samples = keep_audio_samples
        self._lock = threading.Lock()
        self._ring: deque[dict[str, Any]] = deque(maxlen=ring_limit)
        self._open_presses = 0
        self._close_until_ns: int | None = None
        self.rows = 0

    @property
    def windowed(self) -> bool:
        return self._windowed

    def now_ns(self) -> int:
        return self._clock()

    # 샘플 ------------------------------------------------------------------

    # ``source``: 행의 source 칸. 합성 입력은 ``mock_current``처럼 따로 적어 실측과 섞이지 않게 한다.

    def record_current_voltage(
        self, voltage: float, t_ns: int | None = None, *, source: str = "current"
    ) -> None:
        self._sample(t_ns, source, current_voltage=float(voltage))

    def record_power(self, sample: PowerSample, t_ns: int | None = None, *, source: str = "power") -> None:
        self._sample(t_ns, source, power_watts=float(sample.watts), power_sensor_t_s=float(sample.t_s))

    def record_audio_frame(
        self, frame: Sequence[float] | np.ndarray, t_ns: int | None = None, *, source: str = "audio"
    ) -> None:
        block = np.asarray(frame, dtype=np.float64).ravel()
        fields: dict[str, Any] = {"audio_samples": int(block.size)}
        if block.size:
            fields["audio_rms"] = float(np.sqrt(np.mean(block * block)))
            fields["audio_peak"] = float(np.max(np.abs(block)))
        if self._keep_audio_samples and isinstance(self._sink, JsonlSink):
            fields["audio_pcm"] = [float(v) for v in block]
        self._sample(t_ns, source, **fields)

    # 이벤트 ----------------------------------------------------------------

    def mark(self, event: str, note: str = "", t_ns: int | None = None) -> None:
        """이벤트를 찍는다. 창 모드에서는 press_start가 창을 열고 press_end가 닫는다."""
        if not isinstance(event, str) or not _EVENT_NAME.match(event):
            raise ValueError(f"이벤트 이름 형식이 아닙니다: {event!r} (소문자·숫자·밑줄)")
        with self._lock:
            t = self._clock() if t_ns is None else int(t_ns)
            row = {"t_monotonic_ns": t, "source": "event", "event": event, "note": note or None}
            if not self._windowed:
                self._emit(row)
                return
            if event == WINDOW_OPEN_EVENT:
                if self._open_presses == 0 and self._close_until_ns is None:
                    self._flush_ring_since(t - self._pre_ns)
                self._open_presses += 1
            elif event == WINDOW_CLOSE_EVENT and self._open_presses > 0:
                self._open_presses -= 1
                if self._open_presses == 0:
                    self._close_until_ns = t + self._post_ns
            # 이벤트 행은 창과 무관하게 항상 남긴다 — 어디서 무엇이 일어났는지가 기록의 뼈대다.
            self._emit(row)

    def record_power_tail(self, metrics: dict[str, Any], note: str = "", t_ns: int | None = None) -> None:
        """잔여 전류 꼬리 측정값 한 행(``event=power_tail``). 창과 무관하게 항상 남긴다.

        ``metrics``는 `rpi.verifier.power_tail.TailMetrics.as_dict()` 모양의 dict다 — 이 모듈은
        측정 코드를 import하지 않고 값만 옮긴다. ``source``(real|mock)는 행의 source 칸이 된다.
        """
        source = "power_tail" if metrics.get("source", "real") == "real" else "mock_power_tail"
        with self._lock:
            t = self._clock() if t_ns is None else int(t_ns)
            row: dict[str, Any] = {"t_monotonic_ns": t, "source": source, "event": "power_tail",
                                   "note": note or None}
            for key, column in _TAIL_FIELDS.items():
                value = metrics.get(key)
                if value is not None:
                    row[column] = value
            self._emit(row)
            self._sink.flush()

    def flush(self) -> None:
        with self._lock:
            self._sink.flush()

    # 내부 ------------------------------------------------------------------

    def _sample(self, t_ns: int | None, source: str, **fields: Any) -> None:
        with self._lock:
            t = self._clock() if t_ns is None else int(t_ns)
            row = {"t_monotonic_ns": t, "source": source, **fields}
            if not self._windowed or self._window_open(t):
                self._emit(row)
            else:
                self._ring.append(row)

    def _window_open(self, t: int) -> bool:
        if self._open_presses > 0:
            return True
        if self._close_until_ns is not None:
            if t <= self._close_until_ns:
                return True
            self._close_until_ns = None
        return False

    def _flush_ring_since(self, since_ns: int) -> None:
        for row in self._ring:
            if row["t_monotonic_ns"] >= since_ns:
                self._emit(row)
        self._ring.clear()

    def _emit(self, row: dict[str, Any]) -> None:
        self._sink.write(row)
        self.rows += 1


# ── 실행 경로 훅 ───────────────────────────────────────────────────────────


class RecordingGrblClient(GrblClient):
    """어떤 GrblClient든 감싸 누름 호출 앞뒤에 press_start/press_end를 찍는다.

    감싼 대상의 실행 모드·좌표 요구·정지 훅을 그대로 드러낸다 — 기록기를 끼웠다고
    실행 이력이 모의/실제를 잘못 말하면 안 된다. 시각은 **호스트 호출 시각**이다.
    MCU가 보내는 실제 Z 하강·복귀 시각은 `motion_event_hook`으로 따로 들어온다.
    """

    def __init__(self, inner: GrblClient, recorder: PressWindowRecorder) -> None:
        self._inner = inner
        self._recorder = recorder
        self.execution_mode = getattr(inner, "execution_mode", self.execution_mode)
        self.requires_coordinates = getattr(inner, "requires_coordinates", False) is True

    def press(self, command: PressCommand) -> None:
        self._recorder.mark("press_start", _press_note(command))
        try:
            self._inner.press(command)
        except Exception as exc:
            self._recorder.mark("error", f"{command.button}: {exc}")
            raise
        finally:
            self._recorder.mark("press_end", command.button)

    @property
    def last_position(self) -> dict | None:
        """감싼 어댑터의 MCU 위치 보고를 그대로 드러낸다(없으면 None)."""
        return getattr(self._inner, "last_position", None)

    def request_stop(self) -> None:
        stop = getattr(self._inner, "request_stop", None)
        if callable(stop):
            stop()

    def reset_stop(self) -> None:
        reset = getattr(self._inner, "reset_stop", None)
        if callable(reset):
            reset()


def motion_event_hook(recorder: PressWindowRecorder) -> Callable[[str, dict], None]:
    """`SerialMotionClient(on_event=...)`에 넘길 훅. MCU 이벤트를 ``mcu_`` 접두로 찍는다.

    접두를 붙이는 이유: 호스트 호출 시각(press_start)과 MCU 보고 시각(mcu_press_start)은
    같은 사건의 다른 관측이다. 섞으면 시리얼 지연을 잴 수 없다.
    """

    def _hook(name: str, fields: dict) -> None:
        event = "mcu_" + re.sub(r"[^a-z0-9_]", "_", str(name).lower())[:27]
        note = json.dumps({k: v for k, v in fields.items() if k != "event"}, ensure_ascii=False)
        recorder.mark(event, note)

    return _hook


def _press_note(command: PressCommand) -> str:
    parts = [command.button]
    if command.has_coordinates:
        parts.append(f"x_mm={command.x_mm} y_mm={command.y_mm}")
    if command.correction is not None:
        parts.append(f"retry={command.correction.retry_number}")
    return " ".join(parts)


# ── 샘플링 루프 ────────────────────────────────────────────────────────────


def run_source_loop(
    read: Callable[[], None],
    recorder: PressWindowRecorder,
    stop: threading.Event,
    period_s: float = 0.0,
    label: str = "source",
) -> None:
    """stop까지 ``read()``를 반복한다. 판독 오류는 error 이벤트로 남기고 계속한다."""
    while not stop.is_set():
        try:
            read()
        except Exception as exc:  # noqa: BLE001 - 오류도 기록 대상이다
            recorder.mark("error", f"{label}: {exc}")
            if stop.wait(max(period_s, 0.05)):
                break
            continue
        if period_s > 0 and stop.wait(period_s):
            break


def current_reader_step(
    reader: CurrentReader, recorder: PressWindowRecorder, source: str = "current"
) -> Callable[[], None]:
    return lambda: recorder.record_current_voltage(reader.read_voltage(), source=source)


def audio_reader_step(
    reader: AudioReader, recorder: PressWindowRecorder, source: str = "audio"
) -> Callable[[], None]:
    return lambda: recorder.record_audio_frame(reader.read_frame(), source=source)


def power_sensor_step(
    sensor: PowerSensor, recorder: PressWindowRecorder, source: str = "power"
) -> Callable[[], None]:
    return lambda: recorder.record_power(sensor.read(), source=source)


# ── 모의 입력(시험·CLI --mock) ─────────────────────────────────────────────


def mock_sources(n: int = 256) -> tuple[FakeCurrentReader, FakeAudioReader, MockPowerSensor]:
    """결정적 합성 값. **실측이 아니다** — 기록 경로 점검용이며 임계값 근거로 쓰지 않는다."""
    voltages = [2.5 + 0.01 * math.sin(i / 7.0) for i in range(n)]
    frames = [
        (0.05 * np.sin(np.linspace(0, 2 * math.pi * (i % 5 + 1), 512))).astype(np.float32)
        for i in range(8)
    ]
    power = [PowerSample(t_s=i * 0.1, watts=3.0 + (i % 10)) for i in range(n)]
    return FakeCurrentReader(voltages), FakeAudioReader(frames), MockPowerSensor(power)


# ── 실행 경로 상시 기록(act_main 배선) ─────────────────────────────────────


class SourceChoice:
    """한 입력의 선택 결과. ``mock``이면 행의 source가 ``mock_*``로 찍힌다."""

    def __init__(self, kind: str, mock: bool, reason: str) -> None:
        self.kind = kind
        self.mock = mock
        self.reason = reason

    @property
    def label(self) -> str:
        return f"mock_{self.kind}" if self.mock else self.kind

    def __repr__(self) -> str:  # 로그용
        return f"{self.label}({self.reason})"


class LiveRecorder:
    """파일 하나에 이어 쓰며 전류·음향·전력 샘플을 백그라운드로 계속 기록한다.

    실기기 리더를 열 수 없거나 켜지 않은 입력은 **합성 입력으로 대체하되 숨기지 않는다**:
    행의 source를 ``mock_current``/``mock_audio``/``mock_power``로 적고, 시작 이벤트
    메모와 ``sources``에 무엇이 합성인지 남긴다. 합성 값은 실측이 아니다.

    - 전류: ``adc_gain``이 있을 때만 ADS1115를 연다(기본값 없음 — CLI와 같은 규칙).
    - 음향: ``audio=True``일 때만 마이크를 연다(위험소리 감지와 같은 마이크를 쓸 수 있어 기본 꺼짐).
    - 전력: ``power_sensor``(콘센트 모듈 `SerialPowerSensor` 등)를 주면 그것을 읽는다. 없으면 합성.
      ``power_mock=True``면(가짜 출력) 행의 source를 ``mock_power``로 적는다.
    """

    def __init__(
        self,
        path: str | Path,
        *,
        pre_s: float | None = None,
        post_s: float | None = None,
        adc_gain: float | None = None,
        adc_channel: int = 0,
        audio: bool = False,
        current_period_s: float = 0.0,
        open_current: Callable[[float, int], CurrentReader] | None = None,
        open_audio: Callable[[], AudioReader] | None = None,
        power_sensor: PowerSensor | None = None,
        power_mock: bool = False,
        power_reason: str = "콘센트 모듈",
    ) -> None:
        if (pre_s is None) != (post_s is None):
            raise ValueError("pre_s와 post_s는 함께 주거나 함께 비워야 합니다")
        for name, value in (("pre_s", pre_s), ("post_s", post_s)):
            if value is not None and not (math.isfinite(value) and value >= 0):
                raise ValueError(f"{name}는 0 이상의 유한한 수여야 합니다: {value!r}")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fmt = "csv" if self.path.suffix.lower() == ".csv" else "jsonl"
        fresh = not self.path.exists() or self.path.stat().st_size == 0
        self._handle = self.path.open("a", newline="", encoding="utf-8")
        sink: CsvSink | JsonlSink = CsvSink(self._handle, header=fresh) if fmt == "csv" else JsonlSink(self._handle)
        self.recorder = PressWindowRecorder(sink, pre_s=pre_s, post_s=post_s)
        self._stop = threading.Event()
        self._workers: list[threading.Thread] = []
        self._closers: list[Callable[[], None]] = []
        self.sources: list[SourceChoice] = []

        mock_current, mock_audio, mock_power = mock_sources()
        steps: list[tuple[SourceChoice, Callable[[], None], float]] = []

        # 전류
        current: CurrentReader | None = None
        if adc_gain is None:
            choice = SourceChoice("current", True, "ADC gain 미설정")
        else:
            try:
                current = (open_current or _open_ads1115)(adc_gain, adc_channel)
                choice = SourceChoice("current", False, f"ADS1115 gain={adc_gain:g} ch={adc_channel}")
            except Exception as exc:  # noqa: BLE001 - 열기 실패는 합성으로 대체하고 이유를 남긴다
                choice = SourceChoice("current", True, f"ADS1115 열기 실패: {exc}")
        reader = current if current is not None else mock_current
        period = current_period_s if current is not None else max(current_period_s, 0.01)
        steps.append((choice, current_reader_step(reader, self.recorder, choice.label), period))
        self.sources.append(choice)

        # 음향
        audio_reader: AudioReader | None = None
        if not audio:
            choice = SourceChoice("audio", True, "마이크 기록 꺼짐")
        else:
            try:
                audio_reader = (open_audio or _open_microphone)()
                self._closers.append(audio_reader.close)
                choice = SourceChoice("audio", False, "마이크")
            except Exception as exc:  # noqa: BLE001
                choice = SourceChoice("audio", True, f"마이크 열기 실패: {exc}")
        steps.append(
            (
                choice,
                audio_reader_step(audio_reader or mock_audio, self.recorder, choice.label),
                0.0 if audio_reader is not None else 0.032,
            )
        )
        self.sources.append(choice)

        # 전력
        if power_sensor is None:
            choice = SourceChoice("power", True, "실기기 전력 리더 없음")
            steps.append((choice, power_sensor_step(mock_power, self.recorder, choice.label), 0.1))
        else:
            # 센서 read()가 다음 샘플까지 기다린다(끊기면 예외 → error 행). 추가 대기 없이 돈다.
            choice = SourceChoice("power", power_mock, power_reason)
            steps.append((choice, power_sensor_step(power_sensor, self.recorder, choice.label), 0.0))
        self.sources.append(choice)

        self._steps = steps
        self.recorder.mark(
            "marker",
            "live start sources=" + ", ".join(repr(c) for c in self.sources)
            + f" pre_s={pre_s} post_s={post_s}",
        )
        self.recorder.flush()

    @property
    def mock_sources(self) -> list[str]:
        return [c.label for c in self.sources if c.mock]

    def start(self) -> None:
        for choice, step, period in self._steps:
            worker = threading.Thread(
                target=run_source_loop,
                args=(step, self.recorder, self._stop, period, choice.label),
                daemon=True,
                name=f"recorder-{choice.label}",
            )
            self._workers.append(worker)
            worker.start()

    def close(self) -> None:
        self._stop.set()
        for worker in self._workers:
            worker.join(timeout=2.0)
        for close in self._closers:
            try:
                close()
            except Exception:  # noqa: BLE001
                pass
        try:
            self.recorder.mark("marker", "live end")
            self.recorder.flush()
        finally:
            self._handle.close()


def _open_ads1115(gain: float, channel: int) -> CurrentReader:
    from .config import CurrentSensorConfig  # noqa: PLC0415
    from .current_sensor import Ads1115Reader  # noqa: PLC0415

    value = int(gain) if float(gain).is_integer() else gain
    return Ads1115Reader(CurrentSensorConfig(ads_gain=value, channel=channel))  # type: ignore[arg-type]


def _open_microphone() -> AudioReader:
    from .audio_sensor import SounddeviceReader  # noqa: PLC0415
    from .config import AudioSensorConfig  # noqa: PLC0415

    return SounddeviceReader(AudioSensorConfig())


# ── CLI ───────────────────────────────────────────────────────────────────


def default_out_path(fmt: str, now: datetime | None = None) -> Path:
    stamp = (now or datetime.now()).strftime("%Y%m%d-%H%M%S")
    return DEFAULT_OUT_DIR / f"press-raw-{stamp}.{fmt}"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m rpi.verifier.recorder",
        description="누름 이벤트 주변 원시 센서 값을 기록한다(판정 없음).",
    )
    parser.add_argument("--out", help="출력 경로 (기본: data/bench/press-raw-<시각>.<형식>)")
    parser.add_argument("--format", choices=("jsonl", "csv"), default="jsonl")
    parser.add_argument("--duration", type=float, default=0.0, help="초. 0이면 q 입력까지")
    parser.add_argument("--period", type=float, default=0.0, help="전류·전력 판독 사이 대기(초)")
    parser.add_argument("--pre-s", type=float, default=None, help="창 모드: press_start 전 보존(초)")
    parser.add_argument("--post-s", type=float, default=None, help="창 모드: press_end 후 보존(초)")
    parser.add_argument("--mock", action="store_true", help="합성 입력(전류·음향·전력) — 실측 아님")
    parser.add_argument("--current", action="store_true", help="ADS1115 전류 채널 전압")
    parser.add_argument("--adc-gain", type=float, default=None, help="ADS1115 gain. 기본값 없음(포화 방지)")
    parser.add_argument("--adc-channel", type=int, choices=range(4), default=0)
    parser.add_argument("--audio", action="store_true", help="마이크 프레임 레벨")
    parser.add_argument("--audio-pcm", action="store_true", help="JSONL에 원시 PCM도 남긴다")
    parser.add_argument("--no-stdin", action="store_true", help="키보드 이벤트 입력을 읽지 않는다")
    return parser


def _open_sink(fmt: str, handle: TextIO) -> CsvSink | JsonlSink:
    return CsvSink(handle) if fmt == "csv" else JsonlSink(handle)


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not (args.mock or args.current or args.audio):
        parser.error("--mock, --current, --audio 중 하나 이상이 필요하다")
    if args.mock and (args.current or args.audio):
        parser.error("--mock은 실기기 입력과 섞지 않는다(기록에 합성 값이 섞인다)")
    if args.current and args.adc_gain is None:
        parser.error("--current에는 --adc-gain이 필요하다 (기본값 없음: 무전류 전압 확인 후 고른다)")
    if (args.pre_s is None) != (args.post_s is None):
        parser.error("--pre-s와 --post-s는 함께 준다")
    if args.mock and args.duration <= 0:
        parser.error("--mock에는 --duration이 필요하다")

    out = Path(args.out) if args.out else default_out_path(args.format)
    out.parent.mkdir(parents=True, exist_ok=True)
    stop = threading.Event()
    workers: list[threading.Thread] = []
    closers: list[Callable[[], None]] = []

    with out.open("w", newline="", encoding="utf-8") as handle:
        recorder = PressWindowRecorder(
            _open_sink(args.format, handle),
            pre_s=args.pre_s,
            post_s=args.post_s,
            keep_audio_samples=args.audio_pcm,
        )
        recorder.mark(
            "marker",
            f"start mock={args.mock} current={args.current} gain={args.adc_gain} "
            f"ch={args.adc_channel} audio={args.audio} pre_s={args.pre_s} post_s={args.post_s}",
        )
        try:
            steps: list[tuple[str, Callable[[], None], float]] = []
            if args.mock:
                current, audio, power = mock_sources()
                steps += [
                    ("mock_current", current_reader_step(current, recorder), max(args.period, 0.01)),
                    ("mock_audio", audio_reader_step(audio, recorder), 0.032),
                    ("mock_power", power_sensor_step(power, recorder), 0.1),
                ]
            if args.current:
                from .config import CurrentSensorConfig  # noqa: PLC0415
                from .current_sensor import Ads1115Reader  # noqa: PLC0415

                gain = int(args.adc_gain) if float(args.adc_gain).is_integer() else args.adc_gain
                reader = Ads1115Reader(CurrentSensorConfig(ads_gain=gain, channel=args.adc_channel))
                steps.append(("current", current_reader_step(reader, recorder), args.period))
            if args.audio:
                from .audio_sensor import SounddeviceReader  # noqa: PLC0415
                from .config import AudioSensorConfig  # noqa: PLC0415

                audio_reader = SounddeviceReader(AudioSensorConfig())
                closers.append(audio_reader.close)
                steps.append(("audio", audio_reader_step(audio_reader, recorder), 0.0))
            for label, step, period in steps:
                workers.append(
                    threading.Thread(
                        target=run_source_loop,
                        args=(step, recorder, stop, period, label),
                        daemon=True,
                    )
                )
            for worker in workers:
                worker.start()
            if args.duration > 0:
                timer = threading.Timer(args.duration, stop.set)
                timer.daemon = True
                timer.start()
            if not args.no_stdin and not args.mock:

                def _read_keys() -> None:
                    for line in sys.stdin:
                        text = line.strip()
                        if text == "q":
                            break
                        if text == "s":
                            recorder.mark("press_start", "keyboard")
                        elif text == "e":
                            recorder.mark("press_end", "keyboard")
                        elif text:
                            recorder.mark("marker", text)
                    stop.set()

                threading.Thread(target=_read_keys, daemon=True).start()
                print("기록 중 — s=누름 시작, e=누름 끝, q=종료, 그 밖의 글=메모", file=sys.stderr)
            if args.mock:
                # 합성 누름 한 번 — 창 모드 경로까지 점검한다.
                recorder.mark("press_start", "mock")
                stop.wait(min(0.2, args.duration / 2))
                recorder.mark("press_end", "mock")
            while not stop.wait(0.1):
                pass
        except KeyboardInterrupt:
            pass
        finally:
            stop.set()
            for worker in workers:
                worker.join(timeout=2.0)
            for close in closers:
                try:
                    close()
                except Exception:  # noqa: BLE001
                    pass
            recorder.mark("marker", "end")
            recorder.flush()

    print(f"{recorder.rows} rows -> {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
