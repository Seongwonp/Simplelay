// 원작: 팀원(서예솔) Touch Bridge CoreXY 펌웨어 v3, SimpleLay용으로 통신·이름 수정
// =====================================================================
//  SimpleLay 모션 MCU(CoreXY) 설정 — 2026-10-10 수령본에서 옮김. **실물 미검증.**
//  하드웨어: ESP32 DevKit + JMOD-MOTOR-1(TB6612FNG) + DFRobot FIT0482 x2
//
//  SimpleLay 수정(2026-10-10):
//  - 리밋 핀: 원작의 PIN_LIMIT_X=30·PIN_LIMIT_Y=100은 ESP32에 없는 GPIO였다(USE_LIMIT_SWITCHES=false라
//    쓰이지 않았을 뿐). 빈 GPIO 21·22로 바꾸고, 핀이 유효한지 컴파일 때 static_assert로 막는다.
//  - 기구·게인·속도 값은 원작 값 그대로 두되 전부 `실측 필요`로 표시했다(벨트 걸기 전·후에 다시 잰다).
//  - 맨 아래에 SimpleLay 줄 단위 JSON 규약(호스트 링크·워치독·솔레노이드 상한·명령 기한) 절을 더했다.
// =====================================================================
#pragma once
#include <Arduino.h>

// ---------------- 핀 배치 (ESP32 DevKit V1 기준) ----------------
// 스트래핑 핀(0, 2, 5, 12, 15)과 입력 전용 핀(34~39)은 출력에 쓰지 않음
// 팀원 확인 필요: 실제 배선이 이 표와 같은지(README 배선 표).
constexpr int PIN_STBY  = 4;    // TB6612 STBY (HIGH = 동작). **외부 풀다운 필요**(리셋·패닉 중 High-Z → 출력 꺼짐)

constexpr int PIN_A_PWM = 25;   // 모터 A (CoreXY 왼쪽 모터)
constexpr int PIN_A_IN1 = 26;
constexpr int PIN_A_IN2 = 27;

constexpr int PIN_B_PWM = 32;   // 모터 B (CoreXY 오른쪽 모터)
constexpr int PIN_B_IN1 = 33;
constexpr int PIN_B_IN2 = 13;

constexpr int PIN_ENC_A_A = 16; // 모터 A 엔코더 A/B상 (WROVER 모듈이면 16·17이 PSRAM — WROOM-32 기준)
constexpr int PIN_ENC_A_B = 17;
constexpr int PIN_ENC_B_A = 18; // 모터 B 엔코더 A/B상
constexpr int PIN_ENC_B_B = 19;

// 리밋 스위치(선택). false면 스톨(벽에 닿음) 감지로 원점 복귀
constexpr bool USE_LIMIT_SWITCHES = false;
// SimpleLay 수정: 원작 30·100은 ESP32에 없는 GPIO. 내부 풀업이 있는 빈 핀 21·22로 옮겼다(팀원 확인 필요).
constexpr int  PIN_LIMIT_X = 21;  // NO 스위치, GND로 단락 = 눌림 (INPUT_PULLUP)
constexpr int  PIN_LIMIT_Y = 22;

// ---------------- 방향 보정 ----------------
// 실측 필요: README '처음 켤 때 순서'(bring-up 빌드의 M 명령)로 시험해서 맞춤
constexpr bool MOTOR_A_INVERT = false;
constexpr bool MOTOR_B_INVERT = false;
constexpr bool ENC_A_INVERT   = true;
constexpr bool ENC_B_INVERT   = true;

// ---------------- PWM ----------------
constexpr uint32_t PWM_FREQ_HZ  = 20000;  // 20kHz: 가청 대역 밖
constexpr uint8_t  PWM_RES_BITS = 10;
constexpr uint32_t PWM_MAX      = (1u << PWM_RES_BITS) - 1;
constexpr uint8_t  PWM_CH_A = 0;          // ESP32 core 2.x에서만 사용
constexpr uint8_t  PWM_CH_B = 1;

// ---------------- 기구 (전부 실측 필요) ----------------
// FIT0482: 홀센서 7극쌍 -> 모터축 1회전당 7펄스/상, 쿼드러처 x4 = 28카운트 (실측 필요: 출력축 1회전 카운트)
constexpr float ENC_COUNTS_PER_MOTOR_REV = 7.0f * 4.0f;
constexpr float GEAR_RATIO      = 50.0f;                                 // 실측 필요
constexpr float COUNTS_PER_REV  = ENC_COUNTS_PER_MOTOR_REV * GEAR_RATIO; // 1400 → RPi4 SIMPLELAY_MOTION_R_OUT과 같게
// GT2 벨트 + 20T 풀리 가정 -> 실제 풀리에 맞게 수정 (실측 필요)
constexpr float PULLEY_TEETH    = 20.0f;                                 // → SIMPLELAY_MOTION_PULLEY_TEETH
constexpr float BELT_PITCH_MM   = 2.0f;                                  // → SIMPLELAY_MOTION_BELT_PITCH_MM
constexpr float MM_PER_REV      = PULLEY_TEETH * BELT_PITCH_MM;          // 40mm
constexpr float COUNTS_PER_MM   = COUNTS_PER_REV / MM_PER_REV;           // 35

// 작업 영역. 시연 빌드는 좌하단 원점, 시험대 빌드는 현재 위치를 임시 원점으로
// 잡으므로 네 모서리 탐색을 위해 음수 방향도 허용한다. 실제 기구 한계는 미측정.
#if defined(BENCH_HOME_AT_CURRENT) && BENCH_HOME_AT_CURRENT
constexpr float X_MIN_MM = -200.0f;
constexpr float Y_MIN_MM = -200.0f;
#else
constexpr float X_MIN_MM = 0.0f;
constexpr float Y_MIN_MM = 0.0f;
#endif
constexpr float X_MAX_MM = 200.0f;
constexpr float Y_MAX_MM = 200.0f;

// ---------------- 모션 (실측 필요) ----------------
// FIT0482 정격 180rpm x 40mm = 120mm/s 벨트 속도. 여유를 두고 제한
constexpr float MOTOR_BELT_VMAX = 80.0f;   // 모터 하나의 벨트 속도 상한 [mm/s]
constexpr float MOTOR_BELT_AMAX = 400.0f;  // [mm/s^2]
constexpr float DEFAULT_SPEED   = 50.0f;   // XY 기본 이송 속도 [mm/s]
constexpr float DEFAULT_ACCEL   = 300.0f;  // XY 가속도 [mm/s^2]

constexpr float HOMING_SPEED     = 10.0f;  // [mm/s]
constexpr float HOMING_PWM_LIMIT = 0.40f;  // 원점 복귀 중 출력 제한 (벽 충돌 보호)
constexpr float HOMING_BACKOFF   = 3.0f;   // 원점에서 떨어질 거리 [mm]
constexpr float STALL_ERR_MM     = 1.5f;   // 스톨 판정 추종 오차
constexpr float STALL_ARM_S      = 0.30f;  // 출발 직후 이 시간 동안은 스톨 판정 안 함

// ---------------- 제어기 (게인 전부 실측 필요 — 무부하 → 벨트 장착 순) ----------------
constexpr float CONTROL_HZ = 1000.0f;

// 출력 단위: PWM 비율(-1~1), 오차 단위: 엔코더 카운트
constexpr float DEFAULT_KP  = 0.020f;     // 50카운트(약 1.4mm) 오차 = 최대 출력
constexpr float DEFAULT_KI  = 0.050f;
constexpr float DEFAULT_KD  = 0.00005f;   // 속도 오차 [count/s] 기준
constexpr float DEFAULT_KFF = 0.00012f;   // 속도 피드포워드 (6V 무부하 ~7200 count/s)
constexpr float I_LIMIT     = 0.30f;      // 적분항 상한
constexpr float PWM_MIN     = 0.08f;      // 정지 마찰 보상 (데드밴드)
constexpr float D_FILTER_ALPHA = 0.10f;   // 측정 속도 저역통과

// 시험대 빌드에서만 넓힌다. 자유 공간의 Y -5 명령은
// (-175,175) 목표에 (-166,167)까지 간 뒤 정지 마찰로 더 좁혀지지 않았다.
// 대략 0.46mm 허용은 좌표 탐색 전용이며 정밀 누름의 성공 근거가 아니다.
// 시연 빌드의 엄격한 3카운트 기준은 변경하지 않는다.
#if defined(BENCH_HOME_AT_CURRENT) && BENCH_HOME_AT_CURRENT
constexpr int32_t POS_TOL_COUNTS  = 16;
#else
constexpr int32_t POS_TOL_COUNTS  = 3;    // 도착 허용 오차 (~0.09mm)
#endif
constexpr float   SETTLE_S        = 0.05f;
#if defined(BENCH_HOME_AT_CURRENT) && BENCH_HOME_AT_CURRENT
constexpr float   SETTLE_TIMEOUT_S = 0.4f;  // 좌표 탐색: 벽에서 1초 밀어붙이지 않는다
#else
constexpr float   SETTLE_TIMEOUT_S = 1.0f;
#endif

// ---------------- 안전 (실측 필요) ----------------
#if defined(BENCH_HOME_AT_CURRENT) && BENCH_HOME_AT_CURRENT
constexpr float FOLLOW_ERR_MAX_MM = 10.0f;  // 조그 최대 5mm의 벽 접촉은 MOVE_PARTIAL로 처리
#else
constexpr float FOLLOW_ERR_MAX_MM = 4.0f;   // 추종 오차 한계 (걸림·탈조 감지)
#endif
constexpr float FOLLOW_ERR_TIME_S = 0.20f;  // 이 시간 이상 지속되면 FAULT

// =====================================================================
//  SimpleLay 추가 — 줄 단위 JSON 규약(line-json/v0) over USB 시리얼
//  호스트: rpi/controller/serial_motion.py, 기준: rpi/tools/fake_mcu.py,
//  명령 표: firmware-motion/protocol_table.json (이 펌웨어도 같은 표를 따른다)
// =====================================================================
#define FW_NAME_BASE           "firmware-motion-corexy"
#define HOST_SERIAL_BAUD       115200   // → RPi4 SIMPLELAY_MOTION_BAUD=115200
#define HOST_RX_BUFFER_BYTES   1024
#define HOST_TX_BUFFER_BYTES   1024
#define HOST_LINE_MAX          256      // 한 줄 최대 바이트(넘으면 그 줄은 통째로 버린다)
#define JSON_POOL_BYTES        4096     // ArduinoJson 고정 풀(힙 미사용)

// 호스트 워치독: 받은 줄이 하나도 없이 이 시간이 지나면 — 동작 중이면 host_timeout 알람으로 멈추고,
// 위치 유지(IDLE) 중이면 알람 없이 출력만 내린다. 호스트는 동작 응답을 기다리는 동안 HOST_HEARTBEAT_MS마다 ping.
// 실측 필요: USB 지연·RPi4 부하에서 ping 간격이 얼마나 벌어지는지.
#define HOST_HEARTBEAT_MS      500      // RPi4 SIMPLELAY_MOTION_HEARTBEAT_MS 기본값과 같게
#define HOST_WATCHDOG_MS       2000
#if HOST_WATCHDOG_MS < 3 * HOST_HEARTBEAT_MS
#error "HOST_WATCHDOG_MS < 3 * HOST_HEARTBEAT_MS — heartbeat 한두 번 늦는 것으로 멈추면 안 된다"
#endif

// MCU 태스크 워치독(esp_task_wdt): loop·제어 태스크가 멈추면 패닉 → 재부팅 → ready 배너 reset="task_wdt".
#define MCU_TASK_WDT_MS        1000

// 명령 기한(백스톱 — 원작 코어의 FAULT_SETTLE·FAULT_HOME·추종 오차가 먼저 잡는다). 실측 필요.
// 원점 복귀: 축마다 최대 (X_MAX_MM×1.3+20)/HOMING_SPEED ≈ 28 s → 두 축 + 후퇴. RPi4 SIMPLELAY_MOTION_HOME_TIMEOUT_S는 이보다 길게.
#define HOME_MAX_MS            70000
#define MOVE_MAX_MS            15000
#define PRESS_TIMEOUT_MARGIN_MS 1000
#define SWITCHBOT_REQUEST_MAX_MS 10000  // BLE 연결 전체 백스톱. notify ACK_TIMEOUT_MS는 SwitchBotBLE.h에서 더 짧게 끝난다.

// 정지·알람 뒤 short brake를 이 시간 유지한 다음 STBY LOW(출력 High-Z).
#define STOP_BRAKE_MS          100
#define FAULT_BRAKE_MS         100

// 이동·누름 중 위치 보고(position 이벤트) 간격.
#define POSITION_EVENT_MS      100

// 호스트가 보낸 a·b(카운트)를 이 펌웨어의 역기구학으로 mm로 바꾼 값과 호스트가 함께 보낸 x_mm·y_mm의 차 상한.
// 넘으면 호스트(RPi4 SIMPLELAY_MOTION_*)와 이 config.h의 기구 값이 다르다는 뜻 — bad_args로 움직이기 전에 거절.
#define KIN_MATCH_TOL_MM       0.5f

// 원작의 positionToken 검사(이동 뒤 위치가 밀렸으면 누르지 않음)를 옮긴 것: 누름 직전 측정 위치와 마지막
// 이동 목표의 거리 상한(원작 toleranceMm 기본 0.7). 넘으면 not_homed로 거절하고 원점 기준을 버린다. 실측 필요.
#define PRESS_POS_TOL_MM       0.7f

// 리밋 디바운스(loop 한 바퀴 ≈ 1 ms 단위 연속 샘플 수). USE_LIMIT_SWITCHES일 때만.
#define LIMIT_DEBOUNCE_SAMPLES 5

// ---------------- Z 누름 장치 선택 ----------------
#ifndef Z_ACTUATOR_SWITCHBOT
#define Z_ACTUATOR_SWITCHBOT 0
#endif

#if Z_ACTUATOR_SWITCHBOT
#ifndef SWITCHBOT_MAC
#error "Z_ACTUATOR_SWITCHBOT=1에는 SWITCHBOT_MAC이 필요하다"
#endif
#define Z_MODE_NAME            "switchbot"
#else
#define Z_MODE_NAME            "solenoid"
#endif

// ---------------- 솔레노이드(Z 누름) — 실측 필요 ----------------
// 원작의 구동(SOL_HIT_MS 100% → SOL_HOLD_DUTY 유지, SOL_SETTLE_MS)은 main.cpp에 그대로 있다.
// 아래는 SimpleLay 규약 쪽 상한·발열 보호(firmware-motion과 같은 이름·의미).
#define SOLENOID_ON_MAX_MS     800      // 한 번 누름 켜짐(drive_ms + dwell_ms) 상한 → 넘으면 soft_limit. ready·status z_on_max_ms
#define PRESS_DRIVE_MAX_MS     500      // drive_ms 상한(호스트 press_drive_max_ms 이하)
#define PRESS_DWELL_MAX_MS     800
#define SOLENOID_MIN_OFF_MS    300      // 끈 뒤 다음 켜짐까지 최소 꺼짐(부팅 직후에도 적용)
#define SOLENOID_OFF_RATIO     3        // 꺼짐 ≥ 켜짐 × 이 값(듀티 25% 이하)
#define SOL_BACKSTOP_GRACE_MS  50       // 켜짐이 SOLENOID_ON_MAX_MS + 이 값을 넘으면 어떤 경로든 끈다

#if SOLENOID_MIN_OFF_MS <= 0 || SOLENOID_OFF_RATIO < 1
#error "솔레노이드 냉각(SOLENOID_MIN_OFF_MS > 0, SOLENOID_OFF_RATIO >= 1)이 필요하다 — 코일 발열 보호"
#endif

// ---------------- 핀 검사 (SimpleLay 추가) ----------------
// ESP32(WROOM-32)에 있는 GPIO: 0~19, 21~23, 25~27, 32~39. 6~11은 내부 플래시.
constexpr bool gpioExists(int p) {
  return (p >= 0 && p <= 19) || (p >= 21 && p <= 23) || (p >= 25 && p <= 27) || (p >= 32 && p <= 39);
}
constexpr bool gpioUsable(int p) { return gpioExists(p) && !(p >= 6 && p <= 11); }
constexpr bool gpioOutputOk(int p) {
  return gpioUsable(p) && p < 34 && p != 0 && p != 2 && p != 5 && p != 12 && p != 15;
}
constexpr bool gpioPullupInputOk(int p) { return gpioUsable(p) && p < 34; }  // 34~39는 내부 풀업 없음

static_assert(gpioOutputOk(PIN_STBY) && gpioOutputOk(PIN_A_PWM) && gpioOutputOk(PIN_A_IN1) &&
                  gpioOutputOk(PIN_A_IN2) && gpioOutputOk(PIN_B_PWM) && gpioOutputOk(PIN_B_IN1) &&
                  gpioOutputOk(PIN_B_IN2),
              "모터 출력 핀이 ESP32에 없거나 플래시·스트래핑·입력 전용 핀이다");
static_assert(gpioPullupInputOk(PIN_ENC_A_A) && gpioPullupInputOk(PIN_ENC_A_B) &&
                  gpioPullupInputOk(PIN_ENC_B_A) && gpioPullupInputOk(PIN_ENC_B_B),
              "엔코더 핀은 INPUT_PULLUP을 쓰므로 내부 풀업이 있는 GPIO(34 미만)여야 한다");
static_assert(!USE_LIMIT_SWITCHES || (gpioPullupInputOk(PIN_LIMIT_X) && gpioPullupInputOk(PIN_LIMIT_Y)),
              "리밋 핀이 ESP32에 없는 GPIO이거나 내부 풀업이 없다(원작의 30·100 같은 값)");
static_assert(gpioPullupInputOk(PIN_LIMIT_X) && gpioPullupInputOk(PIN_LIMIT_Y),
              "리밋 핀은 쓰지 않더라도 유효한 GPIO로 둔다(켜는 순간 잘못된 핀을 읽지 않게)");
