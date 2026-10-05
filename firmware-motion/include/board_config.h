#pragma once
// 보드·배선·기구 설정 — **핀과 기구 값은 전부 이 파일 하나에 둔다**(2026-10-05).
//
// 팀원(HW)이 ESP32에서 돌린 모션 코드의 핀 맵·방향·기구 값을 합칠 때 **이 파일만** 고치면 되게 했다.
// 소스(src/)에는 핀 번호를 쓰지 않는다(rpi/tests/test_motion_z_mode.py가 확인). 튜닝 값(PID·속도·기한·
// 워치독)은 include/config.h에 남는다.
//
// 여기 숫자는 전부 **자리표시자**다. `팀원 확인 필요` 표시가 붙은 줄은 팀원 코드·배선에서 받은 값으로
// 바꾼다. 실측값이 아니며 실기기 설정의 근거로 쓰지 않는다. 다 채우면 config.h의
// MOTION_CONFIG_PLACEHOLDER를 0으로 바꾼다.

// ─── Z 누름 방식(빌드 플래그) ───────────────────────────────────────────────
// Z_MODE_MOTOR    : 엔코더 DC 모터(FIT0482) + TB6612 두 번째 채널. depth(카운트)·duration(시간) 누름.
// Z_MODE_SOLENOID : GPIO 하나 → MOSFET(로직 레벨) → 솔레노이드. duration 누름만(켜짐 시간 기반),
//                   depth는 z_unsupported로 거절. 후퇴 = 전원 끊기(스프링 복귀 가정).
// 기본은 Z_MODE_MOTOR(9/29 설계 그대로). platformio.ini의 *_solenoid 환경이 -DZ_MODE=Z_MODE_SOLENOID로 빌드한다.
// 팀원 확인 필요: Z가 스위치봇 분해 모듈·솔레노이드·모터 중 무엇인지(하드웨어 방향 문서 §5).
#define Z_MODE_MOTOR           1
#define Z_MODE_SOLENOID        2
#ifndef Z_MODE
#define Z_MODE                 Z_MODE_MOTOR
#endif
#if Z_MODE != Z_MODE_MOTOR && Z_MODE != Z_MODE_SOLENOID
#error "Z_MODE는 Z_MODE_MOTOR 또는 Z_MODE_SOLENOID"
#endif
#if Z_MODE == Z_MODE_SOLENOID
#define Z_MODE_NAME            "solenoid"
#else
#define Z_MODE_NAME            "motor"
#endif

// ─── 모터 드라이버 핀(JMOD-MOTOR-1 = TB6612FNG) ─────────────────────────────
// 드라이버1: 채널A → 모터 A(CoreXY), 채널B → 모터 B(CoreXY). 드라이버2: 채널A → Z(모터 방식일 때만).
// 팀원 확인 필요: 실제 ESP32 보드 종류(FireBeetle/DevKit)와 핀 배치. 모듈 논리 전원이 5 V면 레벨 변환.
// 스트래핑 핀(0·2·5·12·15)은 입력으로 쓰지 않는다. GPIO5는 부팅 때 풀업·PWM 신호가 나올 수 있어
// 출력(모터 B IN2)으로만 쓴다 — STBY가 LOW(외부 풀다운)인 동안 IN 핀 흔들림은 모터에 닿지 않는다.
#define PIN_MOTOR_A_PWM        25      // 팀원 확인 필요
#define PIN_MOTOR_A_IN1        26      // 팀원 확인 필요
#define PIN_MOTOR_A_IN2        27      // 팀원 확인 필요
#define PIN_MOTOR_B_PWM        16      // 팀원 확인 필요
#define PIN_MOTOR_B_IN1        17      // 팀원 확인 필요
#define PIN_MOTOR_B_IN2        5       // 팀원 확인 필요. 2026-09-29: GPIO4 → GPIO5(리밋 Z와 맞바꿈)
// STBY 두 핀에 외부 풀다운(예: 10 kΩ) — 리셋·패닉 중에도 출력이 꺼져 있게. 팀원 확인 필요(모듈에 STBY 핀이 나와 있는지).
#define PIN_STBY_AB            22      // 드라이버1 STBY (HIGH = 출력 켬). 팀원 확인 필요
#if Z_MODE == Z_MODE_MOTOR
#define PIN_MOTOR_Z_PWM        18      // 팀원 확인 필요
#define PIN_MOTOR_Z_IN1        19      // 팀원 확인 필요
#define PIN_MOTOR_Z_IN2        23      // 팀원 확인 필요
#define PIN_STBY_Z             21      // 드라이버2 STBY. 팀원 확인 필요
#endif

// 양(+) 듀티에서 엔코더 카운트가 늘지 않으면 해당 축을 1로. 팀원 확인 필요(팀원 코드의 방향 부호).
#define MOTOR_A_INVERT         0
#define MOTOR_B_INVERT         0
#define MOTOR_Z_INVERT         0

// ─── 솔레노이드(Z_MODE_SOLENOID) ─────────────────────────────────────────────
// GPIO → 로직 레벨 N-MOSFET 게이트(직렬 저항 + 게이트 풀다운 — 리셋·부팅 중 꺼짐), 코일 양단 역전압 다이오드.
// 켜짐 = SOLENOID_ACTIVE_LEVEL. 스트래핑 핀 금지(부팅 때 잠깐 켜질 수 있다).
// 팀원 확인 필요: 핀, 솔레노이드 정격 전압·전류(전원 여유), 스트로크·복귀 스프링, MOSFET 부품.
#define PIN_SOLENOID           18      // 팀원 확인 필요(모터 방식의 Z PWM 자리 — 솔레노이드 방식에서는 비어 있다)
#define SOLENOID_ACTIVE_LEVEL  HIGH    // 팀원 확인 필요
// 한 번 켜 둘 수 있는 최대 시간(ms). 누름 요청의 drive_ms + dwell_ms가 이것을 넘으면 soft_limit으로 거절하고,
// 어떤 경로로든 이 시간을 넘겨 켜져 있으면 제어 주기에서 강제로 끈다(timeout 알람). 측정 필요(코일 발열).
#define SOLENOID_ON_MAX_MS     800
// 코일 발열 보호: 끈 뒤 다음에 켤 수 있을 때까지 최소 max(SOLENOID_MIN_OFF_MS, 직전 켜짐 시간 × SOLENOID_OFF_RATIO).
// 안 지났으면 z_cooldown으로 거절한다(움직이지 않은 거절 — 호스트는 재홈하지 않는다). 측정 필요.
#define SOLENOID_MIN_OFF_MS    300
#define SOLENOID_OFF_RATIO     3       // 켜짐 1 : 꺼짐 3 이상(듀티 25% 이하) — 측정 필요
// 끈 뒤 스프링이 플런저를 되돌리는 시간(ms). 이만큼 기다린 뒤 press 완료(ok)를 보낸다. 측정 필요.
#define SOLENOID_RELEASE_MS    80

// ─── 엔코더(PCNT, x4 디코딩) ─────────────────────────────────────────────────
// 엔코더 출력 전압이 5 V면 ESP32 입력(3.3 V) 전에 분압·레벨 변환. GPIO34~39는 내부 풀업이 없다.
// ESP32 errata 3.11: ADC·Hall을 켜면 GPIO36·39 입력이 약 80 ns LOW로 끌린다(ENC_GLITCH_NS가 거르는지 확인).
// 팀원 확인 필요: 핀, 엔코더 전원·출력 방식, 팀원 코드가 x1/x2/x4 중 무엇으로 셌는지.
#define PIN_ENC_A_CHA          34      // 팀원 확인 필요
#define PIN_ENC_A_CHB          35      // 팀원 확인 필요
#define PIN_ENC_B_CHA          36      // 팀원 확인 필요
#define PIN_ENC_B_CHB          39      // 팀원 확인 필요
#if Z_MODE == Z_MODE_MOTOR
#define PIN_ENC_Z_CHA          32      // 팀원 확인 필요
#define PIN_ENC_Z_CHB          33      // 팀원 확인 필요
#endif
// 모터 방향 확정 뒤 카운트 부호가 반대면 1. 팀원 확인 필요.
#define ENC_A_INVERT           0
#define ENC_B_INVERT           0
#define ENC_Z_INVERT           0

// ─── 리밋 스위치 ─────────────────────────────────────────────────────────────
// 기본 가정: NC 스위치를 GND에 연결 + 풀업 → 평소 LOW, 눌림(또는 단선) 시 HIGH = 활성.
// 팀원 확인 필요: NO/NC, 활성 레벨, 풀업 위치(내부/외부), 스위치가 X·Y 어느 끝(원점 쪽)에 있는지.
// 솔레노이드 방식은 Z 위쪽 리밋이 없다(-1 = 없음, limits 응답의 z는 항상 false).
#define PIN_LIMIT_X            13      // X 원점 쪽. 팀원 확인 필요
#define PIN_LIMIT_Y            14      // Y 원점 쪽. 팀원 확인 필요
#if Z_MODE == Z_MODE_MOTOR
#define PIN_LIMIT_Z            4       // Z 위쪽(후퇴) 끝. 팀원 확인 필요
#else
#define PIN_LIMIT_Z            (-1)
#endif
#define LIMIT_ACTIVE_LEVEL     HIGH    // 팀원 확인 필요
#define LIMIT_USE_PULLUP       1       // 팀원 확인 필요

// ─── 원점 방향(CoreXY) ───────────────────────────────────────────────────────
// 순수 X/Y 이동은 두 모터를 함께 돌린다. 아래 부호는 호스트 a_sign=b_sign=+1 가정의 -X(A-,B-), -Y(A-,B+).
// 팀원 확인 필요: 스위치 위치·모터 방향(팀원 코드에서 '원점 쪽'으로 갈 때 두 모터의 부호).
#define HOME_X_DIR_A           (-1)
#define HOME_X_DIR_B           (-1)
#define HOME_Y_DIR_A           (-1)
#define HOME_Y_DIR_B           (+1)
#define HOME_Z_DIR             (-1)    // Z 카운트 + = 누름, 원점은 위쪽(모터 방식만)

// ─── 기구 범위(원점 기준) ─────────────────────────────────────────────────────
// 호스트도 mm 소프트 리밋을 먼저 검사한다. 이것은 MCU 쪽 두 번째 벽이다. A=x+y, B=x-y(카운트 환산).
// 팀원 확인 필요: 실제 이동 범위(mm)와 그 카운트.
#define A_MIN_COUNTS           (-10)
#define A_MAX_COUNTS           20000
#define B_MIN_COUNTS           (-10000)
#define B_MAX_COUNTS           10000
#define X_MIN_MM               0.0f    // 호스트 SIMPLELAY_MOTION_X_MIN_MM과 같게
#define X_MAX_MM               100.0f  // 팀원 확인 필요
#define Y_MIN_MM               0.0f
#define Y_MAX_MM               100.0f  // 팀원 확인 필요
// 원점 탐색 최대 거리(카운트) — 기구 전체 길이 + 여유.
#define HOME_XY_MAX_TRAVEL_COUNTS 12000
#define HOME_Z_MAX_TRAVEL_COUNTS  3000
// Z 누름 최대 깊이(카운트, 모터 방식). 호스트 press_depth_max_counts 이하로.
#define Z_PRESS_MAX_COUNTS     60

// ─── 기구 참고값(호스트 환경 변수와 맞춰 적어 두는 자리 — MCU 코드는 쓰지 않는다) ─────
// 좌표 변환(mm ↔ 카운트)은 RPi4(rpi/controller/kinematics.py)가 한다. 팀원 값을 받으면 여기와 RPi4 env에 같이 적는다.
// 팀원 확인 필요: 출력축 1회전 카운트(x4 기준, 감속비 포함), 풀리 톱니 수, 벨트 피치.
#define BOARD_ENC_COUNTS_PER_OUTPUT_REV 0   // → SIMPLELAY_MOTION_R_OUT (0 = 아직 모름)
#define BOARD_PULLEY_TEETH              0   // → SIMPLELAY_MOTION_PULLEY_TEETH
#define BOARD_BELT_PITCH_UM             0   // → SIMPLELAY_MOTION_BELT_PITCH_MM(×1000, GT2면 2000)
