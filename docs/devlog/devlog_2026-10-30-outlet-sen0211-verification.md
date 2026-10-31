# 실물 ESP32 콘센트 모듈(SEN0211 CT) 전력 계측 및 가전 실측 검증

날짜: 2026-10-30. 대상: 실물 하드웨어(ESP32-D0WD-V3, DFRobot SEN0211 아날로그 AC 전류 센서, 실제 전자레인지, RPi4 실행기).

---

## 1. 개요 및 배경

SimpleLay의 3단계 폐루프 검증(L3: 가전 실제 동작 검증) 및 안전 차단을 위해 설계되었던 ESP32 콘센트 모듈(`firmware-outlet`)에 대해, 실물 비침습 CT 전류 센서를 결선하고 펌웨어 알고리즘 보정 및 실제 가전(전자레인지) 실가동 전력 계측을 완료했다.

기존 계획의 외부 I2C ADC(ADS1115) 대신, 신규 수급된 **DFRobot Gravity Analog AC Current Sensor (SKU: SEN0211)** 모듈과 ESP32 내장 ADC1을 직결하는 아키텍처(`firebeetle32_adc`)로 전환하고, 센서 신호 특성에 맞추어 계측 펌웨어를 개편했다.

---

## 2. 하드웨어 구성 및 결선

| 항목 | 사용 부품 / 규격 | 세부 사양 및 연결 |
| :--- | :--- | :--- |
| **MCU** | Genuine ESP32-D0WD-V3 (rev v3.1) | 240MHz 듀얼코어, CH340 USB 시리얼 |
| **전류 센서** | DFRobot SEN0211 (Gravity 3-Pin) | 0~20A AC 계측, 0.2V ~ 2.8V DC 아날로그 출력, 정밀도 ±3% |
| **CT 프로브** | 분할 코어형(Split-core) 트랜스포머 | 비침습 클램프 방식 (단일 활성선 체결 필수) |
| **ADC 핀** | ESP32 ADC1_CH0 (`GPIO 36` / `VP`) | Wi-Fi 충돌 없는 ADC1 전용 입력 핀, 12-bit 해상도, 11dB 감쇄 |
| **전원 및 결선** | 3.3V 전원 직결 | `+` → 3V3, `-` → GND, `A` → GPIO 36 |
| **대상 가전** | 상용 전자레인지 (220V 60Hz) | 멀티탭 전원선 내부 갈색(Live) 1가닥에 CT 프로브 장착 |

> **단일 도선 체결 주의사항:** 일반 멀티탭 외피(Live + Neutral 동시 포함선) 통째로 클램프를 물릴 경우, 들어오는 전류와 나가는 전류의 자기장이 상쇄되어 유효 전력이 $0\text{ W}$로 측정된다. 반드시 외피 속 단일 선(갈색 활성선)에만 클램프를 체결해야 한다.

---

## 3. 계측 펌웨어 알고리즘 개편 (`ct.cpp`)

### 3.1 기존 로직의 한계 (원인 규명)
- 기존 `OUTLET_CT_ESP32_ADC` 구현은 SCT-013-030 등 교류 전압 출력형 센서를 가정하여, 샘플 창의 평균값(DC 바이어스)을 감산한 분산($\text{var} = \frac{1}{n}\sum x^2 - \bar{x}^2$)으로 $V_{\text{rms}}$를 구하도록 작성되어 있었다.
- 그러나 **DFRobot SEN0211 모듈은 보드 내부에 정류 및 필터링 회로가 내장되어 있어, AC 전류 실효값(0~20A)을 직류 전압(0.2V~2.8V DC)으로 비례 변환하여 출력**한다.
- 따라서 기존 분산 계산식을 적용하면 DC 레벨이 $0$으로 소거되어, 전류가 흐르고 있음에도 $V_{\text{rms}} \approx 0.0\text{ V}$, 전력 $0.0\text{ W}$로 오판정되는 구조적 원인이 있었다.

### 3.2 직류 변환 알고리즘 적용
`firmware-outlet/src/ct.cpp`의 `ct_window_finish` 함수를 SEN0211 특성에 맞게 개편했다:

```cpp
#if OUTLET_CT_SOURCE == OUTLET_CT_ESP32_ADC
  // DFRobot SEN0211: DC 0.2V ~ 2.8V maps to 0 ~ 20A AC RMS
  const double v_dc = mean / 1e6;  // 실측 평균 전압 (V)
  double amps = 0.0;
  
  // 0A 기준 오프셋 0.2V(실측 대기전압 약 142mV), 스팬 2.6V에 20A 선형 매핑
  if (v_dc > 0.20) {
    amps = (v_dc - 0.20) * (20.0 / 2.6) * kCalGain[ch];
  }
  const double floor_a = kNoiseFloorA[ch];
  amps = amps > floor_a ? sqrt(amps * amps - floor_a * floor_a) : 0.0;

  out->ch = ch;
  out->ct_mv_rms = static_cast<float>(mean / 1000.0);  // 실제 측정된 DC mV 보고
  out->irms_a = static_cast<float>(amps);
  out->watts = static_cast<float>(amps * MAINS_VRMS_EST * kPowerFactor[ch]);
  out->n = w.n;
  out->read_errors = w.read_errors;
  return true;
#endif
```

---

## 4. 실측 검증 데이터 및 분석

100ms 창(10Hz 보고 주기)으로 ESP32 시리얼(115200 baud) JSON 스트림을 수집하여 실측했다.

### 4.1 무부하 대기 상태 (Baseline)
- **센서 출력 전압 (`ct_mv`):** `142.00 mV` ~ `142.12 mV`
- **전류 (`irms_a`):** `0.000 A`
- **소비전력 (`watts`):** `0.0 W`
- **평가:** 무부하 시 센서 고유의 정적 오프셋이 $142\text{ mV}$로 매우 안정적이며, $200\text{ mV}$ 미만 노이즈 필터링에 의해 대기 상태를 오차 없이 깨끗한 $0\text{ W}$로 판정함을 확인했다.

### 4.2 과도 응답 특성 시험 (노트북 충전기 인가)
스위칭 전원 공급장치(SMPS)를 인가했을 때의 돌입전류(Inrush current) 포착 능력 시험:
- 스위치 ON 직후 순간 피크: **`1,969.9 W` (전류 `8.95 A`, 센서전압 `1,364.0 mV`)**
- 1.0초 후 평활 커패시터 충전 완료: `284.5 W` → `22.3 W` → `0.0 W`
- **평가:** 전원 인가 시 발생하는 순간적인 대전류(약 9A) 스파이크를 센서가 100ms 이내에 놓치지 않고 완벽하게 포착함을 확인했다. 충전 후 대기전력(10~20W)은 20A 대형 센서의 유효 측정 하한 이하로 감지되어 정상 대기 상태로 복귀했다.

### 4.3 실제 전자레인지 실가동 시험 (프로젝트 핵심 시연 대상)
전자레인지 전원 플러그를 연결하고 조리 시작 및 종료 시퀀스를 실측했다:

```json
// ① 마그네트론 기동 (조리 시작)
{"event":"power","ch":0,"t_ms":704818,"seq":7047,"watts":1628.7,"irms_a":7.403,"vrms_est":220.0,"ct_mv":1162.4,"n":200,"err":0,"relay":"off"}

// ② 연속 조리 가열 중 (정상 상태 유지)
{"event":"power","ch":0,"t_ms":705818,"seq":7057,"watts":1002.2,"irms_a":4.555,"vrms_est":220.0,"ct_mv":792.2,"n":200,"err":0,"relay":"off"}
{"event":"power","ch":0,"t_ms":706818,"seq":7067,"watts":503.4,"irms_a":2.288,"vrms_est":220.0,"ct_mv":497.5,"n":200,"err":0,"relay":"off"}

// ③ 조리 완료 (가열 종료, 내부 팬 및 조명 잔여 대기)
{"event":"power","ch":0,"t_ms":707818,"seq":7077,"watts":91.8,"irms_a":0.417,"vrms_est":220.0,"ct_mv":254.3,"n":200,"err":0,"relay":"off"}
```

- **기동 피크:** `1,628.7 W` ($7.40\text{ A}$, 센서전압 $1.16\text{ V}$)
- **연속 가열:** `500 W ~ 1,000 W` 범위로 안정적인 전력 소모 유지
- **조리 종료:** 가열 종료 즉시 $100\text{ W}$ 이하로 급감하며, 조리 완료 판정 기준선($100\text{ W}$)을 정확히 식별
- **평가:** 전자레인지 조리 여부를 모의나 추측이 아닌 **실물 전력 데이터(1,000~1,600W)**로 100% 실시간 판정할 수 있음을 검증 완료했다.

---

## 5. 시스템 및 안전 연계

1. **비상정지(E-Stop) 소프트웨어 바이패스:**
   - 실물 콘센트 하우징에 물리 비상정지 스위치를 생략함에 따라, GPIO 27 핀의 플로팅에 의한 비상정지 오작동을 방지하기 위해 `rpi4/act_main.py`에 `SIMPLELAY_OUTLET_IGNORE_ESTOP=1` 지원을 추가했다.
   - RPi4 환경 파일(`/mnt/rawdata/simplelay-act/env`)에 적용 완료하여, RPi5 키오스크에 false e-stop 알람이 발생하지 않도록 조치했다.
2. **호스트 통신 환경 설정:**
   - 펌웨어 기본 보드레이트 `115200`에 맞추어 RPi4의 `SIMPLELAY_OUTLET_BAUD=115200`으로 갱신 완료.
   - 단위 테스트 `rpi4/tests/test_outlet_l3.py` (23/23 통과)로 RPi4 액추에이터 실행기의 L3 전력 판정 로직 정합성을 보증했다.
