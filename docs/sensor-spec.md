# 센서 명세 (L3 전력 검증 및 누름 센서)

> **2026-10-30 실물 하드웨어 확정:** 가전 분해 없는 비침습 전류 측정을 위해 **DFRobot SEN0211 아날로그 AC 전류 센서**를 ESP32 ADC1에 직결하여 L3(가전 실제 가열 동작 확인) 실측 검증을 완료했다. 아래 1절의 ACS712는 초기 침습형/내부선 검토 이력이다.

---

## 0. 실물 확정: DFRobot SEN0211 비침습 AC 전류 센서 (2026-10-30 실물 검증)

### 0.1 선정 배경 및 침습식(ACS712) 대비 차별점
- **비침습성 (Non-invasive):** 기존 ACS712는 220V 활선(Live)을 절단하여 센서 기판 터미널에 직렬 연결해야 하므로 감전 및 화재 위험이 높고 가전 보증이 훼손된다.
- **분할 코어(Split-core) 변류기:** DFRobot SEN0211은 개폐형 변류기(CT) 클램프를 전원선 1가닥(갈색 활성선)에 물리기만 하면 되므로, **절단이나 개조 없이 100% 안전하게 설치**할 수 있다.
- **자체 정류 회로 내장:** 교류 신호를 센서 보드 내부에서 직류 전압(0.2V ~ 2.8V DC)으로 변환 및 필터링하여 출력하므로, 별도 고속 RMS 샘플링 IC 없이도 ESP32 내장 ADC1로 안정적인 실효 전력 계측이 가능하다.

### 0.2 하드웨어 규격 (Specification)
- **센서 모듈:** DFRobot Gravity: Analog AC Current Sensor (SKU: SEN0211)
- **공급 전압:** 3.3V ~ 5.5V (ESP32 3.3V 전원 사용)
- **계측 범위:** 0 ~ 20A AC RMS (상용 220V 기준 최대 4,400W 수용)
- **출력 신호:** 0.2V ~ 2.8V DC (아날로그 선형 전압)
- **정밀도:** ±3% (정격의 10% ~ 120% 구간)
- **ESP32 연결:** ADC1_CH0 (GPIO 36 / VP)
- **결선 규칙:** 멀티탭 피복 내부 **갈색(Live) 1선만** 통과 (외피 통째로 물리면 Live-Neutral 자속 상쇄로 0W 출력)

### 0.3 신호 변환 및 캘리브레이션 수식
- {offset} = 0.20V$ (실측 무부하 기준선 142mV)
-  = 20.0A / (2.8V - 0.2V) = 7.6923 A/V$
- {rms} = (V_{out} - 0.20V) * 7.6923 A/V$ ({out} > 0.20V$)
-  = I_{rms} * 220V * 1.0$ (유효 역률 가정)

### 0.4 실물 전자레인지 실측 데이터 (2026-10-30)
- **대기 상태 (Standby):** 142.0mV -> 0.0W (잡음 마진 200mV 이하 안전 필터링)
- **가열 개시 (Inrush / Magnetron ON):** 1,162.4mV -> **1,628.7W** (7.40A)
- **조리 가열 중 (Cooking):** 792.2mV -> **1,002.2W** (4.55A)
- **조리 완료 정지 (Stop):** 254.3mV -> 91.8W -> **0.0W** (L3 가열 완료 즉시 판정)

---

## 1. 전류 센서 — ACS712 (초기 검토 이력)

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

> **선택: ACS712-05B** — 0.34 mA 분해능.
>
> **측정 위치(2026-10-07 통일):** 누름 장치 쪽(Z 구동부) 전류 — 가전을 열지 않는다. 정확한 측정 지점은 HW 확정 전이다.
> 초기 설계의 "가전 제어보드 5 V 라인" 측정은 가전 분해가 필요해 쓰지 않는다. 아래 전류 특성 표는 그 초기 설계의 추정치로, 현재 위치에서는 다시 재야 한다(추측/측정 필요).
>
> **한계:** 지금 관측 구간은 XY 이동 전체와 Z 누름을 함께 덮는다. Z 누름 구간(MCU `press_start` 기준)으로 좁히는 일은 남은 과제다.

### 전자레인지 전류 특성 (추정 — 초기 설계 기준, 현재 측정 위치와 다름)

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
| 전류 ✅ + 음향 ❌ | pressed | 0.55 |
| 전류 ❌ + 음향 ✅ | **not pressed** | 0.45 |
| 전류 ❌ + 음향 ❌ | not pressed | 0.0 |

> 기본 가중치 전류 0.55·음향 0.45, 임계값 0.50(`rpi/verifier/config.py`의 `FusionConfig`). 따라서 **전류(L1) 판정이 필수이고 음향은 보조 신뢰도**다 — 음향만으로는 눌림으로 판정하지 않는다. `rpi/tests/test_fusion_truth_table.py`가 이 표를 고정한다. 하드코딩 금지.

---

## 5. 구현 우선순위 (M1)

1. USB 마이크 + peak dB → 최소 동작 확인
2. `scipy.signal.welch`로 실측 주파수 확정
3. FFT 대역 에너지 방식으로 교체
4. ADS1115 전류 판정 연결
5. fusion 복합 판정 적용
