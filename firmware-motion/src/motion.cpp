#include "motion.h"

#include <math.h>

#include "config.h"
#include "drivers.h"

// 응답 순서 규칙(호스트 serial_motion.py의 처리 순서 때문에 중요):
//   알람은 `{"event":"alarm"}`을 **먼저**, 대기 중 명령의 `ok:false` 응답을 **나중에** 보낸다.
//   호스트는 이벤트를 받는 즉시 그 요청을 실패로 끝내고 늦은 응답은 id 불일치로 버린다.
//   순서가 반대면 알람 이벤트가 다음 요청(예: 복구용 home)을 실패시킨다.

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

constexpr float kDt = CONTROL_PERIOD_US / 1000000.0f;
constexpr uint8_t kMaskAB = (1u << AXIS_A) | (1u << AXIS_B);
constexpr uint8_t kMaskZ = (1u << AXIS_Z);

struct PidGains {
  float kp, ki, kd, i_limit;
  int32_t out_limit;
};

const PidGains kGains[AXIS_COUNT] = {
    {PID_XY_KP, PID_XY_KI, PID_XY_KD, PID_XY_I_LIMIT, PWM_LIMIT_XY},
    {PID_XY_KP, PID_XY_KI, PID_XY_KD, PID_XY_I_LIMIT, PWM_LIMIT_XY},
    {PID_Z_KP, PID_Z_KI, PID_Z_KD, PID_Z_I_LIMIT, PWM_LIMIT_Z},
};

struct AxisCtl {
  int32_t pos;
  int32_t prev_pos;
  float target;
  float integ;
  int32_t duty;
  bool open_loop;  // duration 누름: 듀티 직접 지정
  int32_t open_duty;
  bool stall_check;
  bool stall_timing;
  int32_t stall_ref;
  uint32_t stall_since;
};

struct Trajectory {
  bool active;
  uint8_t mask;
  float start[AXIS_COUNT];
  float end[AXIS_COUNT];
  uint32_t t0;
  uint32_t dur_ms;
};

enum class HomePhase : uint8_t { FastApproach, Backoff, SlowApproach, FinalBackoff };

struct HomeGroup {
  LimitId limit;
  int8_t dir[AXIS_COUNT];  // 스위치 쪽 방향, 0 = 이 단계에서 움직이지 않음
};

// 순서: Z 후퇴 → X → Y
const HomeGroup kHomeGroups[] = {
    {LIMIT_Z, {0, 0, HOME_Z_DIR}},
    {LIMIT_X, {HOME_X_DIR_A, HOME_X_DIR_B, 0}},
    {LIMIT_Y, {HOME_Y_DIR_A, HOME_Y_DIR_B, 0}},
};
constexpr uint8_t kHomeGroupCount = sizeof(kHomeGroups) / sizeof(kHomeGroups[0]);

struct HomeCtx {
  uint8_t group;
  HomePhase phase;
  int32_t phase_start[AXIS_COUNT];
};

enum class PressPhase : uint8_t { Down, DownOpen, Dwell, Up };

struct PressCtx {
  PressPhase phase;
  bool depth;
  int32_t amount;
  uint32_t dwell_ms;
  uint32_t t0;
};

AxisCtl g_ax[AXIS_COUNT];
Trajectory g_traj;
HomeCtx g_home;
PressCtx g_press;

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
uint32_t g_last_host = 0;
uint32_t g_now = 0;
uint32_t g_last_position_event = 0;

bool g_settling = false;
uint32_t g_settle_since = 0;

bool busy() { return g_state == State::Homing || g_state == State::Moving || g_state == State::Pressing; }

int32_t iabs(int32_t v) { return v < 0 ? -v : v; }

void reset_axis_control(uint8_t i) {
  g_ax[i].target = static_cast<float>(g_ax[i].pos);
  g_ax[i].prev_pos = g_ax[i].pos;
  g_ax[i].integ = 0.0f;
  g_ax[i].open_loop = false;
  g_ax[i].open_duty = 0;
  g_ax[i].stall_check = true;
  g_ax[i].stall_timing = false;
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

// 즉시: 듀티 0, STBY LOW(출력 High-Z). 정지 명령 경로.
void cut_outputs_now() {
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    motor_set_duty(static_cast<Axis>(i), 0);
    g_ax[i].duty = 0;
  }
  drivers_standby_outputs(false);
  g_outputs_on = false;
  g_braking = false;
  g_traj.active = false;
}

// short brake FAULT_BRAKE_MS 뒤 STBY LOW. 알람·워치독 경로.
void brake_then_standby() {
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    motor_brake(static_cast<Axis>(i));
    g_ax[i].duty = 0;
  }
  g_outputs_on = false;
  g_braking = true;
  g_brake_until = g_now + FAULT_BRAKE_MS;
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
  proto_event_position(g_ax[AXIS_A].pos, g_ax[AXIS_B].pos, g_ax[AXIS_Z].pos);
}

void finish_ok() {
  // 이동·누름이 끝난 위치를 ok 응답보다 먼저 보낸다(호스트는 이벤트를 먼저 처리한다).
  if (g_state == State::Moving || g_state == State::Pressing) emit_position();
  g_state = State::Idle;
  g_traj.active = false;
  if (g_has_pending) {
    g_has_pending = false;
    proto_reply_ok(g_pending);
  }
}

void fault(const char* reason) {
  brake_then_standby();
  g_state = State::Alarm;
  g_alarm = reason;
  g_homed = false;  // 위치 기준을 믿지 않는다 — home으로 복구
  proto_event_alarm(reason);  // 이벤트 먼저
  if (g_has_pending) {
    g_has_pending = false;
    proto_reply_error(g_pending, reason);
  }
}

// ── 궤적(목표 카운트를 일정 속도로 옮긴다) ──────────────────────────────────

void traj_start(uint8_t mask, const float* end, float speed_cps) {
  float max_delta = 0.0f;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    g_traj.start[i] = g_ax[i].target;
    g_traj.end[i] = (mask & (1u << i)) ? end[i] : g_ax[i].target;
    const float d = fabsf(g_traj.end[i] - g_traj.start[i]);
    if (d > max_delta) max_delta = d;
  }
  uint32_t dur = static_cast<uint32_t>(max_delta / speed_cps * 1000.0f);
  g_traj.dur_ms = dur == 0 ? 1 : dur;
  g_traj.mask = mask;
  g_traj.t0 = g_now;
  g_traj.active = true;
  g_settling = false;
}

void traj_update() {
  if (!g_traj.active) return;
  const uint32_t elapsed = g_now - g_traj.t0;
  float frac = static_cast<float>(elapsed) / static_cast<float>(g_traj.dur_ms);
  if (frac >= 1.0f) {
    frac = 1.0f;
    g_traj.active = false;
  }
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (g_traj.mask & (1u << i)) {
      g_ax[i].target = g_traj.start[i] + (g_traj.end[i] - g_traj.start[i]) * frac;
    }
  }
}

// 궤적이 끝났고, 마스크 축이 허용 오차 안에 SETTLE_MS 동안 머물렀는가.
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
  return (g_now - g_settle_since) >= SETTLE_MS;
}

// ── 원점 복귀 ────────────────────────────────────────────────────────────────

uint8_t group_mask(const HomeGroup& g) {
  uint8_t mask = 0;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (g.dir[i] != 0) mask |= (1u << i);
  }
  return mask;
}

void home_enter_phase(HomePhase phase) {
  g_home.phase = phase;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    g_home.phase_start[i] = g_ax[i].pos;
    g_ax[i].target = static_cast<float>(g_ax[i].pos);  // 앞선 목표를 버리고 제자리에서 시작
    g_ax[i].integ = 0.0f;
  }
}

int32_t home_travel(const HomeGroup& g) {
  int32_t travel = 0;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (g.dir[i] == 0) continue;
    const int32_t d = iabs(g_ax[i].pos - g_home.phase_start[i]);
    if (d > travel) travel = d;
  }
  return travel;
}

// 속도 모드: toward=+1이면 스위치 쪽, -1이면 반대쪽. 목표가 너무 앞서면 더 밀지 않는다.
void home_advance(const HomeGroup& g, int8_t toward, float speed_cps) {
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (g.dir[i] == 0) continue;
    const float lead = g_ax[i].target - static_cast<float>(g_ax[i].pos);
    if (fabsf(lead) > HOME_MAX_LEAD_COUNTS) continue;
    g_ax[i].target += static_cast<float>(g.dir[i] * toward) * speed_cps * kDt;
  }
}

void home_tick() {
  const HomeGroup& g = kHomeGroups[g_home.group];
  const bool hit = limit_active(g.limit);
  const int32_t travel = home_travel(g);
  const int32_t short_limit = HOME_BACKOFF_COUNTS * HOME_RELEASE_FACTOR;

  switch (g_home.phase) {
    case HomePhase::FastApproach:
      if (hit) {
        home_enter_phase(HomePhase::Backoff);
      } else if (travel > HOME_MAX_TRAVEL_COUNTS) {
        fault("home_not_found");
      } else {
        home_advance(g, +1, HOME_FAST_CPS);
      }
      break;
    case HomePhase::Backoff:
      if (!hit && travel >= HOME_BACKOFF_COUNTS) {
        home_enter_phase(HomePhase::SlowApproach);
      } else if (travel > short_limit) {
        fault("home_not_found");  // 후퇴해도 스위치가 풀리지 않는다(고착·배선)
      } else {
        home_advance(g, -1, HOME_SLOW_CPS);
      }
      break;
    case HomePhase::SlowApproach:
      if (hit) {
        home_enter_phase(HomePhase::FinalBackoff);
        float end[AXIS_COUNT];
        for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
          end[i] = g_ax[i].target - static_cast<float>(g.dir[i] * HOME_BACKOFF_COUNTS);
        }
        traj_start(group_mask(g), end, HOME_SLOW_CPS);
      } else if (travel > short_limit) {
        fault("home_not_found");
      } else {
        home_advance(g, +1, HOME_SLOW_CPS);
      }
      break;
    case HomePhase::FinalBackoff:
      if (!traj_arrived(group_mask(g))) break;
      if (hit) {
        fault("home_not_found");
        break;
      }
      if (++g_home.group < kHomeGroupCount) {
        home_enter_phase(HomePhase::FastApproach);
        if (limit_active(kHomeGroups[g_home.group].limit)) home_enter_phase(HomePhase::Backoff);
        break;
      }
      // 모든 축 완료: 지금 위치를 원점(0)으로.
      for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
        encoder_zero(static_cast<Axis>(i));
        g_ax[i].pos = 0;
        reset_axis_control(i);
      }
      g_homed = true;
      finish_ok();
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
        z.stall_timing = false;
      }
      break;
    case PressPhase::DownOpen:
      if (z.pos > Z_PRESS_MAX_COUNTS) {
        fault("soft_limit");
      } else if ((g_now - g_press.t0) >= static_cast<uint32_t>(g_press.amount)) {
        z.open_loop = false;
        z.target = static_cast<float>(z.pos);
        z.integ = 0.0f;
        g_press.phase = PressPhase::Dwell;
        g_press.t0 = g_now;
      }
      break;
    case PressPhase::Dwell:
      if ((g_now - g_press.t0) >= g_press.dwell_ms) {
        z.stall_check = true;
        z.stall_timing = false;
        g_press.phase = PressPhase::Up;
        float end[AXIS_COUNT] = {0.0f, 0.0f, 0.0f};
        traj_start(kMaskZ, end, Z_SPEED_CPS);
      }
      break;
    case PressPhase::Up:
      if (traj_arrived(kMaskZ)) {
        proto_event("press_end");
        finish_ok();
      }
      break;
  }
}

// ── 축 제어 ──────────────────────────────────────────────────────────────────

int32_t pid_step(uint8_t i) {
  AxisCtl& ax = g_ax[i];
  const PidGains& k = kGains[i];
  const float err = ax.target - static_cast<float>(ax.pos);
  const bool holding = !g_traj.active || !(g_traj.mask & (1u << i));
  if (holding && fabsf(err) <= POS_TOLERANCE_COUNTS) {
    ax.integ = 0.0f;
    return 0;
  }
  ax.integ += k.ki * err * kDt;
  if (ax.integ > k.i_limit) ax.integ = k.i_limit;
  if (ax.integ < -k.i_limit) ax.integ = -k.i_limit;
  const float vel = static_cast<float>(ax.pos - ax.prev_pos) / kDt;
  float out = k.kp * err + ax.integ - k.kd * vel;
  if (out > k.out_limit) out = static_cast<float>(k.out_limit);
  if (out < -k.out_limit) out = -static_cast<float>(k.out_limit);
  int32_t duty = static_cast<int32_t>(out);
  if (duty != 0 && iabs(duty) < PWM_MIN_EFFECTIVE) duty = duty > 0 ? PWM_MIN_EFFECTIVE : -PWM_MIN_EFFECTIVE;
  return duty;
}

// true = 스톨 판정
bool stall_step(uint8_t i) {
  AxisCtl& ax = g_ax[i];
  if (!ax.stall_check || iabs(ax.duty) < STALL_MIN_PWM) {
    ax.stall_timing = false;
    return false;
  }
  if (!ax.stall_timing || iabs(ax.pos - ax.stall_ref) >= STALL_MIN_DELTA_COUNTS) {
    ax.stall_timing = true;
    ax.stall_ref = ax.pos;
    ax.stall_since = g_now;
    return false;
  }
  return (g_now - ax.stall_since) >= STALL_TIMEOUT_MS;
}

void drive_axes() {
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    AxisCtl& ax = g_ax[i];
    ax.duty = ax.open_loop ? ax.open_duty : pid_step(i);
    motor_set_duty(static_cast<Axis>(i), ax.duty);
  }
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (stall_step(i)) {
      // 원점 탐색 중 스톨은 스위치를 못 찾고 끝에 닿은 것으로 본다.
      fault(g_state == State::Homing ? "home_not_found" : "stall");
      return;
    }
  }
}

}  // namespace

// ── 공개 함수 ────────────────────────────────────────────────────────────────

void motion_init(bool hw_ok) {
  g_hw_ok = hw_ok;
  g_state = State::Idle;
  g_homed = false;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    g_ax[i] = AxisCtl{};
    g_ax[i].pos = encoder_read(static_cast<Axis>(i));
    reset_axis_control(i);
  }
  g_traj.active = false;
  cut_outputs_now();
  if (!hw_ok) {
    g_state = State::Alarm;
    g_alarm = "hw_init";
  }
}

void motion_note_host_line(uint32_t now_ms) { g_last_host = now_ms; }

void motion_tick(uint32_t now_ms) {
  g_now = now_ms;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) g_ax[i].pos = encoder_read(static_cast<Axis>(i));
  limits_sample();

  if (g_braking && static_cast<int32_t>(g_now - g_brake_until) >= 0) {
    for (uint8_t i = 0; i < AXIS_COUNT; ++i) motor_set_duty(static_cast<Axis>(i), 0);
    drivers_standby_outputs(false);
    g_braking = false;
  }

  if (busy()) {
    if ((g_now - g_last_host) >= HOST_WATCHDOG_MS) {
      fault("host_timeout");
    } else if ((g_now - g_cmd_start) >= g_cmd_max_ms) {
      fault("timeout");
    } else if ((g_state == State::Moving || g_state == State::Pressing) && any_limit_active()) {
      fault("limit");  // 원점 복귀 밖에서 스위치가 눌렸다
    }
  }

  if (g_outputs_on) {
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
      (g_now - g_last_position_event) >= POSITION_EVENT_MS) {
    emit_position();
  }

  for (uint8_t i = 0; i < AXIS_COUNT; ++i) g_ax[i].prev_pos = g_ax[i].pos;
}

void motion_cmd_status(const ReqId& id) {
  MotionSnapshot s;
  s.state = state_name(g_state);
  s.homed = g_homed;
  s.a = g_ax[AXIS_A].pos;
  s.b = g_ax[AXIS_B].pos;
  s.z = g_ax[AXIS_Z].pos;
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
  if (busy()) {
    proto_reply_error(id, "busy");
    return;
  }
  if (!g_hw_ok) {
    proto_reply_error(id, "hw_init");
    return;
  }
  g_alarm = nullptr;
  g_homed = false;
  enable_outputs();
  begin_command(id, State::Homing, HOME_MAX_MS);
  g_home.group = 0;
  home_enter_phase(HomePhase::FastApproach);
  if (limit_active(kHomeGroups[0].limit)) home_enter_phase(HomePhase::Backoff);
}

namespace {
const char* motion_refusal() {
  if (busy()) return "busy";
  if (g_state == State::Alarm) return "alarm";
  if (!g_homed) return "not_homed";
  return nullptr;
}
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
  enable_outputs();
  begin_command(id, State::Moving, MOVE_MAX_MS);
  float end[AXIS_COUNT] = {static_cast<float>(a), static_cast<float>(b), 0.0f};
  traj_start(kMaskAB, end, MOVE_SPEED_CPS);
}

void motion_cmd_press(const ReqId& id, bool depth, int32_t amount, int32_t dwell_ms) {
  if (const char* refusal = motion_refusal()) {
    proto_reply_error(id, refusal);
    return;
  }
  if ((depth && amount > Z_PRESS_MAX_COUNTS) || (!depth && amount > PRESS_DRIVE_MAX_MS)) {
    proto_reply_error(id, "soft_limit");
    return;
  }
  if (dwell_ms > PRESS_DWELL_MAX_MS) {
    proto_reply_error(id, "bad_args");
    return;
  }
  enable_outputs();
  begin_command(id, State::Pressing, PRESS_MAX_MS);
  g_press.depth = depth;
  g_press.amount = amount;
  g_press.dwell_ms = static_cast<uint32_t>(dwell_ms);
  g_press.t0 = g_now;
  AxisCtl& z = g_ax[AXIS_Z];
  z.stall_check = true;
  z.stall_timing = false;
  proto_event("press_start");
  if (depth) {
    g_press.phase = PressPhase::Down;
    float end[AXIS_COUNT] = {0.0f, 0.0f, static_cast<float>(amount)};
    traj_start(kMaskZ, end, Z_SPEED_CPS);
  } else {
    g_press.phase = PressPhase::DownOpen;
    z.open_loop = true;
    z.open_duty = PRESS_DRIVE_PWM;
    z.stall_check = false;  // 시간 누름은 버튼에 닿아 멈추는 것이 정상이다(깊이 상한은 따로 본다)
  }
}

void motion_cmd_stop(const ReqId& id) {
  const bool was_busy = busy();
  cut_outputs_now();  // 듀티 0 + STBY LOW 먼저
  if (was_busy) {
    g_homed = false;  // 중간에 끊긴 동작 — 호스트도 재홈 전까지 믿지 않는다
    if (g_has_pending) {
      g_has_pending = false;
      proto_reply_error(g_pending, "stopped");
    }
  }
  if (g_state != State::Alarm) g_state = State::Stopped;
  proto_reply_ok(id);
}
