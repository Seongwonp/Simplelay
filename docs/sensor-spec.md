# 센서 명세 (M1 구현 참조)

> Phase A 구현 전 참조 문서. ACS712 전류 + 마이크 음향 두 신호를 조합해 버튼 눌림을 판정한다.

---

## 1. 전류 센서 — ACS712

### 동작 원리
홀 효과(Hall Effect) 기반 선형 전류 센서. 측정 전류 → 내부 자기장 → 선형 전압 출력.

| 항목 | 값 |
|------|-----|
| 무전류 기준 출력 | VCC / 2 = **2.5 V** (5 V 공급) |
| 출력 범위 | 0.5 V ~ 4.5 V |
| 대역폭 | 80 kHz |
| 응답 시간 | ≤ 5 μs |

### 모델 선택

| 모델 | 정격 | 감도 | 분해능 (ADS1115 기준) |
|------|------|------|----------------------|
| ACS712-05B | ±5 A | 185 mV/A | ~0.34 mA/step |
| ACS712-20A | ±20 A | 100 mV/A | ~0.63 mA/step |
| ACS712-30A | ±30 A | 66 mV/A | ~0.95 mA/step |

> **선택: ACS712-05B** — 제어보드 5 V 라인 모니터링, 버튼 눌림 △I ≈ 5 ~ 50 mA 범위를 0.34 mA 분해능으로 충분히 감지.

### 전자레인지 전류 특성 (추정)

| 상태 | 5 V 제어 라인 전류 |
|------|------------------|
| 대기 (디스플레이 켜짐) | 30 ~ 80 mA |
| 버튼 눌림 순간 (스파이크) | **+10 ~ 50 mA** |
| 버튼 유지 (1 ms 이상) | +5 ~ 20 mA 지속 |

---

## 2. 외부 ADC — ADS1115 (I2C)

RPi는 온보드 ADC 없음. 두 옵션 비교:

| 항목 | MCP3008 (SPI) | **ADS1115 (I2C)** |
|------|--------------|------------------|
| 분해능 | 10-bit | **16-bit** |
| 최대 샘플레이트 | 200 ksps | 860 sps |
| 전류 분해능 (05B) | ~17 mA/step | **~0.34 mA/step** |
| Python 라이브러리 | `spidev` | `adafruit-circuitpython-ads1x15` |

> **선택: ADS1115** — 버튼 눌림의 미세 전류 변화(5 ~ 50 mA)를 정밀 감지 가능.

### Python 읽기 코드

```python
import board, busio
import adafruit_ads1x15.ads1115 as ADS
from adafruit_ads1x15.analog_in import AnalogIn

i2c = busio.I2C(board.SCL, board.SDA)
ads = ADS.ADS1115(i2c, data_rate=860)
ads.gain = 2            # ±2.048 V 범위
chan = AnalogIn(ads, ADS.P0)

SENSITIVITY = 0.185     # ACS712-05B: 185 mV/A

def read_current_a() -> float:
    return (chan.voltage - 2.5) / SENSITIVITY
```

### 눌림 판정 — 이동 평균 + 미분 (권장)

```python
from collections import deque

WINDOW   = 20       # ~23 ms @ 860 sps
DELTA_TH = 0.012    # 12 mA 급증 시 눌림 판정

buf = deque(maxlen=WINDOW)

def is_pressed() -> bool:
    val = read_current_a()
    buf.append(val)
    if len(buf) < WINDOW:
        return False
    baseline = sum(buf) / WINDOW
    return (val - baseline) > DELTA_TH
```

> 단순 임계값보다 온도 드리프트·장기 전류 변화에 강함.

### 필요 패키지

```bash
pip install adafruit-circuitpython-ads1x15 adafruit-blinka smbus2
```

---

## 3. 음향 센서 — 마이크

### 연결 방법

| 방식 | 장점 | 단점 | 권장 시점 |
|------|------|------|----------|
| USB 마이크 | plug-and-play, 드라이버 불필요 | 크기 큼 | **M1 시작 시** |
| I2S INMP441 | 소형, 저소음 | 배선 필요 (`/boot/config.txt`) | 배선 여유 생기면 |

**INMP441 배선 (BCM 핀 번호)**

| INMP441 | RPi BCM | 물리 핀 |
|---------|---------|---------|
| VDD | 3.3 V | Pin 1 |
| GND | GND | Pin 6 |
| SCK (BCLK) | GPIO 18 | Pin 12 |
| WS (LRCLK) | GPIO 19 | Pin 35 |
| SD (DATA) | GPIO 20 | Pin 38 |
| L/R | GND | — |

### PyAudio 스트림 기본값

| 파라미터 | 값 | 이유 |
|---------|-----|------|
| CHUNK | **512** | 32 ms @ 16 kHz — 버튼음 감지 적정 |
| RATE | 16000 Hz | 버튼음 대역 충분, CPU 부하 낮음 |
| FORMAT | `paInt16` | |
| CHANNELS | 1 | |

### 전자레인지 버튼음 주파수 특성

| 버튼 유형 | 주파수 대역 |
|----------|-----------|
| 정전용량 터치패드 비프 | **1,000 ~ 2,000 Hz** |
| 완료음 (길게) | 2,000 ~ 4,000 Hz |
| 기계식 클릭 | 100 ~ 8,000 Hz (광대역) |

> 실측 필수: `scipy.signal.welch`로 실제 기기 버튼음 녹음 후 피크 주파수 확인.

### 감지 방법 비교

| 방법 | 소음 내성 | 복잡도 | 권장 환경 |
|------|---------|--------|----------|
| peak dB 임계값 | 낮음 | 낮음 | 조용한 실험실 |
| **FFT 대역 에너지** | **높음** | 중간 | **주방/일반 환경** |

### FFT 대역 에너지 감지 (권장)

```python
import numpy as np

def detect_beep(
    pcm: np.ndarray,
    rate: int = 16000,
    f_low: int = 800,
    f_high: int = 3000,
    threshold: float = 0.35,
) -> bool:
    window  = pcm * np.hanning(len(pcm))
    fft_mag = np.abs(np.fft.rfft(window))
    freqs   = np.fft.rfftfreq(len(pcm), 1 / rate)
    mask    = (freqs >= f_low) & (freqs <= f_high)
    ratio   = fft_mag[mask].sum() / (fft_mag.sum() + 1e-9)
    return bool(ratio > threshold)
```

> `f_low`, `f_high`, `threshold`는 실측값으로 교체. 초기값은 위 표의 추정 대역.

### sounddevice 콜백 방식 (저지연)

```python
import queue
import sounddevice as sd

q: queue.Queue = queue.Queue()

def _callback(indata, frames, time, status):
    q.put(indata[:, 0].copy())

with sd.InputStream(callback=_callback, blocksize=256,
                    samplerate=16000, channels=1):
    while True:
        pcm = q.get()
        if detect_beep(pcm):
            print("버튼음 감지")
```

### 필요 패키지

```bash
sudo apt-get install -y portaudio19-dev libatlas-base-dev
pip install pyaudio sounddevice numpy scipy
```

---

## 4. 복합 판정 전략 (fusion)

두 신호를 조합해 신뢰도를 높인다.

| 조건 | 판정 | 신뢰도 |
|------|------|--------|
| 전류 ✅ + 음향 ✅ | pressed | 1.0 |
| 전류 ✅ + 음향 ❌ | pressed | 0.7 |
| 전류 ❌ + 음향 ✅ | pressed | 0.6 |
| 전류 ❌ + 음향 ❌ | not pressed | 0.0 |

> 신뢰도 임계값(기본 0.5)은 `rpi/verifier/config.py`로 주입. 하드코딩 금지.

---

## 5. 구현 우선순위 (M1)

1. USB 마이크 + peak dB → 최소 동작 확인
2. `scipy.signal.welch`로 실측 주파수 확정
3. FFT 대역 에너지 방식으로 교체
4. ADS1115 전류 판정 연결
5. fusion 복합 판정 적용
