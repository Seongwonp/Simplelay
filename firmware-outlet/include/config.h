#pragma once
// firmware-outlet 설정 — **모든 핀·보정 값은 자리표시자(PLACEHOLDER)다. 실측값이 아니다.**
//
// 콘센트 모듈(2026-09-30 하드웨어 방향 확정 §1): 분할형 CT로 가전 전류를 비접촉으로 재서
// 유효 전력 추정값을 RPi4로 보내고(L3 판정은 RPi4), 물리 비상정지 버튼이 가전 전원 릴레이를
// **이 보드 안에서** 연다(호스트·네트워크와 무관).
//
// 여기 적힌 숫자 중 데이터시트에서 온 것은 SCT-013-030의 정격(30 A → 1 V rms)과 ADS1115의
// 레지스터·전압 범위뿐이다. 그것도 실제 부품·배선과 맞는지 팀원 확인 전이다. 보정 계수·상용 전압·
// 역률·핀은 전부 측정 필요다. 채운 뒤 OUTLET_CONFIG_PLACEHOLDER를 0으로 바꾼다(값을 채우지 않고 0으로
// 바꾸지 않는다).

#define OUTLET_CONFIG_PLACEHOLDER 1

// ─── CT 입력 선택(platformio.ini env가 정한다) ───────────────────────────────
#define OUTLET_CT_ADS1115 1
#define OUTLET_CT_ESP32_ADC 2
#ifndef OUTLET_CT_SOURCE
#define OUTLET_CT_SOURCE OUTLET_CT_ADS1115
#endif

// ─── CT 채널 수(2026-10-06 사용자 결정: 두 번째 CT — 전자레인지·세탁기를 동시에 잰다) ─────────────
// 채널 0 = 전자레인지(릴레이를 거치는 플러그), 채널 1 = 세탁기(릴레이를 거치지 않는다). 호스트가 채널 → 가전을
// SIMPLELAY_OUTLET_CHANNELS(예: microwave:0,washer:1)로 잇는다. ADS1115는 최대 4(MUX), 내장 ADC 빌드는 최대 2(핀 2개).
// 1로 빌드하면 CT 하나 배선과 같다(power 이벤트에 "ch":0이 붙는 것만 다르다).
#ifndef OUTLET_CT_CHANNELS
#define OUTLET_CT_CHANNELS     2
#endif
#define OUTLET_CT_MAX_CHANNELS 4       // 아래 채널별 표의 길이
// 릴레이는 하나이고 이 채널(전자레인지)의 가전 전원만 끊는다. **세탁기 채널은 릴레이를 거치지 않게 배선한다** —
// 모터 기동 전류가 릴레이 정격을 넘을 수 있고(정격 확인 전), 세탁기는 CT로 재기만 한다(2026-10-06 결정).
// 비상정지 버튼도 이 릴레이만 연다 — 세탁기 전원은 끊지 않는다. TODO(HW 확인): 실제 배선.
#define OUTLET_RELAY_CH        0

// ─── 호스트 링크(RPi4 ↔ USB 시리얼) ─────────────────────────────────────────
// 고정 보드레이트. RPi4 쪽 SIMPLELAY_OUTLET_BAUD를 같은 값으로 둔다.
#define HOST_SERIAL_BAUD       115200
#define HOST_RX_BUFFER_BYTES   512
#define HOST_TX_BUFFER_BYTES   2048    // 0이면 Serial.write가 막혀 loop가 멈춘다
#define HOST_LINE_MAX          192     // 한 줄 최대 바이트(넘으면 그 줄은 버린다)
#define JSON_POOL_BYTES        2048    // ArduinoJson 고정 풀(힙 미사용)
#define FW_NAME                "firmware-outlet"
#define FW_PROTOCOL            "line-json/outlet-v0"

// 호스트 침묵 시 릴레이 정책. 0(기본) = 호스트가 조용해도 릴레이를 그대로 둔다 — RPi4 재시작마다
// 조리 중인 가전 전원이 끊기지 않게. 1 = HOST_SILENCE_MS 동안 받은 줄이 없으면 릴레이를 열고
// {"event":"host_timeout"}을 보낸다(호스트는 ping heartbeat 필요). 시연 정책은 팀이 정한다.
#define HOST_SILENCE_RELAY_OFF 0
#define HOST_SILENCE_MS        5000

// MCU 태스크 워치독: loop·샘플링 태스크가 이 시간 동안 돌지 않으면 패닉 → 재부팅.
// 재부팅 직후 GPIO는 High-Z — 릴레이 입력의 외부 풀다운(활성 HIGH 모듈) 또는 모듈 내부 풀업
// (활성 LOW 모듈)이 릴레이를 **열린 채** 두어야 한다. TODO(HW 확인): 실제 모듈로 확인.
#define MCU_TASK_WDT_MS        1000

// ─── 샘플링 ──────────────────────────────────────────────────────────────────
// 샘플링 태스크가 SAMPLE_HZ로 깨어나 비상정지 버튼을 보고 CT를 읽는다(ADS1115는 틱마다 채널 하나, 내장 ADC는 모든 채널).
// 보고 주기(기본 REPORT_HZ_DEFAULT)마다 그 창의 실효값을 power 이벤트로 낸다.
// ADS1115 연속 변환 최대 860 SPS — 그보다 느리게 읽어 같은 변환값을 두 번 읽지 않게 한다.
// 60 Hz 상용 전원 기준 10 Hz 보고 = 창 하나에 정확히 6주기. TODO(HW 실측): 지역 주파수(60 Hz) 확인.
#if OUTLET_CT_SOURCE == OUTLET_CT_ADS1115
// 단발 변환(single-shot) + 채널 돌려 읽기: 틱마다 ① 지난 틱에 시작한 변환이 끝났는지(OS 비트) 보고 읽어 그
// 채널 창에 넣고 ② 다음 채널 MUX로 새 변환을 시작한다. 860 SPS 한 변환이 약 1.16 ms(내부 발진기 ±10%면
// 1.28 ms)라 2 ms 틱에 여유를 둔다. 채널당 SAMPLE_HZ / OUTLET_CT_CHANNELS(2채널 = 250 Hz, 기본 5 Hz 창에 50점 —
// 60 Hz 12주기에 50점). 변환이 아직 끝나지 않았으면 다음 변환을 시작하지 않고 그 틱을 건너뛴다(ct.cpp). 측정 필요.
#define SAMPLE_HZ              500
#else
#define SAMPLE_HZ              2000
#endif
#define SAMPLE_PERIOD_US       (1000000 / SAMPLE_HZ)
#define SAMPLE_TASK_PRIORITY   5
#define SAMPLE_TASK_CORE       1
#define SAMPLE_TASK_STACK      4096
// 기본 보고 주기(2026-10-06 평가 A3): ADS1115 돌려 읽기로 CT가 둘 이상이면 5 Hz — 채널당 창 샘플 50(500 Hz / 2채널 /
// 5 Hz)으로 호스트 하한(SIMPLELAY_OUTLET_MIN_SAMPLES 기본 20)의 2.5배 여유. 10 Hz면 25점이라 변환 대기로 몇 틱만
// 건너뛰어도 하한에 닿아 창이 버려지고 L3가 '센서 끊김'으로 멈췄다. 60 Hz 상용 전원 12주기. 측정 필요.
#if OUTLET_CT_SOURCE == OUTLET_CT_ADS1115 && OUTLET_CT_CHANNELS > 1
#define REPORT_HZ_DEFAULT      5
#else
#define REPORT_HZ_DEFAULT      10
#endif
#define REPORT_HZ_MIN          1
#define REPORT_HZ_MAX          20
// rate 명령은 채널 하나의 창 샘플이 이 값보다 적어지는 주기를 거절한다(호스트 SIMPLELAY_OUTLET_MIN_SAMPLES 기본과 같다).
// 예: ADS1115 2채널이면 10 Hz(채널당 25점)까지 받지만 하한 근처다 — 기본은 5 Hz(50점). 20 Hz(12.5점)는 bad_args. 측정 필요.
#define CT_MIN_SAMPLES_PER_WINDOW 20
// 창 샘플이 기대치(SAMPLE_HZ / 보고 주기)의 이 비율(%) 미만이면 그 창은 보고하지 않는다(판독 실패가 쌓인 창이
// 몇 개 안 되는 샘플로 0 W처럼 보이지 않게). 호스트도 n·err로 한 번 더 거른다(SIMPLELAY_OUTLET_MIN_SAMPLES). 측정 필요.
#define CT_MIN_WINDOW_PCT      50

// ─── CT 보정(채널별, 전부 측정 필요) ─────────────────────────────────────────
// 표는 채널 0, 1, 2, 3 순서. 쓰는 것은 앞의 OUTLET_CT_CHANNELS개다. CT마다 개체 차이·배선이 달라 따로 맞춘다.
// SCT-013-030(전압 출력형, 부담 저항 내장): 정격 30 A → 1 V rms. 팀원이 다른 모델(전류 출력형
// SCT-013-000 + 외부 부담 저항 등)을 쓰면 이 값이 바뀐다. TODO(HW 확인): 실제 CT 모델(두 번째 CT 포함).
#define CT_AMPS_PER_VOLT_CH    {30.0f, 30.0f, 30.0f, 30.0f}
// 보정 배율 — 기준 부하(정격을 아는 전열기 등)·클램프 미터와 비교해 정한다. 1.0은 '보정 안 함'.
// TODO(HW 실측): 채널마다.
#define CT_CAL_GAIN_CH         {1.0f, 1.0f, 1.0f, 1.0f}
// 무부하에서도 남는 잡음 전류(A rms). 측정 전에는 0(빼지 않음) — 잡음이 그대로 W로 보인다.
// TODO(HW 실측): 채널마다, 가전 전원을 뺀 상태에서 몇 분 기록해 정한다.
#define CT_NOISE_FLOOR_A_CH    {0.0f, 0.0f, 0.0f, 0.0f}
// 상용 전원 전압(V rms) — **측정하지 않는다**. vrms_est 필드로 그대로 내보내 추정임을 밝힌다. 한 콘센트라 공통.
// TODO(HW 실측): 현장 콘센트 전압.
#define MAINS_VRMS_EST         220.0f
// 역률 — 저항성 부하 가정. 전자레인지 인버터·세탁기 모터 부하는 1보다 작다. TODO(HW 실측): 채널마다.
#define POWER_FACTOR_EST_CH    {1.0f, 1.0f, 1.0f, 1.0f}

// ─── ADS1115(I2C) ───────────────────────────────────────────────────────────
// 가정 배선(채널마다 차동 한 쌍): CT 0 두 선 → AIN0·AIN1, CT 1 두 선 → AIN2·AIN3. 쌍의 뒤쪽(AIN1·AIN3)을 각각
// VDD/2 바이어스(분압 + 커패시터)에 묶는다. CT 하나일 때의 배선(AIN0-AIN1)이 그대로 채널 0이다.
// 차동 ±2.048 V 범위(PGA=2) — SCT-013-030 최대 1.414 V 피크에 여유. TODO(HW 확인): 실제 배선.
#define PIN_I2C_SDA            21
#define PIN_I2C_SCL            22
#define ADS1115_ADDR           0x48    // ADDR → GND
#define ADS1115_I2C_HZ         400000
// 채널 → MUX 값(설정 레지스터 14:12). 기본 ch0 = 000(AIN0-AIN1), ch1 = 011(AIN2-AIN3) — 차동 두 쌍이라 이 배선은 최대 2채널.
// 3채널 이상은 배선을 바꿔야 한다: 공통 바이어스 AIN3에 001(AIN0-AIN3)·010(AIN1-AIN3)·011(AIN2-AIN3)(최대 3), 또는
// 단일 입력 100~111(AINx-GND, 최대 4 — 바이어스 1.65 V + 피크 1.41 V가 ±2.048 V를 넘어 PGA를 001(±4.096 V)로 바꿔야
// 한다). 그때 이 표·ADS1115_CONFIG_BASE·ADS1115_UV_PER_LSB를 함께 고친다. 뒤 두 칸은 자리표시자. TODO(HW 확인)
#define ADS1115_MUX_CH         {0x0, 0x3, 0x6, 0x7}
// 설정 레지스터(MUX 제외): OS=1(변환 시작), PGA=010(±2.048 V), MODE=1(단발), DR=111(860 SPS), 비교기 끔.
#define ADS1115_CONFIG_BASE    0x85E3
#define ADS1115_UV_PER_LSB     62.5f   // 2.048 V / 32768

// ─── ESP32 내장 ADC(대안) ────────────────────────────────────────────────────
// 가정 배선: CT 0 한 선 → GPIO36(ADC1_CH0), CT 1 한 선 → GPIO39(ADC1_CH3), 다른 선은 각각 1.65 V 바이어스.
// 창마다 평균을 빼 DC를 없앤다. ADC1만 쓴다(ADC2는 Wi-Fi와 충돌) — 입력 전용 핀 두 개라 이 빌드는 최대 2채널.
// 틱마다 모든 채널을 읽는다(채널당 SAMPLE_HZ). TODO(HW 확인)
#define PIN_CT_ADC_CH          {36, 39}
#define OUTLET_CT_ADC_MAX_CHANNELS 2

// ─── 릴레이(가전 전원 차단) ──────────────────────────────────────────────────
// 부팅 기본 = 꺼짐(열림, 가전 전원 없음). 호스트가 relay_on을 보내야 켠다(fail-safe, README 참고).
// RELAY_ACTIVE_LEVEL: 릴레이를 '켬(접점 닫힘)'으로 만드는 GPIO 레벨.
// TODO(HW 확인): 실제 모듈 극성(활성 HIGH/LOW), 접점 정격(전자레인지 약 1~1.5 kW → 220 V에서 약 7 A
// + 돌입 전류), 절연 케이스.
#define PIN_RELAY              26
#define RELAY_ACTIVE_LEVEL     HIGH

// ─── 비상정지 버튼 ───────────────────────────────────────────────────────────
// 가정: NC(평상시 닫힘) 버튼을 GND에 연결 + 내부 풀업 → 평소 LOW, 눌림 **또는 단선** 시 HIGH = 활성.
// 단선도 정지로 읽혀야 버튼 고장이 '정지 불가'로 숨지 않는다. TODO(HW 확인): 실제 버튼 접점 형식.
#define PIN_ESTOP              27
#define ESTOP_ACTIVE_LEVEL     HIGH
#define ESTOP_USE_PULLUP       1
// 활성 샘플이 이만큼 연속이면 릴레이를 연다(SAMPLE_HZ 기준 약 2.5 ms·1 ms). 차단 쪽은 짧게 둔다 —
// 잡음으로 잘못 끊기는 것은 안전 쪽 실패다. 해제(estop_reset)는 버튼이 돌아온 뒤 호스트 명령으로만.
#define ESTOP_TRIP_SAMPLES     2
// 걸림을 재부팅 너머로 보존(RTC 메모리 + NVS). 1 = 켬(기본). 0이면 RTC 메모리만(전원이 꺼지면 풀린다) — 권하지 않는다.
#define OUTLET_ESTOP_PERSIST   1

// ─── 정적 검사 ───────────────────────────────────────────────────────────────
#if OUTLET_CT_SOURCE != OUTLET_CT_ADS1115 && OUTLET_CT_SOURCE != OUTLET_CT_ESP32_ADC
#error "OUTLET_CT_SOURCE는 OUTLET_CT_ADS1115(1) 또는 OUTLET_CT_ESP32_ADC(2)"
#endif
#if (1000000 % SAMPLE_HZ) != 0
#error "SAMPLE_HZ는 1 s를 정수 us로 나누는 값이어야 한다"
#endif
#if (SAMPLE_HZ % REPORT_HZ_DEFAULT) != 0
#error "REPORT_HZ_DEFAULT는 SAMPLE_HZ를 나누어떨어지게 해야 한다(창 길이 정수)"
#endif
#if OUTLET_CT_CHANNELS < 1 || OUTLET_CT_CHANNELS > OUTLET_CT_MAX_CHANNELS
#error "OUTLET_CT_CHANNELS는 1~4"
#endif
#if OUTLET_CT_SOURCE == OUTLET_CT_ESP32_ADC && OUTLET_CT_CHANNELS > OUTLET_CT_ADC_MAX_CHANNELS
#error "내장 ADC 빌드는 CT 2채널까지(입력 핀 GPIO36·GPIO39)"
#endif
#if OUTLET_RELAY_CH < 0 || OUTLET_RELAY_CH >= OUTLET_CT_CHANNELS
#error "OUTLET_RELAY_CH는 0 ~ OUTLET_CT_CHANNELS-1"
#endif
#if OUTLET_CT_SOURCE == OUTLET_CT_ADS1115 && ((SAMPLE_HZ / REPORT_HZ_DEFAULT) % OUTLET_CT_CHANNELS) != 0
#error "ADS1115 돌려 읽기: 기본 창 길이(틱)가 채널 수로 나누어떨어져야 채널마다 같은 샘플 수가 된다"
#endif
#if OUTLET_CT_SOURCE == OUTLET_CT_ADS1115
#define CT_DEFAULT_SAMPLES_PER_CHANNEL (SAMPLE_HZ / REPORT_HZ_DEFAULT / OUTLET_CT_CHANNELS)
#else
#define CT_DEFAULT_SAMPLES_PER_CHANNEL (SAMPLE_HZ / REPORT_HZ_DEFAULT)
#endif
// 기본 주기에서 평소에 하한 근처가 아니게 — 채널당 창 샘플이 하한의 두 배 이상(평가 A3).
#if CT_DEFAULT_SAMPLES_PER_CHANNEL < 2 * CT_MIN_SAMPLES_PER_WINDOW
#error "기본 보고 주기에서 채널당 창 샘플이 CT_MIN_SAMPLES_PER_WINDOW의 두 배보다 적다(평소에 끊김 근처)"
#endif
#if OUTLET_CT_SOURCE == OUTLET_CT_ADS1115 && (SAMPLE_HZ / REPORT_HZ_DEFAULT / OUTLET_CT_CHANNELS) < CT_MIN_SAMPLES_PER_WINDOW
#error "기본 보고 주기에서 채널당 창 샘플이 CT_MIN_SAMPLES_PER_WINDOW보다 적다"
#endif
#if OUTLET_CT_SOURCE == OUTLET_CT_ADS1115 && SAMPLE_HZ > 860
#error "ADS1115 연속 변환(860 SPS)보다 빨리 읽으면 같은 값을 두 번 읽는다"
#endif
#if HOST_SILENCE_RELAY_OFF && HOST_SILENCE_MS < 3000
#error "HOST_SILENCE_MS가 너무 짧다 — 호스트 heartbeat(기본 1 s) 몇 개 늦음으로 가전 전원이 끊긴다"
#endif
