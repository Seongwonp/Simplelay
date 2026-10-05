#include "motion.h"

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <math.h>

#include "config.h"
#include "drivers.h"

// 응답 순서 규칙(호스트 serial_motion.py의 처리 순서 때문에 중요):
//   알람은 `{"event":"alarm"}`을 **먼저**, 대기 중 명령의 `ok:false` 응답을 **나중에** 보낸다.
//   호스트는 이벤트를 받는 즉시 그 요청을 실패로 끝내고 늦은 응답은 id 불일치로 버린다.
//   순서가 반대면 알람 이벤트가 다음 요청(예: 복구용 home)을 실패시킨다.
//   Z 후퇴가 필요한 알람은 후퇴가 끝난 뒤(최대 Z_RETRACT_MS) 이벤트와 실패 응답을 보낸다.
//
// 2026-09-29 첫날 위험 보완: 원점 복귀는 개루프 듀티 + 스톨 판정 + 단계별 시간 예산, 이동은 A/B가 한
// 시간 매개변수를 공유하는 사다리꼴 궤적 + 작은 적분(anti-windup) + 필터 속도 미분 + 데드밴드 히스테리시스,
// 동작 뒤 정지 유지 정책(IDLE_POLICY), 알람 때 Z 후퇴. 전부 실물 미검증, 값은 config.h 자리표시자.
//
// 2026-10-05 Z 누름 방식 빌드 플래그(board_config.h Z_MODE): Z_MODE_SOLENOID면 Z 원점 단계가 없고,
// 누름은 duration만(켜짐 = drive_ms + dwell_ms, 상한 SOLENOID_ON_MAX_MS, 끈 뒤 냉각 시간 안이면 z_cooldown,
// depth는 z_unsupported), 알람·정지·워치독은 솔레노이드를 즉시 끈다(z_retract = done|not_needed).
// 제어 주기마다 켜짐 시간이 SOLENOID_ON_MAX_MS를 넘었는지 따로 본다(어떤 경로로 켜져 있든 끈다).

namespace {

enum class State : uint8_t { Idle, Homing, Moving, Pressing, Stopped, Alarm };

const char* state_name(State s) {
  switch (s) {
    case State::Idle: return "idle";
    case State::Homing: return "homing";
    case State::Moving: return "moving";
    case State::Pressing: return "pressing";
    case State::Stopped: return "stopped";
    case State::Alarm: return "alarm";
  }
  return "alarm";
}

constexpr float kDt = 1.0f / static_cast<float>(CONTROL_HZ);
constexpr uint8_t kMaskAB = (1u << AXIS_A) | (1u << AXIS_B);
constexpr uint8_t kMaskZ = (1u << AXIS_Z);

struct PidGains {
  float kp, ki, kd, kff, i_limit;
  int32_t out_limit;
};

const PidGains kGains[AXIS_COUNT] = {
    {PID_XY_KP, PID_XY_KI, PID_XY_KD, PID_XY_KFF, PID_XY_I_LIMIT, PWM_LIMIT_XY},
    {PID_XY_KP, PID_XY_KI, PID_XY_KD, PID_XY_KFF, PID_XY_I_LIMIT, PWM_LIMIT_XY},
    {PID_Z_KP, PID_Z_KI, PID_Z_KD, PID_Z_KFF, PID_Z_I_LIMIT, PWM_LIMIT_Z},
};

struct AxisCtl {
  int32_t pos;
  int32_t hist[VEL_WINDOW_TICKS];  // 속도 창(가장 오래된 값 = hist[hist_idx])
  uint8_t hist_idx;
  float vel;      // 측정 속도(카운트/초, 필터)
  float target;   // 위치 목표(카운트)
  float ref_vel;  // 궤적 기준 속도(카운트/초) — 피드포워드
  float integ;
  bool in_band;   // 데드밴드 안(히스테리시스)
  int32_t duty;
  bool open_loop;  // 원점 복귀·duration 누름·Z 후퇴: 듀티 직접 지정
  int32_t open_duty;
  bool brake;      // short brake 유지
  bool stall_check;
  bool stall_timing;
  int32_t stall_ref;
  uint32_t stall_since;
};

// 사다리꼴 궤적. 마스크 축은 한 시간 매개변수 t를 공유한다: s(t)는 이동량이 가장 큰 축 기준 거리,
// 각 축 목표 = start + delta · s/L. 추종 오차가 크면 t를 멈춰 두 축이 같은 비율로 진행하게 한다.
struct Trajectory {
  bool active;
  uint8_t mask;
  float start[AXIS_COUNT];
  float delta[AXIS_COUNT];
  float length;
  float accel;
  float vpeak;
  float t_acc;
  float t_cruise;
  float t_total;
  float t;
};

enum class HomePhase : uint8_t { FastApproach, Backoff, SlowApproach, FinalBackoff, Settle };

struct HomeGroup {
  LimitId limit;
  int8_t dir[AXIS_COUNT];  // 스위치 쪽 방향, 0 = 이 단계에서 움직이지 않음
  int32_t max_travel;
};

// 순서: Z 후퇴 → X → Y (솔레노이드 방식은 Z 단계 없음 — 꺼져 있으면 스프링이 올려 둔다)
const HomeGroup kHomeGroups[] = {
#if Z_MODE == Z_MODE_MOTOR
    {LIMIT_Z, {0, 0, HOME_Z_DIR}, HOME_Z_MAX_TRAVEL_COUNTS},
#endif
    {LIMIT_X, {HOME_X_DIR_A, HOME_X_DIR_B, 0}, HOME_XY_MAX_TRAVEL_COUNTS},
    {LIMIT_Y, {HOME_Y_DIR_A, HOME_Y_DIR_B, 0}, HOME_XY_MAX_TRAVEL_COUNTS},
};
constexpr uint8_t kHomeGroupCount = sizeof(kHomeGroups) / sizeof(kHomeGroups[0]);

constexpr uint32_t kShortTravel = HOME_BACKOFF_COUNTS * HOME_RELEASE_FACTOR;
constexpr uint32_t phase_budget_ms(uint32_t counts, float min_cps) {
  return static_cast<uint32_t>(static_cast<float>(counts) / min_cps * 1000.0f) + HOME_PHASE_MARGIN_MS;
}
constexpr uint32_t group_budget_ms(uint32_t max_travel) {
  return phase_budget_ms(max_travel, HOME_FAST_MIN_CPS) + 3 * phase_budget_ms(kShortTravel, HOME_SLOW_MIN_CPS) +
         HOME_SETTLE_MS + HOME_PHASE_MARGIN_MS;
}
constexpr uint32_t kHomeZBudget = (Z_MODE == Z_MODE_MOTOR) ? group_budget_ms(HOME_Z_MAX_TRAVEL_COUNTS) : 0;
static_assert(kHomeZBudget + 2 * group_budget_ms(HOME_XY_MAX_TRAVEL_COUNTS) <= HOME_MAX_MS,
              "HOME_MAX_MS가 원점 복귀 단계별 예산의 합보다 작다");

struct HomeCtx {
  uint8_t group;
  HomePhase phase;
  int32_t phase_start[AXIS_COUNT];
  uint32_t phase_t0;
  uint32_t budget_ms;
  int32_t travel_limit;
};

// SolenoidOn·SolenoidRelease는 Z_MODE_SOLENOID에서만 쓴다.
enum class PressPhase : uint8_t { Down, DownOpen, Dwell, Up, SolenoidOn, SolenoidRelease };

struct PressCtx {
  PressPhase phase;
  bool depth;
  int32_t amount;
  uint32_t dwell_ms;
  uint32_t t0;
};

struct RetractCtx {
  bool active;
  uint32_t t0;
};

StaticSemaphore_t g_lock_buf;
SemaphoreHandle_t g_lock = nullptr;

AxisCtl g_ax[AXIS_COUNT];
Trajectory g_traj;
HomeCtx g_home;
PressCtx g_press;
RetractCtx g_retract;

State g_state = State::Idle;
bool g_homed = false;
bool g_hw_ok = false;
bool g_outputs_on = false;
bool g_braking = false;
uint32_t g_brake_until = 0;
const char* g_alarm = nullptr;

bool g_has_pending = false;
ReqId g_pending = {false, 0};
uint32_t g_cmd_start = 0;
uint32_t g_cmd_max_ms = 0;
volatile uint32_t g_last_host = 0;  // loop 태스크가 잠금 없이 쓴다(32비트 한 번 쓰기)
uint32_t g_now = 0;
uint32_t g_last_position_event = 0;

bool g_settling = false;
uint32_t g_settle_since = 0;

// ── 솔레노이드(Z_MODE_SOLENOID) ───────────────────────────────────────────────
// 시각은 millis()로 직접 잰다 — 정지 명령(loop 태스크)에서도 불리고 g_now는 제어 주기에서만 갱신된다.
// 모터 방식 빌드에서는 sol_off()만 남고 늘 false다(끌 솔레노이드가 없다).
#if Z_MODE == Z_MODE_SOLENOID
uint32_t g_sol_on_at = 0;
uint32_t g_sol_off_at = 0;
uint32_t g_sol_cooldown_ms = 0;  // 다음에 켤 수 있을 때까지 최소 꺼짐 시간

void sol_on() {
  g_sol_on_at = millis();
  solenoid_set(true);
}

// 끈다. 켜져 있었으면 냉각 시간 = max(SOLENOID_MIN_OFF_MS, 켜짐 시간 × SOLENOID_OFF_RATIO)을 잡고 true.
bool sol_off() {
  if (!solenoid_is_on()) return false;
  solenoid_set(false);
  const uint32_t now = millis();
  const uint32_t by_ratio = (now - g_sol_on_at) * SOLENOID_OFF_RATIO;
  g_sol_off_at = now;
  g_sol_cooldown_ms = by_ratio > SOLENOID_MIN_OFF_MS ? by_ratio : SOLENOID_MIN_OFF_MS;
  return true;
}

// 정상 누름(켜짐 ≤ SOLENOID_ON_MAX_MS)이 백스톱과 같은 주기에 겹치지 않게 두는 여유(제어 주기 몇 번).
constexpr int32_t kSolBackstopGraceMs = 20;

bool sol_cooling() {
  return g_sol_cooldown_ms > 0 &&
         static_cast<int32_t>(millis() - g_sol_off_at) < static_cast<int32_t>(g_sol_cooldown_ms);
}
#else
bool sol_off() { return false; }
#endif

// status·position의 z: 모터 방식은 Z 엔코더 카운트, 솔레노이드 방식은 켜짐 1 / 꺼짐 0.
int32_t z_report();

bool busy() { return g_state == State::Homing || g_state == State::Moving || g_state == State::Pressing; }

int32_t iabs(int32_t v) { return v < 0 ? -v : v; }

// 두 시각의 차를 부호 있게(다른 태스크가 쓴 시각이 g_now보다 늦을 수 있다).
int32_t since(uint32_t t) { return static_cast<int32_t>(g_now - t); }

void vel_reset(AxisCtl& ax) {
  for (uint8_t k = 0; k < VEL_WINDOW_TICKS; ++k) ax.hist[k] = ax.pos;
  ax.hist_idx = 0;
  ax.vel = 0.0f;
}

void vel_update(AxisCtl& ax) {
  const int32_t oldest = ax.hist[ax.hist_idx];
  ax.hist[ax.hist_idx] = ax.pos;
  ax.hist_idx = static_cast<uint8_t>((ax.hist_idx + 1) % VEL_WINDOW_TICKS);
  const float raw = static_cast<float>(ax.pos - oldest) / (VEL_WINDOW_TICKS * kDt);
  ax.vel += VEL_FILTER_ALPHA * (raw - ax.vel);
}

void stall_reset(AxisCtl& ax) { ax.stall_timing = false; }

void reset_axis_control(uint8_t i) {
  AxisCtl& ax = g_ax[i];
  ax.target = static_cast<float>(ax.pos);
  ax.ref_vel = 0.0f;
  ax.integ = 0.0f;
  ax.in_band = false;
  ax.open_loop = false;
  ax.open_duty = 0;
  ax.brake = false;
  ax.stall_check = true;
  stall_reset(ax);
}

void enable_outputs() {
  g_braking = false;
  if (g_outputs_on) return;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    reset_axis_control(i);
    motor_set_duty(static_cast<Axis>(i), 0);
  }
  drivers_standby_outputs(true);
  g_outputs_on = true;
}

// 즉시: 듀티 0, STBY LOW(출력 High-Z), 솔레노이드 끔. 정지 명령 경로.
void cut_outputs_now() {
  sol_off();
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    motor_set_duty(static_cast<Axis>(i), 0);
    g_ax[i].duty = 0;
    g_ax[i].ref_vel = 0.0f;
  }
  drivers_standby_outputs(false);
  g_outputs_on = false;
  g_braking = false;
  g_traj.active = false;
}

// short brake brake_ms 뒤 STBY LOW. 알람·워치독·정지 유지 해제 경로.
void brake_then_standby(uint32_t brake_ms) {
  sol_off();  // 솔레노이드는 제동할 것이 없다 — 바로 끈다
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    motor_brake(static_cast<Axis>(i));
    g_ax[i].duty = 0;
    g_ax[i].ref_vel = 0.0f;
  }
  g_outputs_on = false;
  g_braking = true;
  g_brake_until = g_now + brake_ms;
  g_traj.active = false;
}

void begin_command(const ReqId& id, State state, uint32_t max_ms) {
  g_has_pending = true;
  g_pending = id;
  g_state = state;
  g_cmd_start = g_now;
  g_cmd_max_ms = max_ms;
  g_settling = false;
}

void emit_position() {
  g_last_position_event = g_now;
  proto_event_position(g_ax[AXIS_A].pos, g_ax[AXIS_B].pos, z_report());
}

int32_t z_report() {
#if Z_MODE == Z_MODE_SOLENOID
  return solenoid_is_on() ? 1 : 0;
#else
  return g_ax[AXIS_Z].pos;
#endif
}

// 동작이 끝난 뒤 출력 정책. RELEASE: 짧게 제동 → STBY LOW(엔코더는 계속 센다). HOLD: PID 유지.
void apply_idle_policy() {
#if IDLE_POLICY == IDLE_POLICY_RELEASE
  brake_then_standby(IDLE_RELEASE_BRAKE_MS);
#else
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    g_ax[i].open_loop = false;
    g_ax[i].ref_vel = 0.0f;
  }
#endif
}

void finish_ok() {
  // 이동·누름이 끝난 위치를 ok 응답보다 먼저 보낸다(호스트는 이벤트를 먼저 처리한다).
  if (g_state == State::Moving || g_state == State::Pressing) emit_position();
  g_state = State::Idle;
  g_traj.active = false;
  apply_idle_policy();
  if (g_has_pending) {
    g_has_pending = false;
    proto_reply_ok(g_pending);
  }
}

void report_alarm(const char* z_retract) {
  proto_event_alarm(g_alarm, z_retract);  // 이벤트 먼저
  if (g_has_pending) {
    g_has_pending = false;
    proto_reply_error(g_pending, g_alarm);
  }
}

// 알람. cut_now=true(워치독 부류)는 Z 후퇴 없이 즉시 제동·차단한다. 그 밖에는 Z가 눌린 쪽에 있으면
// XY는 제동하고 Z만 위로 개루프 후퇴(한도 Z_RETRACT_MS)한 뒤 차단하고, 그때 이벤트·실패 응답을 보낸다.
void fault(const char* reason, bool cut_now = false) {
#if Z_MODE == Z_MODE_SOLENOID
  // 솔레노이드는 전원을 끊는 것이 후퇴다(스프링 복귀) — 워치독 부류든 아니든 즉시 끄고 바로 보고한다.
  (void)cut_now;
  g_state = State::Alarm;
  g_alarm = reason;
  g_homed = false;
  g_traj.active = false;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) g_ax[i].ref_vel = 0.0f;
  const bool was_on = sol_off();
  brake_then_standby(FAULT_BRAKE_MS);
  report_alarm(was_on ? "done" : "not_needed");
#else
  const bool had_position = g_homed;  // 홈 전이면 Z 위치(카운트)를 믿을 수 없다
  g_state = State::Alarm;
  g_alarm = reason;
  g_homed = false;  // 위치 기준을 믿지 않는다 — home으로 복구
  g_traj.active = false;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) g_ax[i].ref_vel = 0.0f;

  const bool z_pressed = g_ax[AXIS_Z].pos > Z_RETRACT_ZONE_COUNTS && !limit_active(LIMIT_Z);
  if (!had_position) {  // Z가 눌렸는지 알 수 없다 — 후퇴를 시도하지 않는다
    brake_then_standby(FAULT_BRAKE_MS);
    report_alarm("skipped");
    return;
  }
  if (!z_pressed) {
    brake_then_standby(FAULT_BRAKE_MS);
    report_alarm("not_needed");
    return;
  }
  if (cut_now || !g_outputs_on) {
    brake_then_standby(FAULT_BRAKE_MS);
    report_alarm("skipped");
    return;
  }
  g_braking = false;
  g_ax[AXIS_A].brake = true;
  g_ax[AXIS_B].brake = true;
  AxisCtl& z = g_ax[AXIS_Z];
  z.brake = false;
  z.open_loop = true;
  z.open_duty = HOME_Z_DIR * Z_RETRACT_DUTY;  // 원점(위) 쪽 = 후퇴
  stall_reset(z);
  g_retract.active = true;
  g_retract.t0 = g_now;
#endif
}

bool stall_step(uint8_t i, int32_t min_pwm, uint32_t timeout_ms);

void retract_tick() {
  const AxisCtl& z = g_ax[AXIS_Z];
  const char* result = nullptr;
  if (z.pos <= Z_RETRACT_DONE_COUNTS || limit_active(LIMIT_Z)) {
    result = "done";
  } else if (since(g_retract.t0) >= static_cast<int32_t>(Z_RETRACT_MS)) {
    result = "timeout";
  } else if (stall_step(AXIS_Z, 1, HOME_STALL_MS)) {
    result = "stalled";
  }
  if (result == nullptr) return;
  g_retract.active = false;
  brake_then_standby(FAULT_BRAKE_MS);
  report_alarm(result);
}

// ── 궤적 ─────────────────────────────────────────────────────────────────────

float profile_seconds(float length, float vmax, float accel) {
  if (length <= 0.0f) return 0.0f;
  const float t_acc = vmax / accel;
  const float d_acc = 0.5f * accel * t_acc * t_acc;
  if (2.0f * d_acc >= length) return 2.0f * sqrtf(length / accel);
  return 2.0f * t_acc + (length - 2.0f * d_acc) / vmax;
}

uint32_t profile_ms(float length, float vmax, float accel) {
  return static_cast<uint32_t>(profile_seconds(length, vmax, accel) * 1000.0f) + 1;
}

void traj_start(uint8_t mask, const float* end, float vmax, float accel) {
  float length = 0.0f;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    g_traj.start[i] = g_ax[i].target;
    g_traj.delta[i] = (mask & (1u << i)) ? end[i] - g_ax[i].target : 0.0f;
    const float d = fabsf(g_traj.delta[i]);
    if (d > length) length = d;
  }
  g_traj.length = length;
  g_traj.accel = accel;
  const float t_acc = vmax / accel;
  const float d_acc = 0.5f * accel * t_acc * t_acc;
  if (2.0f * d_acc >= length) {  // 삼각형: 최고 속도에 닿기 전에 감속
    g_traj.t_acc = sqrtf(length / accel);
    g_traj.vpeak = accel * g_traj.t_acc;
    g_traj.t_cruise = 0.0f;
  } else {
    g_traj.t_acc = t_acc;
    g_traj.vpeak = vmax;
    g_traj.t_cruise = (length - 2.0f * d_acc) / vmax;
  }
  g_traj.t_total = 2.0f * g_traj.t_acc + g_traj.t_cruise;
  g_traj.t = 0.0f;
  g_traj.mask = mask;
  g_traj.active = true;
  g_settling = false;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (mask & (1u << i)) g_ax[i].in_band = false;
  }
}

// s(t): 거리, sv: 속도(이동량이 가장 큰 축 기준).
void traj_eval(float t, float* s, float* sv) {
  const Trajectory& tr = g_traj;
  if (t <= 0.0f) {
    *s = 0.0f;
    *sv = 0.0f;
  } else if (t < tr.t_acc) {
    *s = 0.5f * tr.accel * t * t;
    *sv = tr.accel * t;
  } else if (t < tr.t_acc + tr.t_cruise) {
    *s = 0.5f * tr.accel * tr.t_acc * tr.t_acc + tr.vpeak * (t - tr.t_acc);
    *sv = tr.vpeak;
  } else if (t < tr.t_total) {
    const float td = tr.t_total - t;
    *s = tr.length - 0.5f * tr.accel * td * td;
    *sv = tr.accel * td;
  } else {
    *s = tr.length;
    *sv = 0.0f;
  }
}

void traj_update() {
  if (!g_traj.active) return;
  bool hold = false;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if ((g_traj.mask & (1u << i)) && fabsf(g_ax[i].target - static_cast<float>(g_ax[i].pos)) > FOLLOW_ERR_HOLD_COUNTS) {
      hold = true;  // 한 축이 뒤처졌다 — 시간을 멈춰 다른 축도 기다리게 한다(경로 모양 유지)
    }
  }
  if (!hold) g_traj.t += kDt;
  if (g_traj.t >= g_traj.t_total) {
    g_traj.t = g_traj.t_total;
    g_traj.active = false;
  }
  float s = 0.0f;
  float sv = 0.0f;
  traj_eval(g_traj.t, &s, &sv);
  if (hold || !g_traj.active) sv = 0.0f;
  const float frac = g_traj.length > 0.0f ? s / g_traj.length : 1.0f;
  const float vscale = g_traj.length > 0.0f ? sv / g_traj.length : 0.0f;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (!(g_traj.mask & (1u << i))) continue;
    g_ax[i].target = g_traj.start[i] + g_traj.delta[i] * frac;
    g_ax[i].ref_vel = g_traj.delta[i] * vscale;
  }
}

// 궤적이 끝났고, 마스크 축이 허용 오차 안에 ARRIVE_DWELL_MS 동안 연속으로 머물렀는가.
bool traj_arrived(uint8_t mask) {
  if (g_traj.active) return false;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (!(mask & (1u << i))) continue;
    if (fabsf(g_ax[i].target - static_cast<float>(g_ax[i].pos)) > POS_TOLERANCE_COUNTS) {
      g_settling = false;
      return false;
    }
  }
  if (!g_settling) {
    g_settling = true;
    g_settle_since = g_now;
    return false;
  }
  return since(g_settle_since) >= static_cast<int32_t>(ARRIVE_DWELL_MS);
}

// ── 원점 복귀(개루프) ────────────────────────────────────────────────────────

bool in_group(const HomeGroup& g, uint8_t i) { return g.dir[i] != 0; }

// 그룹 시작: 그룹 축은 개루프, 나머지 축은 지금 위치를 PID로 유지.
void home_start_group() {
  const HomeGroup& g = kHomeGroups[g_home.group];
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    AxisCtl& ax = g_ax[i];
    reset_axis_control(i);
    ax.open_loop = in_group(g, i);
  }
}

void home_enter_phase(HomePhase phase) {
  const HomeGroup& g = kHomeGroups[g_home.group];
  g_home.phase = phase;
  g_home.phase_t0 = g_now;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    g_home.phase_start[i] = g_ax[i].pos;
    if (!in_group(g, i)) continue;
    g_ax[i].open_duty = 0;
    g_ax[i].brake = (phase == HomePhase::Settle);
    stall_reset(g_ax[i]);
  }
  switch (phase) {
    case HomePhase::FastApproach:
      g_home.travel_limit = g.max_travel;
      g_home.budget_ms = phase_budget_ms(static_cast<uint32_t>(g.max_travel), HOME_FAST_MIN_CPS);
      break;
    case HomePhase::Backoff:
    case HomePhase::SlowApproach:
    case HomePhase::FinalBackoff:
      g_home.travel_limit = static_cast<int32_t>(kShortTravel);
      g_home.budget_ms = phase_budget_ms(kShortTravel, HOME_SLOW_MIN_CPS);
      break;
    case HomePhase::Settle:
      g_home.travel_limit = static_cast<int32_t>(kShortTravel);
      g_home.budget_ms = HOME_SETTLE_MS;
      break;
  }
}

int32_t home_travel(const HomeGroup& g, uint8_t i) { return iabs(g_ax[i].pos - g_home.phase_start[i]); }

int32_t home_travel_max(const HomeGroup& g) {
  int32_t travel = 0;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (!in_group(g, i)) continue;
    const int32_t d = home_travel(g, i);
    if (d > travel) travel = d;
  }
  return travel;
}

// toward=+1이면 스위치 쪽, -1이면 반대쪽. 두 모터 그룹은 이동량 차이를 작게 보정한다.
void home_drive(const HomeGroup& g, int8_t toward, int32_t base_duty) {
  int32_t sum = 0;
  uint8_t n = 0;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (!in_group(g, i)) continue;
    sum += home_travel(g, i);
    ++n;
  }
  const float mean = n > 0 ? static_cast<float>(sum) / n : 0.0f;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (!in_group(g, i)) continue;
    float corr = 0.0f;
    if (n > 1) {
      corr = HOME_SYNC_GAIN * (mean - static_cast<float>(home_travel(g, i)));
      if (corr > HOME_SYNC_MAX_DUTY) corr = HOME_SYNC_MAX_DUTY;
      if (corr < -HOME_SYNC_MAX_DUTY) corr = -HOME_SYNC_MAX_DUTY;
    }
    const int32_t mag = base_duty + static_cast<int32_t>(corr);
    g_ax[i].open_duty = g.dir[i] * toward * mag;
  }
}

void home_finish_group() {
  if (++g_home.group < kHomeGroupCount) {
    home_start_group();
    home_enter_phase(limit_active(kHomeGroups[g_home.group].limit) ? HomePhase::Backoff : HomePhase::FastApproach);
    return;
  }
  // 모든 축 완료: 지금 위치를 원점(0)으로.
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    encoder_zero(static_cast<Axis>(i));
    g_ax[i].pos = 0;
    vel_reset(g_ax[i]);
    reset_axis_control(i);
  }
  g_homed = true;
  finish_ok();
}

void home_tick() {
  const HomeGroup& g = kHomeGroups[g_home.group];
  const bool hit = limit_active(g.limit);
  const int32_t travel = home_travel_max(g);
  const bool over_budget =
      travel > g_home.travel_limit || since(g_home.phase_t0) > static_cast<int32_t>(g_home.budget_ms);

  switch (g_home.phase) {
    case HomePhase::FastApproach:
      if (hit) {
        home_enter_phase(HomePhase::Backoff);
      } else if (over_budget) {
        fault("home_not_found");
      } else {
        home_drive(g, +1, HOME_DUTY_FAST);
      }
      break;
    case HomePhase::Backoff:
      if (!hit && travel >= HOME_BACKOFF_COUNTS) {
        home_enter_phase(HomePhase::SlowApproach);
      } else if (over_budget) {
        fault("home_not_found");  // 후퇴해도 스위치가 풀리지 않는다(고착·배선)
      } else {
        home_drive(g, -1, HOME_DUTY_SLOW);
      }
      break;
    case HomePhase::SlowApproach:
      if (hit) {
        home_enter_phase(HomePhase::FinalBackoff);
      } else if (over_budget) {
        fault("home_not_found");
      } else {
        home_drive(g, +1, HOME_DUTY_SLOW);
      }
      break;
    case HomePhase::FinalBackoff:
      if (!hit && travel >= HOME_BACKOFF_COUNTS) {
        home_enter_phase(HomePhase::Settle);  // 제동하고 멈춘 뒤 0으로 잡는다
      } else if (over_budget) {
        fault("home_not_found");
      } else {
        home_drive(g, -1, HOME_DUTY_SLOW);
      }
      break;
    case HomePhase::Settle:
      if (since(g_home.phase_t0) < static_cast<int32_t>(HOME_SETTLE_MS)) break;
      if (hit) {
        fault("home_not_found");
        break;
      }
      home_finish_group();
      break;
  }
}

// ── 누름 ─────────────────────────────────────────────────────────────────────

void press_tick() {
  AxisCtl& z = g_ax[AXIS_Z];
  switch (g_press.phase) {
    case PressPhase::Down:
      if (traj_arrived(kMaskZ)) {
        g_press.phase = PressPhase::Dwell;
        g_press.t0 = g_now;
        z.stall_check = false;  // 버튼을 누른 채 버티는 동안은 스톨 판정을 끈다(시간 상한 있음)
        stall_reset(z);
      }
      break;
    case PressPhase::DownOpen:
      if (z.pos > Z_PRESS_MAX_COUNTS) {
        fault("soft_limit");
      } else if (since(g_press.t0) >= g_press.amount) {
        z.open_loop = false;
        z.target = static_cast<float>(z.pos);
        z.integ = 0.0f;
        g_press.phase = PressPhase::Dwell;
        g_press.t0 = g_now;
      }
      break;
    case PressPhase::Dwell:
      if (since(g_press.t0) >= static_cast<int32_t>(g_press.dwell_ms)) {
        z.stall_check = true;
        stall_reset(z);
        g_press.phase = PressPhase::Up;
        float end[AXIS_COUNT] = {0.0f, 0.0f, 0.0f};
        traj_start(kMaskZ, end, Z_SPEED_CPS, Z_ACCEL_CPS2);
      }
      break;
    case PressPhase::Up:
      if (traj_arrived(kMaskZ)) {
        proto_event("press_end");
        finish_ok();
      }
      break;
    case PressPhase::SolenoidOn:
      if (since(g_press.t0) >= g_press.amount) {
        sol_off();
        proto_event("press_end");
        g_press.phase = PressPhase::SolenoidRelease;
        g_press.t0 = g_now;
      }
      break;
    case PressPhase::SolenoidRelease:
      // 스프링이 플런저를 되돌릴 시간을 둔 뒤 완료 — 그 전에 XY가 움직이면 버튼을 긁는다.
      if (since(g_press.t0) >= static_cast<int32_t>(SOLENOID_RELEASE_MS)) finish_ok();
      break;
  }
}

// ── 축 제어 ──────────────────────────────────────────────────────────────────

int32_t pid_step(uint8_t i) {
  AxisCtl& ax = g_ax[i];
  const PidGains& k = kGains[i];
  const float err = ax.target - static_cast<float>(ax.pos);
  const bool tracking = g_traj.active && (g_traj.mask & (1u << i));
  if (!tracking) {
    // 데드밴드 + 히스테리시스: 허용 오차 안이면 출력 0(마찰 보상 킥 없음), 벗어나도 REENGAGE까지는 두고 본다.
    const float aerr = fabsf(err);
    if (ax.in_band) {
      if (aerr > POS_REENGAGE_COUNTS) ax.in_band = false;
    } else if (aerr <= POS_TOLERANCE_COUNTS) {
      ax.in_band = true;
    }
    if (ax.in_band) {
      ax.integ = 0.0f;
      return 0;
    }
  } else {
    ax.in_band = false;
  }
  const float p = k.kp * err;
  const float ff = k.kff * ax.ref_vel;
  const float d = -k.kd * ax.vel;
  const float unsat = p + ax.integ + ff + d;
  // anti-windup: 이미 포화된 쪽으로 오차가 더 밀면 적분하지 않는다. 그리고 I_LIMIT로 자른다.
  const bool push_hi = unsat >= static_cast<float>(k.out_limit) && err > 0.0f;
  const bool push_lo = unsat <= -static_cast<float>(k.out_limit) && err < 0.0f;
  if (!push_hi && !push_lo) {
    ax.integ += k.ki * err * kDt;
    if (ax.integ > k.i_limit) ax.integ = k.i_limit;
    if (ax.integ < -k.i_limit) ax.integ = -k.i_limit;
  }
  float out = p + ax.integ + ff + d;
  // 마찰 보상: 밀 방향이 정해졌을 때만 기동 듀티를 더한다(데드밴드 밖에서만 여기 온다).
  if (out > 0.5f) {
    out += PWM_MIN_EFFECTIVE;
  } else if (out < -0.5f) {
    out -= PWM_MIN_EFFECTIVE;
  } else {
    out = 0.0f;
  }
  if (out > k.out_limit) out = static_cast<float>(k.out_limit);
  if (out < -k.out_limit) out = -static_cast<float>(k.out_limit);
  return static_cast<int32_t>(out);
}

// true = 스톨 판정(|duty| >= min_pwm인데 timeout_ms 동안 카운트 변화가 STALL_MIN_DELTA_COUNTS 미만)
bool stall_step(uint8_t i, int32_t min_pwm, uint32_t timeout_ms) {
  AxisCtl& ax = g_ax[i];
  if (iabs(ax.duty) < min_pwm) {
    ax.stall_timing = false;
    return false;
  }
  if (!ax.stall_timing || iabs(ax.pos - ax.stall_ref) >= STALL_MIN_DELTA_COUNTS) {
    ax.stall_timing = true;
    ax.stall_ref = ax.pos;
    ax.stall_since = g_now;
    return false;
  }
  return since(ax.stall_since) >= static_cast<int32_t>(timeout_ms);
}

void drive_axes() {
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    AxisCtl& ax = g_ax[i];
    if (ax.brake) {
      ax.duty = 0;
      motor_brake(static_cast<Axis>(i));
      continue;
    }
    ax.duty = ax.open_loop ? ax.open_duty : pid_step(i);
    motor_set_duty(static_cast<Axis>(i), ax.duty);
  }
  if (g_retract.active) return;  // 후퇴 스톨은 retract_tick이 본다
  if (g_state == State::Homing) {
    // 원점 복귀: 개루프 듀티를 주는 축이 HOME_STALL_MS 동안 안 움직이면 멈춘다(스위치 고장 → 끝에 닿음,
    // 또는 듀티 부족). 기한까지 벽을 밀지 않는다.
    const HomeGroup& g = kHomeGroups[g_home.group];
    for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
      if (in_group(g, i) && g_ax[i].open_duty != 0 && stall_step(i, 1, HOME_STALL_MS)) {
        fault("stall");
        return;
      }
    }
    return;
  }
  if (!busy()) return;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (g_ax[i].stall_check && stall_step(i, STALL_MIN_PWM, STALL_TIMEOUT_MS)) {
      fault("stall");
      return;
    }
  }
}

}  // namespace

// ── 공개 함수 ────────────────────────────────────────────────────────────────

void motion_lock() {
  if (g_lock != nullptr) xSemaphoreTake(g_lock, portMAX_DELAY);
}

void motion_unlock() {
  if (g_lock != nullptr) xSemaphoreGive(g_lock);
}

void motion_init(bool hw_ok) {
  if (g_lock == nullptr) g_lock = xSemaphoreCreateMutexStatic(&g_lock_buf);
  g_hw_ok = hw_ok;
  g_state = State::Idle;
  g_homed = false;
  g_now = millis();
  g_last_host = g_now;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    g_ax[i] = AxisCtl{};
    g_ax[i].pos = encoder_read(static_cast<Axis>(i));
    vel_reset(g_ax[i]);
    reset_axis_control(i);
  }
  g_traj.active = false;
  g_retract.active = false;
  cut_outputs_now();
#if Z_MODE == Z_MODE_SOLENOID
  // 재부팅 직전에 코일이 켜져 있었을 수 있다(워치독·패닉) — 부팅 뒤 최소 꺼짐 시간 동안은 켜지 않는다.
  g_sol_off_at = millis();
  g_sol_cooldown_ms = SOLENOID_MIN_OFF_MS;
#endif
  if (!hw_ok) {
    g_state = State::Alarm;
    g_alarm = "hw_init";
  }
}

void motion_note_host_line(uint32_t now_ms) { g_last_host = now_ms; }

void motion_tick(uint32_t now_ms) {
  g_now = now_ms;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    g_ax[i].pos = encoder_read(static_cast<Axis>(i));
    vel_update(g_ax[i]);
  }
  limits_sample();

  if (g_braking && since(g_brake_until) >= 0) {
    for (uint8_t i = 0; i < AXIS_COUNT; ++i) motor_set_duty(static_cast<Axis>(i), 0);
    drivers_standby_outputs(false);
    g_braking = false;
  }

  const bool host_silent = since(g_last_host) >= static_cast<int32_t>(HOST_WATCHDOG_MS);
#if Z_MODE == Z_MODE_SOLENOID
  // 백스톱: 어떤 경로로 켜져 있든 SOLENOID_ON_MAX_MS를 넘기면 끈다(코일 발열). 누름 중이면 timeout 알람.
  if (solenoid_is_on() &&
      static_cast<int32_t>(millis() - g_sol_on_at) > static_cast<int32_t>(SOLENOID_ON_MAX_MS) + kSolBackstopGraceMs) {
    if (busy()) {
      fault("timeout");  // 끄고(z_retract done) 알람 이벤트 → 대기 명령 실패
    } else {
      sol_off();
    }
  }
#endif
  if (g_retract.active) {
    retract_tick();  // 한도(Z_RETRACT_MS)가 있어 워치독을 보지 않는다
  } else if (busy()) {
    if (host_silent) {
      fault("host_timeout", true);  // 워치독 부류 — Z 후퇴 없이 즉시 끊는다
    } else if (since(g_cmd_start) >= static_cast<int32_t>(g_cmd_max_ms)) {
      fault("timeout");
    } else if ((g_state == State::Moving || g_state == State::Pressing) && any_limit_active()) {
      fault("limit");  // 원점 복귀 밖에서 스위치가 눌렸다
    }
  } else if (g_outputs_on && host_silent) {
    // 정지 유지(IDLE_POLICY_HOLD) 중 호스트가 조용하다 — 알람 없이 출력만 내린다.
    brake_then_standby(IDLE_RELEASE_BRAKE_MS);
  }

  if (g_outputs_on && !g_retract.active) {
    traj_update();
    switch (g_state) {
      case State::Homing: home_tick(); break;
      case State::Moving:
        if (traj_arrived(kMaskAB)) finish_ok();
        break;
      case State::Pressing: press_tick(); break;
      default: break;
    }
  }

  if (g_outputs_on) drive_axes();

  // 위치 보고(선택 이벤트): 이동·누름 중 POSITION_EVENT_MS마다. 115200bps에서 한 줄 ~40B라 부담이 작다.
  if ((g_state == State::Moving || g_state == State::Pressing) &&
      since(g_last_position_event) >= static_cast<int32_t>(POSITION_EVENT_MS)) {
    emit_position();
  }
}

void motion_cmd_status(const ReqId& id) {
  MotionSnapshot s;
  s.state = state_name(g_state);
  s.homed = g_homed;
  s.a = g_ax[AXIS_A].pos;
  s.b = g_ax[AXIS_B].pos;
  s.z = z_report();
  s.alarm = g_state == State::Alarm ? g_alarm : nullptr;
  proto_reply_status(id, s);
}

void motion_cmd_limits(const ReqId& id) {
  bool raw[LIMIT_COUNT];
  bool deb[LIMIT_COUNT];
  for (uint8_t i = 0; i < LIMIT_COUNT; ++i) {
    raw[i] = limit_raw_now(static_cast<LimitId>(i));
    deb[i] = limit_active(static_cast<LimitId>(i));
  }
  proto_reply_limits(id, raw, deb);
}

void motion_cmd_home(const ReqId& id) {
  if (busy() || g_retract.active) {
    proto_reply_error(id, "busy");
    return;
  }
  if (!g_hw_ok) {
    proto_reply_error(id, "hw_init");
    return;
  }
  g_now = millis();
  g_alarm = nullptr;
  g_homed = false;
  enable_outputs();
  begin_command(id, State::Homing, HOME_MAX_MS);
  g_home.group = 0;
  home_start_group();
  home_enter_phase(limit_active(kHomeGroups[0].limit) ? HomePhase::Backoff : HomePhase::FastApproach);
}

namespace {
const char* motion_refusal() {
  if (busy() || g_retract.active) return "busy";
  if (g_state == State::Alarm) return "alarm";
  if (!g_homed) return "not_homed";
  return nullptr;
}

uint32_t capped(uint32_t ms, uint32_t cap) { return ms < cap ? ms : cap; }
}  // namespace

void motion_cmd_move(const ReqId& id, int32_t a, int32_t b, bool has_xy, float x_mm, float y_mm) {
  if (const char* refusal = motion_refusal()) {
    proto_reply_error(id, refusal);
    return;
  }
  if (a < A_MIN_COUNTS || a > A_MAX_COUNTS || b < B_MIN_COUNTS || b > B_MAX_COUNTS ||
      (has_xy && (!isfinite(x_mm) || !isfinite(y_mm) || x_mm < X_MIN_MM || x_mm > X_MAX_MM ||
                  y_mm < Y_MIN_MM || y_mm > Y_MAX_MM))) {
    proto_reply_error(id, "soft_limit");
    return;
  }
  g_now = millis();
  enable_outputs();
  float end[AXIS_COUNT] = {static_cast<float>(a), static_cast<float>(b), g_ax[AXIS_Z].target};
  traj_start(kMaskAB, end, MOVE_SPEED_CPS, MOVE_ACCEL_CPS2);
  const uint32_t expected = profile_ms(g_traj.length, MOVE_SPEED_CPS, MOVE_ACCEL_CPS2);
  begin_command(id, State::Moving, capped(expected + ARRIVE_DWELL_MS + MOVE_TIMEOUT_MARGIN_MS, MOVE_MAX_MS));
}

void motion_cmd_press(const ReqId& id, bool depth, int32_t amount, int32_t dwell_ms) {
  if (const char* refusal = motion_refusal()) {
    proto_reply_error(id, refusal);
    return;
  }
#if Z_MODE == Z_MODE_SOLENOID
  // 솔레노이드: 깊이를 모른다 → depth 거절. 켜짐 시간 = 구동(drive_ms) + 유지(dwell_ms).
  if (depth) {
    proto_reply_error(id, "z_unsupported");
    return;
  }
  const int32_t on_ms = amount + dwell_ms;
  if (amount > PRESS_DRIVE_MAX_MS || on_ms > static_cast<int32_t>(SOLENOID_ON_MAX_MS)) {
    proto_reply_error(id, "soft_limit");
    return;
  }
  if (dwell_ms > PRESS_DWELL_MAX_MS) {
    proto_reply_error(id, "bad_args");
    return;
  }
  if (sol_cooling()) {
    proto_reply_error(id, "z_cooldown");  // 코일 냉각 시간 안 — 움직이지 않은 거절(호스트는 재홈하지 않는다)
    return;
  }
  g_now = millis();
  enable_outputs();  // XY는 PID로 제자리 유지
  begin_command(id, State::Pressing,
                capped(static_cast<uint32_t>(on_ms) + SOLENOID_RELEASE_MS + MOVE_TIMEOUT_MARGIN_MS, PRESS_MAX_MS));
  g_press.depth = false;
  g_press.amount = on_ms;
  g_press.dwell_ms = static_cast<uint32_t>(dwell_ms);
  g_press.phase = PressPhase::SolenoidOn;
  g_press.t0 = g_now;
  proto_event("press_start");
  sol_on();
#else
  if ((depth && amount > Z_PRESS_MAX_COUNTS) || (!depth && amount > PRESS_DRIVE_MAX_MS)) {
    proto_reply_error(id, "soft_limit");
    return;
  }
  if (dwell_ms > PRESS_DWELL_MAX_MS) {
    proto_reply_error(id, "bad_args");
    return;
  }
  g_now = millis();
  enable_outputs();
  // 기한 = 내려가기(깊이 또는 구동 시간) + 머묾 + 올라오기(최대 깊이 기준) + 여유, 상한 PRESS_MAX_MS.
  const uint32_t up_ms = profile_ms(static_cast<float>(Z_PRESS_MAX_COUNTS), Z_SPEED_CPS, Z_ACCEL_CPS2);
  const uint32_t down_ms =
      depth ? profile_ms(static_cast<float>(amount), Z_SPEED_CPS, Z_ACCEL_CPS2) : static_cast<uint32_t>(amount);
  const uint32_t expected = down_ms + static_cast<uint32_t>(dwell_ms) + up_ms + 2 * ARRIVE_DWELL_MS;
  begin_command(id, State::Pressing, capped(expected + MOVE_TIMEOUT_MARGIN_MS, PRESS_MAX_MS));
  g_press.depth = depth;
  g_press.amount = amount;
  g_press.dwell_ms = static_cast<uint32_t>(dwell_ms);
  g_press.t0 = g_now;
  AxisCtl& z = g_ax[AXIS_Z];
  z.stall_check = true;
  stall_reset(z);
  proto_event("press_start");
  if (depth) {
    g_press.phase = PressPhase::Down;
    float end[AXIS_COUNT] = {g_ax[AXIS_A].target, g_ax[AXIS_B].target, static_cast<float>(amount)};
    traj_start(kMaskZ, end, Z_SPEED_CPS, Z_ACCEL_CPS2);
  } else {
    g_press.phase = PressPhase::DownOpen;
    z.open_loop = true;
    z.open_duty = PRESS_DRIVE_PWM;
    z.stall_check = false;  // 시간 누름은 버튼에 닿아 멈추는 것이 정상이다(깊이 상한은 따로 본다)
  }
#endif
}

void motion_cmd_stop(const ReqId& id) {
  const bool was_busy = busy();
  const bool was_retracting = g_retract.active;
  cut_outputs_now();  // 듀티 0 + STBY LOW 먼저
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) reset_axis_control(i);
  if (was_retracting) {
    // 알람 뒤 Z 후퇴 중 정지 — 후퇴를 멈추고 미뤄 둔 알람 이벤트·실패 응답을 지금 보낸다.
    g_retract.active = false;
    report_alarm("stopped");
  } else if (was_busy) {
    g_homed = false;  // 중간에 끊긴 동작 — 호스트도 재홈 전까지 믿지 않는다
    if (g_has_pending) {
      g_has_pending = false;
      proto_reply_error(g_pending, "stopped");
    }
  }
  if (g_state != State::Alarm) g_state = State::Stopped;
  proto_reply_ok(id);
}
