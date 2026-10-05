#include "outlet.h"

#include <Arduino.h>
#include <driver/gpio.h>

#include "config.h"

namespace {

portMUX_TYPE g_mux = portMUX_INITIALIZER_UNLOCKED;
bool g_relay_on = false;
bool g_estop_latched = false;
bool g_estop_pending_event = false;
uint32_t g_estop_t_ms = 0;
uint8_t g_active_run = 0;

constexpr int kRelayOffLevel = (RELAY_ACTIVE_LEVEL == HIGH) ? LOW : HIGH;

inline bool button_active_now() {
  return gpio_get_level(static_cast<gpio_num_t>(PIN_ESTOP)) == ESTOP_ACTIVE_LEVEL;
}

// 임계구역 안에서만 부른다. digitalWrite 대신 레지스터 쓰기(gpio_set_level) — 임계구역 안에서
// 잠금을 잡을 수 있는 코어 함수를 부르지 않는다.
inline void write_relay_locked(bool on) {
  g_relay_on = on;
  gpio_set_level(static_cast<gpio_num_t>(PIN_RELAY), on ? RELAY_ACTIVE_LEVEL : kRelayOffLevel);
}

}  // namespace

void outlet_init() {
  // 출력으로 바꾸기 **전에** 꺼짐 레벨을 써 둔다 — 부팅 중 잠깐이라도 켜짐 펄스가 나가지 않게.
  digitalWrite(PIN_RELAY, kRelayOffLevel);
  pinMode(PIN_RELAY, OUTPUT);
  digitalWrite(PIN_RELAY, kRelayOffLevel);
  pinMode(PIN_ESTOP, ESTOP_USE_PULLUP ? INPUT_PULLUP : INPUT);
  portENTER_CRITICAL(&g_mux);
  g_relay_on = false;  // fail-safe 기본: 꺼짐. 호스트 relay_on이 있어야 켠다.
  g_estop_latched = false;
  g_estop_pending_event = false;
  g_active_run = 0;
  portEXIT_CRITICAL(&g_mux);
}

bool outlet_poll_estop(uint32_t now_ms) {
  const bool active = button_active_now();
  bool tripped = false;
  portENTER_CRITICAL(&g_mux);
  if (!active) {
    g_active_run = 0;
  } else if (g_active_run < 255) {
    ++g_active_run;
  }
  if (active && g_active_run >= ESTOP_TRIP_SAMPLES && !g_estop_latched) {
    write_relay_locked(false);
    g_estop_latched = true;
    g_estop_pending_event = true;
    g_estop_t_ms = now_ms;
    tripped = true;
  } else if (g_estop_latched && g_relay_on) {
    // 걸린 동안은 어떤 경로로도 켜지지 않게 매 틱 다시 연다(방어).
    write_relay_locked(false);
  }
  portEXIT_CRITICAL(&g_mux);
  return tripped;
}

const char* outlet_relay_on() {
  const char* err = nullptr;
  portENTER_CRITICAL(&g_mux);
  if (g_estop_latched) {
    err = "estop_latched";
  } else {
    write_relay_locked(true);
  }
  portEXIT_CRITICAL(&g_mux);
  return err;
}

void outlet_relay_off() {
  portENTER_CRITICAL(&g_mux);
  write_relay_locked(false);
  portEXIT_CRITICAL(&g_mux);
}

const char* outlet_estop_reset() {
  const bool active = button_active_now();
  const char* err = nullptr;
  portENTER_CRITICAL(&g_mux);
  if (active) {
    err = "estop_active";
  } else {
    // 해제해도 릴레이는 꺼진 채로 둔다 — 다시 켜는 것은 호스트의 별도 relay_on.
    g_estop_latched = false;
    g_active_run = 0;
  }
  portEXIT_CRITICAL(&g_mux);
  return err;
}

bool outlet_host_silence_off() {
  bool changed = false;
  portENTER_CRITICAL(&g_mux);
  if (g_relay_on) {
    write_relay_locked(false);
    changed = true;
  }
  portEXIT_CRITICAL(&g_mux);
  return changed;
}

OutletSnapshot outlet_snapshot() {
  const bool active = button_active_now();
  OutletSnapshot s;
  portENTER_CRITICAL(&g_mux);
  s.relay_on = g_relay_on;
  s.estop_latched = g_estop_latched;
  s.estop_t_ms = g_estop_t_ms;
  portEXIT_CRITICAL(&g_mux);
  s.button_active = active;
  return s;
}

bool outlet_take_estop_event(uint32_t* t_ms) {
  bool pending = false;
  portENTER_CRITICAL(&g_mux);
  pending = g_estop_pending_event;
  g_estop_pending_event = false;
  *t_ms = g_estop_t_ms;
  portEXIT_CRITICAL(&g_mux);
  return pending;
}
