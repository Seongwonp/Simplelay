#pragma once
// firmware-motion 설정 — **모든 값이 자리표시자(PLACEHOLDER)다. 실측값이 아니다.**
//
// 핀·방향·PID 게인·PWM 주파수·속도·기한·리밋 값은 하드웨어가 도착해 배선하고 재기 전까지
// 정할 수 없다. 여기 적힌 숫자는 "컴파일이 되게 하는 자리"일 뿐이며 실기기 설정의 근거로
// 쓰지 않는다. 각 줄의 TODO(HW 실측) 항목을 채운 뒤 아래 MOTION_CONFIG_PLACEHOLDER를 0으로
// 바꾸면 빌드 경고가 사라진다(값을 채우지 않고 0으로 바꾸지 않는다).
//
// 좌표 규약: 호스트(RPi4, rpi/controller/kinematics.py)가 XY mm → CoreXY 모터 카운트로 바꿔
// 보낸다. MCU는 모터별 목표 카운트만 다루며 counts-per-mm·풀리·벨트 값은 호스트 설정이다
// (SIMPLELAY_MOTION_R_OUT 등). Z는 mm 없이 카운트/시간만 쓴다(+ = 누르는 쪽).

// 모든 값이 실측으로 채워지면 0으로 바꾼다.
#define MOTION_CONFIG_PLACEHOLDER 1

// ─── 호스트 링크(RPi4 ↔ USB 시리얼) ─────────────────────────────────────────
// TODO(HW 실측): 보드레이트는 RPi4 쪽 SIMPLELAY_MOTION_BAUD와 같은 값으로 정한다.
#define HOST_SERIAL_BAUD       115200
#define HOST_RX_BUFFER_BYTES   1024
#define HOST_LINE_MAX          256     // 한 줄 최대 바이트(넘으면 그 줄은 버린다)
#define JSON_POOL_BYTES        6144    // ArduinoJson 고정 풀(힙 미사용)
// 워치독: 동작(home/move/press) 중 호스트 줄이 이 시간 동안 없으면 제동 후 STBY LOW + 알람.
// 현재 호스트(serial_motion.py)는 명령 하나를 보내고 응답만 기다리며 그 사이 아무 줄도 보내지
// 않는다. 그래서 이 값은 가장 긴 명령 기한보다 커야 한다(아래 #warning). 동작 중 heartbeat를
// 넣으면(호스트·fake_mcu·이 표를 함께 고친다) 줄일 수 있다.
// TODO(HW 실측): 원점 복귀 최장 시간 실측 뒤 정한다.
#define HOST_WATCHDOG_MS       25000

// ─── 제어 주기 ───────────────────────────────────────────────────────────────
// TODO(HW 실측): 엔코더 최대 속도·PID 안정성 보고 정한다.
#define CONTROL_PERIOD_US      1000

// ─── 모터 드라이버 핀(JMOD-MOTOR-1 = TB6612FNG ×2) ───────────────────────────
// 드라이버1: 채널A → 모터 A(CoreXY), 채널B → 모터 B(CoreXY). 드라이버2: 채널A → Z, 채널B 미사용.
// TODO(HW 실측): FireBeetle 실제 핀 배치·배선표로 확정. 모듈 논리 전원이 5 V면 3.3 V GPIO 직결을
//                보장할 수 없다(docs/JMOD-MOTOR-1-제어-검토.md) — 레벨 변환 여부 먼저 확인.
#define PIN_MOTOR_A_PWM        25
#define PIN_MOTOR_A_IN1        26
#define PIN_MOTOR_A_IN2        27
#define PIN_MOTOR_B_PWM        16
#define PIN_MOTOR_B_IN1        17
#define PIN_MOTOR_B_IN2        4
#define PIN_MOTOR_Z_PWM        18
#define PIN_MOTOR_Z_IN1        19
#define PIN_MOTOR_Z_IN2        23
#define PIN_STBY_AB            22      // 드라이버1 STBY (HIGH = 출력 켬)
#define PIN_STBY_Z             21      // 드라이버2 STBY

// TODO(HW 실측): 양(+) 듀티에서 엔코더 카운트가 늘지 않으면 해당 축을 1로.
#define MOTOR_A_INVERT         0
#define MOTOR_B_INVERT         0
#define MOTOR_Z_INVERT         0

// ─── PWM(LEDC) ──────────────────────────────────────────────────────────────
// TODO(HW 실측): TB6612 상한 100 kHz 안에서 소음·발열 보고 정한다.
#define PWM_FREQ_HZ            20000
#define PWM_RES_BITS           10
#define PWM_MAX_DUTY           ((1 << PWM_RES_BITS) - 1)
// TODO(HW 실측): 공급 전압(FIT0482 정격 6 V)에 맞춘 듀티 상한. 12 V 공급에 50%를 6 V 대용으로 쓰지 않는다.
#define PWM_LIMIT_XY           700
#define PWM_LIMIT_Z            600
// TODO(HW 실측): 모터가 실제로 돌기 시작하는 최소 듀티(데드밴드 보상).
#define PWM_MIN_EFFECTIVE      60

// ─── 엔코더(PCNT, x4 디코딩) ─────────────────────────────────────────────────
// 카운트는 A/B 두 채널의 모든 엣지를 센다(x4). 호스트 SIMPLELAY_MOTION_DECODING_MULTIPLIER=4,
// SIMPLELAY_MOTION_R_OUT은 이 x4 카운트 기준 실측값을 넣는다.
// TODO(HW 실측): 엔코더 출력 전압이 5 V면 ESP32 입력(3.3 V) 전에 분압·레벨 변환 필요.
//                GPIO34~39는 내부 풀업이 없다 — 오픈 컬렉터 출력이면 외부 풀업.
#define PIN_ENC_A_CHA          34
#define PIN_ENC_A_CHB          35
#define PIN_ENC_B_CHA          36
#define PIN_ENC_B_CHB          39
#define PIN_ENC_Z_CHA          32
#define PIN_ENC_Z_CHB          33
// TODO(HW 실측): 모터 방향 확정 뒤 카운트 부호가 반대면 1.
#define ENC_A_INVERT           0
#define ENC_B_INVERT           0
#define ENC_Z_INVERT           0
// TODO(HW 실측): 최고 속도 엣지 간격보다 짧게(최대 약 12,700 ns).
#define ENC_GLITCH_NS          1000

// ─── 리밋 스위치(NC) ─────────────────────────────────────────────────────────
// 기본 가정: NC 스위치를 GND에 연결 + 풀업 → 평소 LOW, 눌림(또는 단선) 시 HIGH = 활성.
// TODO(HW 실측): 실제 결선에 맞춰 활성 레벨·풀업 사용 여부 확정.
//                GPIO5는 부팅 스트래핑 핀이다(풀업 기본) — 다른 핀이 비면 옮긴다.
#define PIN_LIMIT_X            13      // X 원점 쪽
#define PIN_LIMIT_Y            14      // Y 원점 쪽
#define PIN_LIMIT_Z            5       // Z 위쪽(후퇴) 끝
#define LIMIT_ACTIVE_LEVEL     HIGH
#define LIMIT_USE_PULLUP       1
#define LIMIT_DEBOUNCE_TICKS   3       // 연속 같은 값 샘플 수(제어 주기 단위)

// ─── 위치 PID(듀티/카운트) ───────────────────────────────────────────────────
// TODO(HW 실측): 전부 튜닝 전 자리표시자. 무부하 → 벨트 장착 순으로 잡는다.
#define PID_XY_KP              2.0f
#define PID_XY_KI              0.0f
#define PID_XY_KD              0.02f   // 측정값 미분(카운트/초)에 곱한다
#define PID_XY_I_LIMIT         200.0f
#define PID_Z_KP               2.0f
#define PID_Z_KI               0.0f
#define PID_Z_KD               0.02f
#define PID_Z_I_LIMIT          200.0f
#define POS_TOLERANCE_COUNTS   4       // 도착 판정 허용 오차
#define SETTLE_MS              50      // 허용 오차 안에 머물러야 하는 시간

// ─── 속도(카운트/초) ─────────────────────────────────────────────────────────
// TODO(HW 실측): 공식 무부하 310 rpm은 상한일 뿐. 부하 상태 속도 실측 뒤 정한다.
#define MOVE_SPEED_CPS         2000.0f // 이동량이 큰 모터 기준
#define Z_SPEED_CPS            1000.0f
#define HOME_FAST_CPS          800.0f  // 첫 접근(느린 쪽 속도로 둔다)
#define HOME_SLOW_CPS          200.0f  // 후퇴·재접근
#define HOME_MAX_LEAD_COUNTS   60      // 목표가 실제 위치보다 이만큼 앞서면 더 밀지 않는다

// ─── 원점 복귀 ───────────────────────────────────────────────────────────────
// 순서: Z(위로) → X → Y. 각 축: 접근 → 스위치 해제까지 후퇴 → 저속 재접근 → 후퇴한 곳을 0.
// CoreXY에서 순수 X/Y 이동은 두 모터를 함께 돌린다. 아래 부호는 호스트 a_sign=b_sign=+1 가정의
// -X(A-,B-), -Y(A-,B+)이다. TODO(HW 실측): 호스트 a_sign·b_sign과 스위치 위치에 맞춰 확정.
#define HOME_X_DIR_A           (-1)
#define HOME_X_DIR_B           (-1)
#define HOME_Y_DIR_A           (-1)
#define HOME_Y_DIR_B           (+1)
#define HOME_Z_DIR             (-1)    // Z 카운트 + = 누름, 원점은 위쪽
// TODO(HW 실측): 스위치 해제 여유·최대 탐색 거리.
#define HOME_BACKOFF_COUNTS    200
#define HOME_MAX_TRAVEL_COUNTS 200000
#define HOME_RELEASE_FACTOR    4       // 후퇴·재접근 탐색 한도 = BACKOFF × 이 값

// ─── 소프트 리밋(원점 기준 카운트) ───────────────────────────────────────────
// 호스트도 mm 소프트 리밋을 먼저 검사한다. 이것은 MCU 쪽 두 번째 벽이다.
// TODO(HW 실측): 기구 이동 한계 - 여유. A=x+y, B=x-y(카운트 환산) 범위로 잡는다.
#define A_MIN_COUNTS           (-10)
#define A_MAX_COUNTS           20000
#define B_MIN_COUNTS           (-10000)
#define B_MAX_COUNTS           10000
// move의 x_mm·y_mm가 오면 함께 검사한다(호스트 SIMPLELAY_MOTION_X/Y_MIN/MAX_MM과 같게).
#define X_MIN_MM               0.0f
#define X_MAX_MM               100.0f
#define Y_MIN_MM               0.0f
#define Y_MAX_MM               100.0f

// ─── Z 누름 ──────────────────────────────────────────────────────────────────
// TODO(HW 실측): 버튼 스트로크·Z 기구 확정 뒤. 호스트 press_depth_max_counts 이하로.
#define Z_PRESS_MAX_COUNTS     60
#define PRESS_DRIVE_MAX_MS     500     // duration 방식 구동 시간 상한(호스트 press_drive_max_ms 이하)
#define PRESS_DRIVE_PWM        400     // duration 방식 구동 듀티
#define PRESS_DWELL_MAX_MS     3000

// ─── 명령 기한(MCU 자체) ─────────────────────────────────────────────────────
// TODO(HW 실측): 호스트 *_TIMEOUT_S보다 짧게 잡아 MCU가 먼저 실패를 보고하게 한다.
#define HOME_MAX_MS            20000
#define MOVE_MAX_MS            8000
#define PRESS_MAX_MS           5000

// ─── 스톨·제동 ───────────────────────────────────────────────────────────────
// TODO(HW 실측): 이 듀티 이상을 주는데 STALL_TIMEOUT_MS 동안 카운트 변화가 MIN_DELTA 미만이면 스톨.
#define STALL_MIN_PWM          200
#define STALL_MIN_DELTA_COUNTS 2
#define STALL_TIMEOUT_MS       300
// TODO(HW 실측): 알람·워치독 시 short brake 유지 시간(그 뒤 STBY LOW). 정지 거리 실측 뒤.
#define FAULT_BRAKE_MS         50
// 이동·누름 중 위치 보고 {"event":"position","a","b","z"} 주기(ms). 끝날 때는 ok 응답 직전에
// 한 번 더 보낸다. 호스트(serial_motion.py last_position → 실모드 트윈)가 엔코더 위치를 안다.
#define POSITION_EVENT_MS      100

// ─── 정적 검사 ───────────────────────────────────────────────────────────────
#if PWM_LIMIT_XY > PWM_MAX_DUTY || PWM_LIMIT_Z > PWM_MAX_DUTY || PRESS_DRIVE_PWM > PWM_MAX_DUTY
#error "PWM 상한이 PWM_MAX_DUTY보다 크다"
#endif
#if HOST_WATCHDOG_MS <= HOME_MAX_MS || HOST_WATCHDOG_MS <= MOVE_MAX_MS || HOST_WATCHDOG_MS <= PRESS_MAX_MS
#warning "HOST_WATCHDOG_MS가 명령 기한보다 짧다 — 호스트가 동작 중 heartbeat를 보내지 않으면 정상 동작도 host_timeout으로 끊긴다"
#endif
