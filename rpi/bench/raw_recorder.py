"""원시 센서 기록기 — ADC·음향·누름 이벤트를 같은 단조 시각축의 CSV로 남긴다.

하드웨어 수령 직후에는 임계값을 믿기 전에 **값이 실제로 어떻게 생겼는지**부터
봐야 한다(docs/하드웨어-연결-설계.md §4·§6).

기록하는 것:
  - ADC: 라이브러리가 주는 정수 판독값과 전압(V)
  - 음향: 콜백 블록마다 RMS·피크·샘플 수 (레벨 요약일 뿐 판정이 아니다)
  - 이벤트: press_start / press_end / marker / error
  - 모든 행의 시각: 호스트 ``time.monotonic_ns()``

하지 않는 것:
  - 임계값 비교, 눌림 판정, 성공 판정. ``rpi.verifier``를 import하지 않는다 —
    기록이 판정 가정(설정값·가중치)에 물들지 않게 한다.

시각의 한계(측정 필요):
  - ADC 행의 시각은 판독 직후 호스트 시각이다. I2C 변환 지연은 포함하지 않는다.
  - 음향 행의 시각은 콜백이 불린 호스트 시각이다. 장치 버퍼 지연은 따로 재야 한다.
  - 키보드로 찍는 누름 이벤트는 사람 입력 지연을 포함한다. 모션 어댑터가 생기면
    어댑터가 ``mark()``를 부른다.
  - 음향 행은 콜백 시각을 인자로 넘기므로 파일 안 행 순서가 시각 순서와 다를 수
    있다. 분석할 때 ``t_monotonic_ns``로 정렬한다.

사용 (RPi4, 하드웨어 라이브러리 설치 뒤):
    python -m rpi.bench.raw_recorder --adc --adc-gain 1 --audio --duration 60
    입력: s=press_start, e=press_end, q=종료, 그 밖의 글=marker 메모

원시 데이터는 저장소에 올리지 않는다. 기본 경로 ``data/bench/``는 .gitignore 대상이다.
"""

from __future__ import annotations

import argparse
import csv
import sys
import threading
import time
from collections.abc import Callable, Sequence
from datetime import datetime
from pathlib import Path
from typing import Protocol, TextIO

import numpy as np

COLUMNS: tuple[str, ...] = (
    "t_monotonic_ns",
    "source",
    "adc_value",
    "adc_voltage",
    "audio_rms",
    "audio_peak",
    "audio_samples",
    "event",
    "note",
)

EVENTS = frozenset({"press_start", "press_end", "marker", "error"})

# .gitignore의 `data/` 아래 — 원시 데이터는 커밋하지 않는다
DEFAULT_OUT_DIR = Path("data") / "bench"

# ADS1115 PGA 설정. 기본값을 두지 않는다: 영점 전압과 범위가 맞지 않으면 포화된다
# (설계 문서 §4). 측정하는 사람이 전압을 확인하고 고른다.
ADS1115_GAINS: dict[str, float] = {
    "2/3": 2 / 3,
    "1": 1,
    "2": 2,
    "4": 4,
    "8": 8,
    "16": 16,
}

_KEY_EVENTS = {"s": "press_start", "e": "press_end"}


class AdcSource(Protocol):
    def read(self) -> tuple[int, float]:
        """(ADC 정수 판독값, 전압[V]) 한 쌍을 돌려준다."""


class RawCsvRecorder:
    """스레드 안전한 CSV 기록기. 헤더는 생성 시 한 번 쓴다."""

    def __init__(
        self, stream: TextIO, clock: Callable[[], int] = time.monotonic_ns
    ) -> None:
        self._stream = stream
        self._writer = csv.writer(stream, lineterminator="\n")
        self._clock = clock
        self._lock = threading.Lock()
        self._rows = 0
        self._writer.writerow(COLUMNS)

    @property
    def rows(self) -> int:
        """헤더를 뺀 기록 행 수."""
        return self._rows

    def now_ns(self) -> int:
        return self._clock()

    def record_adc(self, value: int, voltage: float, t_ns: int | None = None) -> None:
        self._write(t_ns, "adc", adc_value=int(value), adc_voltage=float(voltage))

    def record_audio_block(
        self, samples: Sequence[float] | np.ndarray, t_ns: int | None = None
    ) -> None:
        block = np.asarray(samples, dtype=np.float64).ravel()
        if block.size == 0:
            self._write(t_ns, "audio", audio_samples=0)
            return
        self._write(
            t_ns,
            "audio",
            audio_rms=float(np.sqrt(np.mean(block * block))),
            audio_peak=float(np.max(np.abs(block))),
            audio_samples=int(block.size),
        )

    def mark(self, event: str, note: str = "", t_ns: int | None = None) -> None:
        if event not in EVENTS:
            raise ValueError(f"unknown event {event!r} (allowed: {sorted(EVENTS)})")
        self._write(t_ns, "event", event=event, note=note)

    def flush(self) -> None:
        with self._lock:
            self._stream.flush()

    def _write(self, t_ns: int | None, source: str, **fields: object) -> None:
        with self._lock:
            # 시각을 락 안에서 찍는다 — 시각을 넘기지 않은 행은 파일 순서가 시각 순서다
            t = self._clock() if t_ns is None else int(t_ns)
            row: list[object] = [t, source]
            row.extend(_cell(fields.get(column)) for column in COLUMNS[2:])
            self._writer.writerow(row)
            self._rows += 1


def _cell(value: object) -> object:
    if value is None:
        return ""
    if isinstance(value, float):
        return repr(value)  # 반올림하지 않는다 — µV 단위 차이가 분석 대상이다
    return value


def run_adc_loop(
    source: AdcSource,
    recorder: RawCsvRecorder,
    stop: threading.Event,
    period_s: float = 0.0,
) -> None:
    """stop이 설정될 때까지 ADC를 읽어 기록한다.

    판독 오류는 error 이벤트로 남기고 계속한다 — 기록기가 사실을 버리고 멈추면
    오류가 언제 얼마나 났는지도 사라진다.
    """
    while not stop.is_set():
        try:
            value, voltage = source.read()
        except Exception as exc:  # noqa: BLE001 -- 원인과 시각을 기록으로 남긴다
            recorder.mark("error", f"adc: {exc}")
            if stop.wait(max(period_s, 0.05)):  # 오류가 반복돼도 바쁜 루프로 돌지 않게
                break
            continue
        recorder.record_adc(value, voltage, t_ns=recorder.now_ns())
        if period_s > 0 and stop.wait(period_s):
            break


def handle_command(line: str, recorder: RawCsvRecorder) -> bool:
    """키보드 한 줄을 이벤트로 옮긴다. 계속 기록하면 True, 종료면 False."""
    text = line.strip()
    if text == "q":
        return False
    if text in _KEY_EVENTS:
        recorder.mark(_KEY_EVENTS[text])
    elif text:
        recorder.mark("marker", text)
    return True


def default_out_path(now: datetime | None = None) -> Path:
    stamp = (now or datetime.now()).strftime("%Y%m%d-%H%M%S")
    return DEFAULT_OUT_DIR / f"raw-{stamp}.csv"


# ── 실기기 입력 (하드웨어 라이브러리가 있을 때만 import) ──────────────────


class Ads1115Source:
    """ADS1115 한 채널. ``value``는 라이브러리의 정수 판독값이다 — 비트 정렬은
    라이브러리 버전에 따라 다를 수 있어 전압 열과 함께 본다(측정 시 확인)."""

    def __init__(self, channel: int, gain: str, data_rate: int) -> None:
        try:
            import board  # type: ignore[import]  # noqa: PLC0415
            import busio  # type: ignore[import]  # noqa: PLC0415
            import adafruit_ads1x15.ads1115 as ads1115  # type: ignore[import]  # noqa: PLC0415
            from adafruit_ads1x15.analog_in import AnalogIn  # type: ignore[import]  # noqa: PLC0415
        except ImportError as exc:
            raise RuntimeError(
                "ADS1115 library is not installed. "
                "Run: pip install adafruit-circuitpython-ads1x15 adafruit-blinka"
            ) from exc

        ads = ads1115.ADS1115(busio.I2C(board.SCL, board.SDA), data_rate=data_rate)
        ads.gain = ADS1115_GAINS[gain]
        pins = [ads1115.P0, ads1115.P1, ads1115.P2, ads1115.P3]
        self._chan = AnalogIn(ads, pins[channel])

    def read(self) -> tuple[int, float]:
        return int(self._chan.value), float(self._chan.voltage)


def start_audio_stream(
    recorder: RawCsvRecorder,
    sample_rate: int,
    block_size: int,
    device: int | None,
):
    """마이크 입력 스트림을 열고 블록마다 레벨을 기록한다. 스트림을 돌려준다."""
    try:
        import sounddevice as sd  # type: ignore[import]  # noqa: PLC0415
    except ImportError as exc:
        raise RuntimeError("sounddevice is not installed. Run: pip install sounddevice") from exc

    def _callback(indata, frames, time_info, status) -> None:  # noqa: ARG001
        t_ns = recorder.now_ns()
        recorder.record_audio_block(indata[:, 0], t_ns=t_ns)
        if status:
            recorder.mark("error", f"audio: {status}", t_ns=t_ns)

    stream = sd.InputStream(
        callback=_callback,
        blocksize=block_size,
        samplerate=sample_rate,
        channels=1,
        device=device,
    )
    stream.start()
    return stream


# ── CLI ───────────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m rpi.bench.raw_recorder",
        description="원시 센서 값을 CSV로 기록한다(판정 없음).",
    )
    parser.add_argument("--out", help="CSV 경로 (기본: data/bench/raw-<시각>.csv)")
    parser.add_argument("--duration", type=float, default=0.0, help="초. 0이면 q 입력까지")
    parser.add_argument("--adc", action="store_true", help="ADS1115 채널 기록")
    parser.add_argument("--adc-channel", type=int, choices=range(4), default=0)
    parser.add_argument(
        "--adc-gain",
        choices=sorted(ADS1115_GAINS),
        help="PGA gain. 기본값 없음 — 무전류 전압을 확인하고 고른다",
    )
    parser.add_argument("--adc-rate", type=int, default=860, help="ADS1115 data rate")
    parser.add_argument(
        "--adc-period", type=float, default=0.0, help="판독 사이 대기(초). 0이면 연속"
    )
    parser.add_argument("--audio", action="store_true", help="마이크 블록 레벨 기록")
    parser.add_argument("--sample-rate", type=int, default=16_000)
    parser.add_argument("--block", type=int, default=512, help="음향 블록 샘플 수")
    parser.add_argument("--audio-device", type=int, default=None)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.adc and not args.audio:
        parser.error("--adc 또는 --audio 중 하나 이상을 켜야 한다")
    if args.adc and args.adc_gain is None:
        parser.error("--adc에는 --adc-gain이 필요하다 (기본값 없음: 포화 방지)")

    out = Path(args.out) if args.out else default_out_path()
    out.parent.mkdir(parents=True, exist_ok=True)
    stop = threading.Event()
    stream = None
    workers: list[threading.Thread] = []

    with out.open("w", newline="", encoding="utf-8") as handle:
        recorder = RawCsvRecorder(handle)
        recorder.mark(
            "marker",
            f"start adc={args.adc} ch={args.adc_channel} gain={args.adc_gain} "
            f"rate={args.adc_rate} audio={args.audio} sr={args.sample_rate} "
            f"block={args.block}",
        )
        try:
            if args.adc:
                source = Ads1115Source(args.adc_channel, args.adc_gain, args.adc_rate)
                workers.append(
                    threading.Thread(
                        target=run_adc_loop,
                        args=(source, recorder, stop, args.adc_period),
                        daemon=True,
                    )
                )
            if args.audio:
                stream = start_audio_stream(
                    recorder, args.sample_rate, args.block, args.audio_device
                )
            for worker in workers:
                worker.start()
            if args.duration > 0:
                timer = threading.Timer(args.duration, stop.set)
                timer.daemon = True
                timer.start()

            def _read_keys() -> None:
                for line in sys.stdin:
                    if not handle_command(line, recorder):
                        break
                stop.set()

            threading.Thread(target=_read_keys, daemon=True).start()
            print("기록 중 — s=누름 시작, e=누름 끝, q=종료, 그 밖의 글=메모", file=sys.stderr)
            while not stop.wait(0.2):
                pass
        except KeyboardInterrupt:
            pass
        finally:
            stop.set()
            for worker in workers:
                worker.join(timeout=2.0)
            if stream is not None:
                stream.stop()
                stream.close()
            recorder.mark("marker", "end")
            recorder.flush()

    print(f"{recorder.rows} rows -> {out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
