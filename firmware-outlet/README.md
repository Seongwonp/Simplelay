# firmware-outlet — ESP32 콘센트 모듈 펌웨어

**2026-10-30 실물 하드웨어 플래시 및 실제 가전(전자레인지) 계측 검증 완료.**
DFRobot SEN0211 아날로그 AC 전류 센서(0~20A)와 ESP32 내장 ADC1(GPIO36)을 직결하고, 실시간 소비 전력(가열 시 1,000~1,628W) 및 대기/조리 완료 판정(100W 미만)을 실측 검증했다 ([실측 개발기록](../docs/devlog/devlog_2026-10-30-outlet-sen0211-verification.md)).

- 타깃 환경: `firebeetle32_adc` (ESP32 ADC1 직결)
- 대상 가전: 상용 220V 전자레인지 (ch0)
- 실측 기준선: 무부하 대기전압 `142mV` ($0.0\text{ W}$), 가열 기동 피크 `1,628.7W` ($7.40\text{ A}$), 조리 중 `503W ~ 1,002W`

---

## 역할 및 시스템 구성

```
전자레인지 전원선 ──(갈색 Live 1가닥)── CT 0 (SEN0211 클램프) ── GPIO36(ADC1_CH0) ─┐
                                                                                   │ ESP32 콘센트 모듈
세탁기 전원선 ─────(갈색 Live 1가닥)── CT 1 (확장 채널) ──────── GPIO39(ADC1_CH3) ─┤
                                                                                   │
                                                         USB 시리얼 (JSON, 115200) ┘
                                                                   │
                                               RPi4 액추에이터 실행기 (act_main.py)
                                               채널별 L3 폐루프 판정 (가열 시작/조리 완료)
```

### 센서 규격 및 결선 (DFRobot SEN0211)
- **센서 모델:** DFRobot Gravity Analog AC Current Sensor (SKU: SEN0211)
- **측정 범위:** 0 ~ 20A AC RMS (정밀도 ±3%)
- **출력 신호:** 0.2V ~ 2.8V DC (보드 내부에 AC 정류 및 평활 회로 내장)
- **ESP32 결선:**
  - `+` (VCC) → 3.3V
  - `-` (GND) → GND
  - `A` (Analog Out) → GPIO 36 (`VP` / `ADC1_CH0`)
- **주의사항:** 멀티탭 전선 피복을 통째로 물리면 활성선(Live)과 중성선(Neutral)의 자속이 상쇄되어 0W가 된다. 반드시 피복 내부의 **단일 도선(갈색 활성선)** 1가닥만 클램프를 통과시켜야 한다.

---

## 전력 계산 알고리즘 (`ct.cpp`)

### SEN0211 DC 출력 신호 처리
기존 AC 교류 파형 샘플링 방식(평균 감산 분산 계산)과 달리, SEN0211은 센서 보드 자체에서 AC 전류 실효값에 비례하는 DC 전압(0.2V~2.8V)을 출력한다. 이에 따라 펌웨어를 직류 전압 기반 계산식으로 개편했다:

$$V_{\text{dc}} = \frac{\text{sum\_uv}}{n \times 10^6} \quad [\text{V}]$$

$$I_{\text{rms}} = 
\begin{cases} 
(V_{\text{dc}} - 0.20\text{V}) \times \frac{20.0\text{A}}{2.6\text{V}} \times \text{gain} & (V_{\text{dc}} > 0.20\text{V}) \\ 
0.0\text{ A} & (V_{\text{dc}} \le 0.20\text{V}) 
\end{cases}$$

$$\text{Watts} = I_{\text{rms}} \times V_{\text{mains\_est}} (220\text{V}) \times \text{pf} (1.0)$$

- **대기 잡음 차단:** 무부하 시 실측 전압은 $142\text{ mV}$로, $200\text{ mV}$ 이하 구간을 잡음 마진으로 두어 대기 모드에서 안정적인 $0.0\text{ W}$를 출력한다.
- **보고 주기:** 100ms 창(10Hz 주기)마다 RPi4로 줄 단위 JSON 전송.

---

## 빌드 및 플래시

Windows 환경(긴 경로 및 App Control 정책 고려)에서 실행:

```powershell
# 1. 빌드 디렉터리 및 환경변수 설정
$env:PLATFORMIO_BUILD_DIR='C:\pio-build\firmware-outlet'

# 2. ESP32 ADC1 타깃 빌드
C:\pyvenv\Scripts\pio.exe run -d firmware-outlet -e firebeetle32_adc

# 3. 보드 플래시 (COM 포트 및 921600 baud)
$env:PYTHONIOENCODING="utf-8"
C:\pyvenv\Scripts\python.exe C:\.platformio\packages\tool-esptoolpy\esptool.py --chip esp32 --port COM3 --baud 921600 write_flash 0x10000 C:\pio-build\firmware-outlet\firebeetle32_adc\firmware.bin
```

---

## 통신 규약 (Protocol)

줄 단위 JSON(`\n`), 115200 baud.

### `power` 이벤트 (10 Hz 실시간 스트림)
```json
{"event":"power","ch":0,"t_ms":704818,"seq":7047,"watts":1628.7,"irms_a":7.403,"vrms_est":220.0,"ct_mv":1162.4,"n":200,"err":0,"relay":"off"}
```
- `ch`: 측정 채널 (0 = 전자레인지, 1 = 확장 채널)
- `watts`: 추정 소비 전력 (W)
- `irms_a`: 실효 전류 (A)
- `ct_mv`: 센서 보드 실측 직류 전압 (mV)
- `n`: 창 샘플 수 (200점)

### 비상정지(E-Stop) 소프트웨어 옵션
물리 비상정지 버튼이 미장착된 환경에서는 GPIO 27 플로팅으로 인한 래치 오작동을 방지하기 위해 RPi4의 `act_main.py`에 `SIMPLELAY_OUTLET_IGNORE_ESTOP=1` 환경변수를 설정하여 운용한다.

---

## 실측 검증 데이터 요약 (2026-10-30)

| 시험 조건 | 실측 전압 (`ct_mv`) | 실측 전류 (`irms_a`) | 소비전력 (`watts`) | 상태 판정 |
| :--- | :--- | :--- | :--- | :--- |
| **무부하 대기** | `142.0 mV` | `0.000 A` | `0.0 W` | STANDBY (대기) |
| **SMPS 돌입전류** | `1,364.0 mV` | `8.95 A` | `1,969.9 W` | 순간 서지 포착 |
| **전자레인지 기동** | `1,162.4 mV` | `7.40 A` | **`1,628.7 W`** | RUNNING (가열 시작) |
| **전자레인지 조리 중**| `792.2 mV` | `4.55 A` | **`1,002.2 W`** | RUNNING (조리 유지) |
| **전자레인지 조리 완료**| `254.3 mV` | `0.42 A` | `91.8 W` | 가열 정지 → 대기 복귀 |
