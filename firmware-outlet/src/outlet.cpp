#include "outlet.h"

#include <Arduino.h>
#include <Preferences.h>
#include <driver/gpio.h>
#include <esp_attr.h>

#include "config.h"

// 비상정지 걸림 보존(2026-10-05 리뷰 H2): 걸림이 RAM에만 있으면 리셋(전압 강하·워치독·포트 열기 DTR)이 풀어 버린다.
// - RTC_NOINIT 메모리: 소프트웨어 리셋·워치독·패닉을 넘어 남는다(전원이 꺼지면 사라짐 — 매직으로 쓰레기값을 가린다).
//   걸리는 그 틱(샘플링 태스크, 임계구역 안)에 바로 쓴다.
// - NVS(플래시): 전원이 꺼져도 남는다. 플래시 쓰기는 느려 loop 태스크(outlet_persist)가 나중에 쓴다.
//   걸린 직후 그 사이에 전원이 끊기는 짧은 틈만 남는다(그때도 버튼이 눌린 채면 부팅 첫 틱에 다시 걸린다).
// 부팅 때 둘 중 하나라도 걸림이면 걸린 채로 시작한다 — 릴레이는 꺼짐, relay_on은 estop_reset 전까지 거절.
RTC_NOINIT_ATTR uint32_t g_rtc_latch_magic;
RTC_NOINIT_ATTR uint32_t g_rtc_latch;

namespace {

constexpr uint32_t kLatchMagic = 0x45535450u;  // 'ESTP'

portMUX_TYPE g_mux = portMUX_INITIALIZER_UNLOCKED;
bool g_relay_on = false;
bool g_estop_latched = false;
bool g_estop_pending_event = false;
uint32_t g_estop_t_ms = 0;
uint8_t g_active_run = 0;
bool g_persist_dirty = false;  // NVS에 아직 옮기지 않은 걸림 변화
Preferences g_prefs;
bool g_prefs_ok = false;

// 임계구역 안에서만 부른다. RTC 메모리는 일반 메모리 쓰기라 바로 쓴다.
inline void remember_latch_locked(bool latched) {
  g_rtc_latch = latched ? 1u : 0u;
  g_rtc_latch_magic = kLatchMagic;
  g_persist_dirty = true;
}

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
  // 릴레이를 꺼짐으로 고정한 **뒤에** 보존된 걸림을 읽는다(NVS 열기는 수 ms 걸린다).
  const bool rtc_latched = (g_rtc_latch_magic == kLatchMagic) && (g_rtc_latch == 1u);
  bool nvs_latched = false;
#if OUTLET_ESTOP_PERSIST
  g_prefs_ok = g_prefs.begin("outlet", false);
  if (g_prefs_ok) nvs_latched = g_prefs.getBool("estop", false);
#endif
  const bool latched = rtc_latched || nvs_latched;
  portENTER_CRITICAL(&g_mux);
  g_relay_on = false;  // fail-safe 기본: 꺼짐. 호스트 relay_on이 있어야 켠다.
  g_estop_latched = latched;  // 재부팅 전에 걸려 있었으면 걸린 채로(ready·status의 estop으로 알린다)
  g_estop_pending_event = false;
  g_active_run = 0;
  g_rtc_latch = latched ? 1u : 0u;
  g_rtc_latch_magic = kLatchMagic;
  g_persist_dirty = latched != nvs_latched;  // RTC에만 남아 있던 걸림은 NVS로도 옮긴다
  portEXIT_CRITICAL(&g_mux);
}

void outlet_persist() {
#if OUTLET_ESTOP_PERSIST
  bool dirty = false;
  bool latched = false;
  portENTER_CRITICAL(&g_mux);
  dirty = g_persist_dirty;
  latched = g_estop_latched;
  g_persist_dirty = false;
  portEXIT_CRITICAL(&g_mux);
  if (!dirty || !g_prefs_ok) return;
  if (g_prefs.putBool("estop", latched) == 0) {
    portENTER_CRITICAL(&g_mux);
    g_persist_dirty = true;  // 실패하면 다음 loop에서 다시
    portEXIT_CRITICAL(&g_mux);
  }
#endif
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
    remember_latch_locked(true);
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
    remember_latch_locked(false);
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
