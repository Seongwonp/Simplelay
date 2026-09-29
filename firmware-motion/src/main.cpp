// firmware-motion — RPi4 옆 모션 MCU(ESP32). **컴파일만 확인, 실물 미검증.**
//
// RPi4(rpi/controller/serial_motion.py) ─USB 시리얼, 줄 단위 JSON─ 이 보드
//   ─ JMOD-MOTOR-1(TB6612FNG) ×2 ─ FIT0482 ×3 (CoreXY A/B + Z 누름)
// 규약의 실행 가능한 기준은 rpi/tools/fake_mcu.py, 명령 표는 firmware-motion/protocol_table.json.
//
// 구조(2026-09-29 첫날 위험 보완):
// - 제어: esp_timer가 CONTROL_HZ로 깨우는 전용 태스크(우선순위 CONTROL_TASK_PRIORITY, 코어 1)가
//   motion_tick()을 돈다. JSON 해석은 loop 태스크(우선순위 1)에서 하므로 긴 줄이 제어 주기를 밀지 않는다.
//   상태 변경·시리얼 쓰기는 motion_lock(정적 뮤텍스) 안에서만.
// - MCU 태스크 워치독: loop·제어 태스크를 esp_task_wdt에 등록(MCU_TASK_WDT_MS). 멈추면 패닉 → 재부팅.
//   재부팅 직후 GPIO는 High-Z — STBY 외부 풀다운이 출력을 꺼 둔다(config.h TODO).
// - 부팅 배너: setup 끝에 {"event":"ready","fw":..,"protocol":..,"reset":..} 한 줄. 호스트는 포트를 연 뒤
//   부트 로그(JSON 아님)를 버리고 이 줄 또는 status 재시도로 준비를 안다.
// 인터럽트 핸들러는 두지 않는다(엔코더 넘침 누적은 PCNT 드라이버 몫, 리밋 스위치는 폴링).
// 제어 루프에는 동적 할당이 없고 JSON 해석은 고정 풀을 쓴다(esp_timer 생성만 초기화 때 힙을 쓴다).
#include <Arduino.h>
#include <esp_system.h>
#include <esp_task_wdt.h>
#include <esp_timer.h>

#include "config.h"
#include "drivers.h"
#include "motion.h"
#include "protocol.h"

#if MOTION_CONFIG_PLACEHOLDER
#warning "firmware-motion: include/config.h가 아직 PLACEHOLDER 값이다 — TODO(HW 실측) 항목을 채우기 전에는 실기기 구동 근거로 쓰지 않는다"
#endif

namespace {

char g_line[HOST_LINE_MAX + 1];
size_t g_len = 0;
bool g_overflow = false;

StaticTask_t g_ctl_tcb;
StackType_t g_ctl_stack[CONTROL_TASK_STACK];
TaskHandle_t g_ctl_task = nullptr;
esp_timer_handle_t g_ctl_timer = nullptr;

// 읽은 바이트 수를 돌려준다.
int poll_host() {
  int budget = HOST_LINE_MAX;  // 한 번에 너무 오래 붙잡지 않는다
  int got = 0;
  while (budget-- > 0 && Serial.available() > 0) {
    const int c = Serial.read();
    if (c < 0) break;
    ++got;
    if (c == '\n') {
      if (!g_overflow && g_len > 0) {
        g_line[g_len] = '\0';
        motion_note_host_line(millis());
        proto_handle_line(g_line, g_len);  // 해석은 잠금 밖, 처리·응답은 잠금 안(protocol.cpp)
      }
      g_len = 0;
      g_overflow = false;
    } else if (c == '\r') {
      continue;
    } else if (g_len < HOST_LINE_MAX) {
      g_line[g_len++] = static_cast<char>(c);
    } else {
      g_overflow = true;  // 너무 긴 줄은 통째로 버린다
    }
  }
  return got;
}

void on_control_timer(void*) {
  if (g_ctl_task != nullptr) xTaskNotifyGive(g_ctl_task);
}

void control_task(void*) {
  // 첫 타이머 신호 뒤에 워치독에 등록한다(타이머를 못 만들었으면 등록 없이 잠들어 재부팅 고리를 만들지 않는다).
  ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
  esp_task_wdt_add(nullptr);
  for (;;) {
    {
      MotionGuard guard;
      motion_tick(millis());
    }
    esp_task_wdt_reset();
    // 타이머가 멈추면 여기서 깨어나지 못하고 태스크 워치독이 재부팅한다(제어가 멎은 채 출력이 남지 않게).
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
  }
}

const char* reset_reason_name() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON: return "poweron";
    case ESP_RST_SW: return "sw";
    case ESP_RST_PANIC: return "panic";
    case ESP_RST_INT_WDT: return "int_wdt";
    case ESP_RST_TASK_WDT: return "task_wdt";
    case ESP_RST_WDT: return "wdt";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_EXT: return "ext";
    default: return "other";
  }
}

void setup_task_watchdog() {
  esp_task_wdt_config_t cfg = {};
  cfg.timeout_ms = MCU_TASK_WDT_MS;
  cfg.idle_core_mask = (1u << 0);  // 코어 0 idle 감시는 유지(코어 1은 제어·loop가 쓴다)
  cfg.trigger_panic = true;
  if (esp_task_wdt_reconfigure(&cfg) == ESP_ERR_INVALID_STATE) esp_task_wdt_init(&cfg);
  esp_task_wdt_add(nullptr);  // loop 태스크(setup이 도는 태스크). 이미 등록돼 있으면 무시된다.
}

bool start_control() {
  g_ctl_task = xTaskCreateStaticPinnedToCore(control_task, "motion_ctl", CONTROL_TASK_STACK, nullptr,
                                             CONTROL_TASK_PRIORITY, g_ctl_stack, &g_ctl_tcb, CONTROL_TASK_CORE);
  if (g_ctl_task == nullptr) return false;
  esp_timer_create_args_t args = {};
  args.callback = on_control_timer;
  args.name = "motion_ctl";
  if (esp_timer_create(&args, &g_ctl_timer) != ESP_OK) return false;
  return esp_timer_start_periodic(g_ctl_timer, CONTROL_PERIOD_US) == ESP_OK;
}

}  // namespace

void setup() {
  Serial.setRxBufferSize(HOST_RX_BUFFER_BYTES);
  Serial.setTxBufferSize(HOST_TX_BUFFER_BYTES);
  Serial.begin(HOST_SERIAL_BAUD);
  const bool hw_ok = drivers_init();
  motion_init(hw_ok);
  setup_task_watchdog();
  if (!start_control()) {
    // 제어 태스크·타이머를 못 만들었다 — hw_init 알람으로 두어 home·move·press를 거절한다.
    MotionGuard guard;
    motion_init(false);
  }
  {
    MotionGuard guard;
    proto_event_ready(reset_reason_name());
  }
}

void loop() {
  const int got = poll_host();
  esp_task_wdt_reset();
  if (got == 0) vTaskDelay(1);  // 받은 것이 없으면 양보(제어 태스크·idle에 CPU를 내준다)
}
