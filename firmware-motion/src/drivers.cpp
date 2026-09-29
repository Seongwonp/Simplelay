#include "drivers.h"

#include <Arduino.h>

#include "config.h"
#include "driver/pulse_cnt.h"

namespace {

struct MotorPins {
  uint8_t pwm;
  uint8_t in1;
  uint8_t in2;
  bool invert;
};

struct EncoderPins {
  int cha;
  int chb;
  bool invert;
};

const MotorPins kMotors[AXIS_COUNT] = {
    {PIN_MOTOR_A_PWM, PIN_MOTOR_A_IN1, PIN_MOTOR_A_IN2, MOTOR_A_INVERT != 0},
    {PIN_MOTOR_B_PWM, PIN_MOTOR_B_IN1, PIN_MOTOR_B_IN2, MOTOR_B_INVERT != 0},
    {PIN_MOTOR_Z_PWM, PIN_MOTOR_Z_IN1, PIN_MOTOR_Z_IN2, MOTOR_Z_INVERT != 0},
};

const EncoderPins kEncoders[AXIS_COUNT] = {
    {PIN_ENC_A_CHA, PIN_ENC_A_CHB, ENC_A_INVERT != 0},
    {PIN_ENC_B_CHA, PIN_ENC_B_CHB, ENC_B_INVERT != 0},
    {PIN_ENC_Z_CHA, PIN_ENC_Z_CHB, ENC_Z_INVERT != 0},
};

const uint8_t kLimitPins[LIMIT_COUNT] = {PIN_LIMIT_X, PIN_LIMIT_Y, PIN_LIMIT_Z};

// PCNT 하드웨어 카운터는 16비트다. 한계에 watch point를 두고 accum_count를 켜면 드라이버가
// 넘침을 누적해 32비트 값을 돌려준다(누적은 드라이버 ISR이 하며 이 코드는 ISR을 두지 않는다).
constexpr int kPcntHigh = 30000;
constexpr int kPcntLow = -30000;

pcnt_unit_handle_t g_units[AXIS_COUNT] = {};
int32_t g_zero_offset[AXIS_COUNT] = {};

uint8_t g_limit_run[LIMIT_COUNT] = {};
bool g_limit_raw_prev[LIMIT_COUNT] = {};
bool g_limit_state[LIMIT_COUNT] = {};

int32_t raw_count(Axis axis) {
  int value = 0;
  if (g_units[axis] == nullptr || pcnt_unit_get_count(g_units[axis], &value) != ESP_OK) {
    return 0;
  }
  return kEncoders[axis].invert ? -static_cast<int32_t>(value) : static_cast<int32_t>(value);
}

bool init_encoder(Axis axis) {
  const EncoderPins& p = kEncoders[axis];

  pcnt_unit_config_t unit_cfg = {};
  unit_cfg.low_limit = kPcntLow;
  unit_cfg.high_limit = kPcntHigh;
  unit_cfg.flags.accum_count = 1;
  if (pcnt_new_unit(&unit_cfg, &g_units[axis]) != ESP_OK) return false;

  pcnt_glitch_filter_config_t filter_cfg = {};
  filter_cfg.max_glitch_ns = ENC_GLITCH_NS;
  if (pcnt_unit_set_glitch_filter(g_units[axis], &filter_cfg) != ESP_OK) return false;

  // x4 직교 디코딩: 채널 a는 CHA 엣지를 CHB 레벨로, 채널 b는 CHB 엣지를 CHA 레벨로 판정.
  pcnt_chan_config_t cha_cfg = {};
  cha_cfg.edge_gpio_num = p.cha;
  cha_cfg.level_gpio_num = p.chb;
  pcnt_channel_handle_t cha = nullptr;
  if (pcnt_new_channel(g_units[axis], &cha_cfg, &cha) != ESP_OK) return false;

  pcnt_chan_config_t chb_cfg = {};
  chb_cfg.edge_gpio_num = p.chb;
  chb_cfg.level_gpio_num = p.cha;
  pcnt_channel_handle_t chb = nullptr;
  if (pcnt_new_channel(g_units[axis], &chb_cfg, &chb) != ESP_OK) return false;

  pcnt_channel_set_edge_action(cha, PCNT_CHANNEL_EDGE_ACTION_DECREASE, PCNT_CHANNEL_EDGE_ACTION_INCREASE);
  pcnt_channel_set_level_action(cha, PCNT_CHANNEL_LEVEL_ACTION_KEEP, PCNT_CHANNEL_LEVEL_ACTION_INVERSE);
  pcnt_channel_set_edge_action(chb, PCNT_CHANNEL_EDGE_ACTION_INCREASE, PCNT_CHANNEL_EDGE_ACTION_DECREASE);
  pcnt_channel_set_level_action(chb, PCNT_CHANNEL_LEVEL_ACTION_KEEP, PCNT_CHANNEL_LEVEL_ACTION_INVERSE);

  if (pcnt_unit_add_watch_point(g_units[axis], kPcntHigh) != ESP_OK) return false;
  if (pcnt_unit_add_watch_point(g_units[axis], kPcntLow) != ESP_OK) return false;
  if (pcnt_unit_enable(g_units[axis]) != ESP_OK) return false;
  if (pcnt_unit_clear_count(g_units[axis]) != ESP_OK) return false;
  if (pcnt_unit_start(g_units[axis]) != ESP_OK) return false;
  return true;
}

bool read_limit_raw(LimitId id) { return digitalRead(kLimitPins[id]) == LIMIT_ACTIVE_LEVEL; }

}  // namespace

bool drivers_init() {
  // 출력부터 안전한 쪽으로: STBY LOW, IN1=IN2=LOW, 듀티 0.
  pinMode(PIN_STBY_AB, OUTPUT);
  pinMode(PIN_STBY_Z, OUTPUT);
  digitalWrite(PIN_STBY_AB, LOW);
  digitalWrite(PIN_STBY_Z, LOW);

  bool ok = true;
  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    const MotorPins& m = kMotors[i];
    pinMode(m.in1, OUTPUT);
    pinMode(m.in2, OUTPUT);
    digitalWrite(m.in1, LOW);
    digitalWrite(m.in2, LOW);
    if (!ledcAttach(m.pwm, PWM_FREQ_HZ, PWM_RES_BITS)) ok = false;
    ledcWrite(m.pwm, 0);
  }

  for (uint8_t i = 0; i < LIMIT_COUNT; ++i) {
    pinMode(kLimitPins[i], LIMIT_USE_PULLUP ? INPUT_PULLUP : INPUT);
    const bool raw = read_limit_raw(static_cast<LimitId>(i));
    g_limit_raw_prev[i] = raw;
    g_limit_state[i] = raw;
  }

  for (uint8_t i = 0; i < AXIS_COUNT; ++i) {
    if (!init_encoder(static_cast<Axis>(i))) ok = false;
  }
  return ok;
}

void motor_set_duty(Axis axis, int32_t duty) {
  const MotorPins& m = kMotors[axis];
  if (m.invert) duty = -duty;
  if (duty > PWM_MAX_DUTY) duty = PWM_MAX_DUTY;
  if (duty < -PWM_MAX_DUTY) duty = -PWM_MAX_DUTY;
  if (duty > 0) {
    digitalWrite(m.in2, LOW);
    digitalWrite(m.in1, HIGH);
    ledcWrite(m.pwm, static_cast<uint32_t>(duty));
  } else if (duty < 0) {
    digitalWrite(m.in1, LOW);
    digitalWrite(m.in2, HIGH);
    ledcWrite(m.pwm, static_cast<uint32_t>(-duty));
  } else {
    ledcWrite(m.pwm, 0);
    digitalWrite(m.in1, LOW);
    digitalWrite(m.in2, LOW);
  }
}

void motor_brake(Axis axis) {
  const MotorPins& m = kMotors[axis];
  digitalWrite(m.in1, HIGH);
  digitalWrite(m.in2, HIGH);
  ledcWrite(m.pwm, PWM_MAX_DUTY);
}

void drivers_standby_outputs(bool enable) {
  digitalWrite(PIN_STBY_AB, enable ? HIGH : LOW);
  digitalWrite(PIN_STBY_Z, enable ? HIGH : LOW);
}

int32_t encoder_read(Axis axis) { return raw_count(axis) - g_zero_offset[axis]; }

void encoder_zero(Axis axis) { g_zero_offset[axis] = raw_count(axis); }

void limits_sample() {
  for (uint8_t i = 0; i < LIMIT_COUNT; ++i) {
    const bool raw = read_limit_raw(static_cast<LimitId>(i));
    if (raw != g_limit_raw_prev[i]) {
      g_limit_raw_prev[i] = raw;
      g_limit_run[i] = 1;
    } else if (g_limit_run[i] < LIMIT_DEBOUNCE_TICKS) {
      ++g_limit_run[i];
    }
    if (g_limit_run[i] >= LIMIT_DEBOUNCE_TICKS) g_limit_state[i] = raw;
  }
}

bool limit_active(LimitId id) { return g_limit_state[id]; }

bool limit_raw_now(LimitId id) { return read_limit_raw(id); }

bool any_limit_active() {
  for (uint8_t i = 0; i < LIMIT_COUNT; ++i) {
    if (g_limit_state[i]) return true;
  }
  return false;
}
