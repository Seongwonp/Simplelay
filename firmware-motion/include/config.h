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

// 핀·방향·리밋 결선·원점 방향·기구 범위·Z 누름 방식(모터/솔레노이드)은 include/board_config.h 한 파일에
// 있다(2026-10-05, 팀원 코드 합치기용). 이 파일은 튜닝 값(PID·속도·기한·워치독)만 둔다.
#include "board_config.h"

// 모든 값(board_config.h 포함)이 실측으로 채워지면 0으로 바꾼다.
#define MOTION_CONFIG_PLACEHOLDER 1

// ─── 호스트 링크(RPi4 ↔ USB 시리얼) ─────────────────────────────────────────
// TODO(HW 실측): 보드레이트는 RPi4 쪽 SIMPLELAY_MOTION_BAUD와 같은 값으로 정한다.
#define HOST_SERIAL_BAUD       115200
#define HOST_RX_BUFFER_BYTES   1024
// 송신 링 버퍼. 0이면 Serial.write가 UART FIFO(128 B)가 빌 때까지 막혀 제어 태스크가 멈춘다.
#define HOST_TX_BUFFER_BYTES   1024
#define HOST_LINE_MAX          256     // 한 줄 최대 바이트(넘으면 그 줄은 버린다)
#define JSON_POOL_BYTES        6144    // ArduinoJson 고정 풀(힙 미사용)
// 워치독: 출력이 켜져 있는 동안(동작 중이든, IDLE_POLICY_HOLD로 정지 유지 중이든) 호스트 줄이 이 시간
// 동안 하나도 없으면 멈춘다. 동작 중이면 제동 후 STBY LOW + host_timeout 알람(Z 후퇴 없이 즉시 끊는 부류),
// 유지 중이면 알람 없이 출력만 내린다. 받은 줄이면 무엇이든(ping·status·limits 포함) 갱신한다.
// 호스트(serial_motion.py)는 동작 응답을 기다리는 동안 HOST_HEARTBEAT_MS마다 ping을 보낸다.
// HOST_HEARTBEAT_MS는 호스트 SIMPLELAY_MOTION_HEARTBEAT_MS(기본 500)와 같게 둔다.
// TODO(HW 실측): USB 시리얼 지연·RPi4 부하에서 ping 간격이 얼마나 벌어지는지 재고 정한다.
#define HOST_HEARTBEAT_MS      500
#define HOST_WATCHDOG_MS       2000
// 부팅 배너 {"event":"ready",...}의 펌웨어 이름. 호스트는 이것(또는 status 재시도)으로 준비를 안다.
#define FW_NAME                "firmware-motion"

// ─── 제어 주기·태스크 ────────────────────────────────────────────────────────
// 제어는 esp_timer가 CONTROL_HZ로 깨우는 전용 태스크에서 돈다(JSON 해석은 loop 태스크, 더 낮은 우선순위).
// TODO(HW 실측): 엔코더 최대 속도·PID 안정성 보고 정한다.
#define CONTROL_HZ             1000
#define CONTROL_PERIOD_US      (1000000 / CONTROL_HZ)
#define CONTROL_TASK_PRIORITY  5       // loop(1)보다 높게. esp_timer 태스크(22)보다 낮게
#define CONTROL_TASK_CORE      1
#define CONTROL_TASK_STACK     4096
// MCU 태스크 워치독(esp_task_wdt): loop·제어 태스크가 이 시간 동안 돌지 않으면 패닉 → 재부팅.
// 재부팅하면 GPIO가 입력(High-Z)이 되므로 STBY 핀에 외부 풀다운이 있어야 출력이 꺼진 채 남는다.
// TODO(HW 실측): 최악 loop 시간(긴 줄 해석·시리얼 쓰기) 재고, 그 몇 배로 둔다.
#define MCU_TASK_WDT_MS        1000

// ─── 정지 유지 정책(동작이 끝난 뒤) ──────────────────────────────────────────
// IDLE_POLICY_RELEASE(기본): 짧게 제동(IDLE_RELEASE_BRAKE_MS) 뒤 STBY LOW. 엔코더는 계속 센다.
// IDLE_POLICY_HOLD: PID로 위치 유지(출력 켜 둠). 호스트가 조용해지면 HOST_WATCHDOG_MS 뒤 출력을 내린다.
// TODO(HW 실측): 벨트·Z 기구가 전원 없이 밀리는지 보고 고른다.
#define IDLE_POLICY_RELEASE    0
#define IDLE_POLICY_HOLD       1
#define IDLE_POLICY            IDLE_POLICY_RELEASE
#define IDLE_RELEASE_BRAKE_MS  30

// ─── PWM(LEDC) ──────────────────────────────────────────────────────────────
// TODO(HW 실측): TB6612 상한 100 kHz 안에서 소음·발열 보고 정한다.
#define PWM_FREQ_HZ            20000
#define PWM_RES_BITS           10
#define PWM_MAX_DUTY           ((1 << PWM_RES_BITS) - 1)
// TODO(HW 실측): 공급 전압(FIT0482 정격 6 V)에 맞춘 듀티 상한. 12 V 공급에 50%를 6 V 대용으로 쓰지 않는다.
#define PWM_LIMIT_XY           700
#define PWM_LIMIT_Z            600
// TODO(HW 실측): 모터가 실제로 돌기 시작하는 최소 듀티(마찰 보상). 허용 오차 안에서는 쓰지 않는다.
#define PWM_MIN_EFFECTIVE      60

// ─── 엔코더(PCNT, x4 디코딩) ─────────────────────────────────────────────────
// 카운트는 A/B 두 채널의 모든 엣지를 센다(x4). 호스트 SIMPLELAY_MOTION_DECODING_MULTIPLIER=4,
// SIMPLELAY_MOTION_R_OUT은 이 x4 카운트 기준 실측값을 넣는다. 핀·부호는 board_config.h.
// TODO(HW 실측): 최고 속도 엣지 간격보다 짧게(최대 약 12,700 ns).
#define ENC_GLITCH_NS          1000

// ─── 리밋 스위치 ─────────────────────────────────────────────────────────────
// 핀·활성 레벨·풀업은 board_config.h.
#define LIMIT_DEBOUNCE_TICKS   3       // 연속 같은 값 샘플 수(제어 주기 단위)

// ─── 위치 PID(듀티/카운트) + 속도 피드포워드 ─────────────────────────────────
// TODO(HW 실측): 전부 튜닝 전 자리표시자. 무부하 → 벨트 장착 순으로 잡는다.
// 출력 = KP·오차 + 적분 + KFF·기준속도 − KD·측정속도(필터) ± 마찰 보상(PWM_MIN_EFFECTIVE).
// 적분은 작게 두고, 출력이 포화된 쪽으로는 더 쌓지 않는다(anti-windup) + I_LIMIT로 자른다.
#define PID_XY_KP              2.0f
#define PID_XY_KI              0.5f    // 작게 — 정지 마찰로 남는 오차만 천천히 민다
#define PID_XY_KD              0.02f   // 측정 속도(카운트/초, VEL_WINDOW_TICKS 창 + 저역 필터)에 곱한다
#define PID_XY_KFF             0.05f   // 기준 속도(카운트/초)에 곱한다
#define PID_XY_I_LIMIT         150.0f
#define PID_Z_KP               2.0f
#define PID_Z_KI               0.5f
#define PID_Z_KD               0.02f
#define PID_Z_KFF              0.05f
#define PID_Z_I_LIMIT          150.0f
// 속도 추정: VEL_WINDOW_TICKS 제어 주기 동안의 위치 차 / 시간, 그 뒤 1차 저역 필터(계수 0~1, 클수록 빠름).
#define VEL_WINDOW_TICKS       8
#define VEL_FILTER_ALPHA       0.3f
// 도착·유지 데드밴드: 궤적이 끝난 축은 허용 오차 안이면 출력 0(마찰 보상 킥 없음). 한 번 들어오면
// POS_REENGAGE_COUNTS를 넘을 때까지 다시 밀지 않는다(히스테리시스 — 한계 순환 방지).
#define POS_TOLERANCE_COUNTS   4
#define POS_REENGAGE_COUNTS    8
// 도착 = 궤적 끝 + 마스크 축이 허용 오차 안에 이 시간 연속으로 머묾.
#define ARRIVE_DWELL_MS        50

// ─── 속도·가속(카운트/초, 카운트/초²) — 사다리꼴 궤적 ─────────────────────────
// A/B는 한 시간 매개변수를 공유한다(이동량이 큰 모터 기준으로 두 모터가 같은 비율로 진행).
// 한 축이라도 추종 오차가 FOLLOW_ERR_HOLD_COUNTS를 넘으면 그 주기에는 궤적 시간을 멈춰 기다린다.
// TODO(HW 실측): 공식 무부하 310 rpm은 상한일 뿐. 부하 상태 속도·가속 실측 뒤 정한다.
#define MOVE_SPEED_CPS         2000.0f // 이동량이 큰 모터 기준
#define MOVE_ACCEL_CPS2        8000.0f
#define Z_SPEED_CPS            1000.0f
#define Z_ACCEL_CPS2           8000.0f
#define FOLLOW_ERR_HOLD_COUNTS 80
// 이동·누름 명령 기한 = 궤적 예상 시간 + 이 여유(상한 MOVE_MAX_MS·PRESS_MAX_MS).
#define MOVE_TIMEOUT_MARGIN_MS 1500

// ─── 원점 복귀(개루프 듀티 프로파일) ─────────────────────────────────────────
// 순서: Z(위로) → X → Y. 각 축: 빠른 접근 → 스위치 해제까지 후퇴 → 저속 재접근 → BACKOFF만큼 후퇴한 곳을 0.
// PID를 쓰지 않고 정해진 듀티를 직접 준다(벨트 부하에서도 기동 듀티를 넘도록). XY는 두 모터를 함께 돌리며
// 이동량 차이를 HOME_SYNC_GAIN으로 작게 보정한다(±HOME_SYNC_MAX_DUTY).
// 원점 방향 부호(HOME_*_DIR_*)는 board_config.h.
// TODO(HW 실측): 벨트 장착 상태의 기동 듀티보다 확실히 크게. 너무 크면 스위치를 세게 친다.
#define HOME_DUTY_FAST         350
#define HOME_DUTY_SLOW         250
#define HOME_SYNC_GAIN         0.5f    // 듀티/카운트
#define HOME_SYNC_MAX_DUTY     80
// 스톨: 듀티를 주는데 HOME_STALL_MS 동안 카운트 변화가 STALL_MIN_DELTA_COUNTS 미만이면 stall 알람.
// (스위치가 고장 나 끝에 닿은 경우도 여기서 멈춘다 — 20 s 기한까지 벽을 밀지 않는다.)
#define HOME_STALL_MS          250
// TODO(HW 실측): 스위치 해제 여유. 축별 최대 탐색 거리(HOME_*_MAX_TRAVEL_COUNTS)는 board_config.h.
#define HOME_BACKOFF_COUNTS    200
#define HOME_RELEASE_FACTOR    4       // 후퇴·재접근 탐색 한도 = BACKOFF × 이 값
// 단계별 시간 예산 = 그 단계 최대 이동 카운트 / 최저 허용 속도 + 여유. 넘으면 home_not_found.
// TODO(HW 실측): HOME_DUTY_* 에서 잰 실제 속도의 절반쯤으로.
#define HOME_FAST_MIN_CPS      1000.0f
#define HOME_SLOW_MIN_CPS      500.0f
#define HOME_PHASE_MARGIN_MS   1000
#define HOME_SETTLE_MS         100     // 마지막 후퇴 뒤 제동하고 기다렸다가 0으로 잡는다

// 소프트 리밋(A/B 카운트·X/Y mm)은 board_config.h.

// ─── Z 누름 ──────────────────────────────────────────────────────────────────
// TODO(HW 실측): 버튼 스트로크·Z 기구 확정 뒤. 최대 깊이(Z_PRESS_MAX_COUNTS)·솔레노이드 시간은 board_config.h.
#define PRESS_DRIVE_MAX_MS     500     // duration 방식 구동 시간 상한(호스트 press_drive_max_ms 이하)
#define PRESS_DRIVE_PWM        400     // duration 방식 구동 듀티
#define PRESS_DWELL_MAX_MS     3000

// ─── 알람 때 Z 후퇴 ──────────────────────────────────────────────────────────
// 알람 때 Z가 후퇴 위치(0) 아래(Z_RETRACT_ZONE_COUNTS 초과)에 있으면 XY는 제동하고 Z만 위쪽으로
// 개루프 구동한다: Z_RETRACT_MS 동안, 또는 Z가 Z_RETRACT_DONE_COUNTS 이하·Z 리밋 활성·스톨까지.
// 그 뒤 제동 → STBY LOW. host_timeout(워치독) 부류는 후퇴 없이 즉시 끊는다. 결과는 alarm 이벤트의
// z_retract 필드: not_needed | done | timeout | stalled | skipped | stopped.
// TODO(HW 실측): Z 기구가 전원 없이 스스로 올라오는지(스프링)·후퇴 속도.
#define Z_RETRACT_DUTY         400
#define Z_RETRACT_MS           400
#define Z_RETRACT_ZONE_COUNTS  5
#define Z_RETRACT_DONE_COUNTS  2

// ─── 명령 기한(MCU 자체) ─────────────────────────────────────────────────────
// TODO(HW 실측): 호스트 *_TIMEOUT_S보다 짧게 잡아 MCU가 먼저 실패를 보고하게 한다.
// HOME_MAX_MS는 단계별 예산 합보다 커야 한다(motion.cpp static_assert). 호스트 home_timeout_s는 이보다 길게.
#define HOME_MAX_MS            60000
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
#if HOME_DUTY_FAST + HOME_SYNC_MAX_DUTY > PWM_LIMIT_XY || HOME_DUTY_FAST > PWM_LIMIT_Z || Z_RETRACT_DUTY > PWM_LIMIT_Z
#error "원점·후퇴 듀티가 축 PWM 상한보다 크다"
#endif
#if HOME_DUTY_SLOW <= PWM_MIN_EFFECTIVE
#error "HOME_DUTY_SLOW는 PWM_MIN_EFFECTIVE보다 커야 한다(기동 못 하는 듀티로 원점을 찾지 않는다)"
#endif
#if HOST_WATCHDOG_MS < 3 * HOST_HEARTBEAT_MS
#error "HOST_WATCHDOG_MS는 HOST_HEARTBEAT_MS의 3배 이상이어야 한다 — ping 한두 개 늦음으로 정상 동작이 끊기지 않게"
#endif
#if POS_REENGAGE_COUNTS < POS_TOLERANCE_COUNTS
#error "POS_REENGAGE_COUNTS는 POS_TOLERANCE_COUNTS 이상이어야 한다"
#endif
#if (1000000 % CONTROL_HZ) != 0
#error "CONTROL_HZ는 1 s를 정수 us로 나누는 값이어야 한다"
#endif
#if Z_MODE == Z_MODE_SOLENOID && SOLENOID_ON_MAX_MS + SOLENOID_RELEASE_MS + MOVE_TIMEOUT_MARGIN_MS > PRESS_MAX_MS
#error "솔레노이드 최장 누름(켜짐 상한 + 복귀 + 여유)이 PRESS_MAX_MS보다 길다"
#endif
#if Z_MODE == Z_MODE_SOLENOID && (SOLENOID_MIN_OFF_MS <= 0 || SOLENOID_OFF_RATIO < 1)
#error "솔레노이드 냉각(SOLENOID_MIN_OFF_MS > 0, SOLENOID_OFF_RATIO >= 1)이 필요하다 — 코일 발열 보호"
#endif
#if IDLE_POLICY != IDLE_POLICY_RELEASE && IDLE_POLICY != IDLE_POLICY_HOLD
#error "IDLE_POLICY는 IDLE_POLICY_RELEASE 또는 IDLE_POLICY_HOLD"
#endif
