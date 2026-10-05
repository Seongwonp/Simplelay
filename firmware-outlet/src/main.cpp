// firmware-outlet — ESP32 콘센트 모듈. **컴파일만 확인, 실물 미검증.**
//
// 가전 전원선(AC 라인 스플리터의 L 한 가닥) ─ 분할형 CT ─ ADS1115(또는 ESP32 ADC) ─ 이 보드
//   ─USB 시리얼, 줄 단위 JSON─ RPi4(rpi/verifier/outlet.py: 전력 샘플 → L3 판정·잔여 전류 기록)
// 이 보드 ─ 릴레이(가전 전원 차단) · 비상정지 버튼(NC)
// 규약의 실행 가능한 기준은 rpi/tools/fake_outlet.py, 명령 표는 firmware-outlet/protocol_table.json.
//
// 구조:
// - 샘플링: esp_timer가 SAMPLE_HZ로 깨우는 전용 태스크가 매 틱 ① 비상정지 버튼을 보고(걸리면 그 자리에서
//   릴레이를 연다 — 호스트·시리얼과 무관) ② CT 한 점을 읽어 창에 누적한다. 창이 차면 실효값·전력 추정을
//   우편함(한 칸)에 넣는다. 시리얼에는 쓰지 않는다.
// - loop: 호스트 줄 해석·응답, 우편함의 power 이벤트·estop 이벤트 송신, 호스트 침묵 정책.
// - 릴레이 기본 = 꺼짐(fail-safe). 부팅·재부팅·패닉 뒤에도 꺼짐에서 시작하고 호스트 relay_on이 있어야 켠다.
// - MCU 태스크 워치독: loop·샘플링 태스크를 esp_task_wdt에 등록(MCU_TASK_WDT_MS). 멈추면 패닉 → 재부팅.
// - CT 초기화 실패면 {"event":"fault","reason":"ct_init"}을 보내고 power 이벤트를 내지 않는다
//   (0 W를 지어내지 않는다 — 호스트는 '데이터 없음'으로 본다). 비상정지·릴레이는 그대로 동작한다.
#include <Arduino.h>
#include <esp_system.h>
#include <esp_task_wdt.h>
#include <esp_timer.h>

#include "config.h"
#include "ct.h"
#include "outlet.h"
#include "protocol.h"

#if OUTLET_CONFIG_PLACEHOLDER
#warning "firmware-outlet: include/config.h가 아직 PLACEHOLDER 값이다 — 핀·CT 보정·릴레이 극성을 확인하기 전에는 실기기 근거로 쓰지 않는다"
#endif

namespace {

char g_line[HOST_LINE_MAX + 1];
size_t g_len = 0;
bool g_overflow = false;
uint32_t g_last_host_ms = 0;
bool g_silence_tripped = false;

bool g_ct_ok = false;
portMUX_TYPE g_mail_mux = portMUX_INITIALIZER_UNLOCKED;
PowerReport g_mail;
bool g_mail_full = false;

StaticTask_t g_tcb;
StackType_t g_stack[SAMPLE_TASK_STACK];
TaskHandle_t g_task = nullptr;
esp_timer_handle_t g_timer = nullptr;

void on_sample_timer(void*) {
  if (g_task != nullptr) xTaskNotifyGive(g_task);
}

void sample_task(void*) {
  ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
  esp_task_wdt_add(nullptr);
  CtWindow window;
  ct_window_reset(&window);
  uint32_t ticks = 0;
  uint32_t seq = 0;
  for (;;) {
    const uint32_t now = millis();
    outlet_poll_estop(now);  // 버튼 차단이 먼저 — CT 읽기(I2C)가 늦어도 차단은 이 틱에 끝난다
    if (g_ct_ok) {
      int32_t uv = 0;
      if (ct_read_uv(&uv)) {
        ct_window_add(&window, uv);
      } else {
        ++window.read_errors;
      }
    }
    ++ticks;
    const uint32_t hz = proto_report_hz();
    const uint32_t per_window = SAMPLE_HZ / (hz > 0 ? hz : 1);
    if (ticks >= per_window) {
      PowerReport report;
      if (g_ct_ok && ct_window_finish(window, &report)) {
        report.t_ms = now;
        report.seq = seq++;
        portENTER_CRITICAL(&g_mail_mux);
        g_mail = report;  // loop가 못 가져갔으면 덮어쓴다(최신 값 우선, seq로 빠짐이 보인다)
        g_mail_full = true;
        portEXIT_CRITICAL(&g_mail_mux);
      }
      ct_window_reset(&window);
      ticks = 0;
    }
    esp_task_wdt_reset();
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
  }
}

int poll_host() {
  int budget = HOST_LINE_MAX;
  int got = 0;
  while (budget-- > 0 && Serial.available() > 0) {
    const int c = Serial.read();
    if (c < 0) break;
    ++got;
    if (c == '\n') {
      if (!g_overflow && g_len > 0) {
        g_line[g_len] = '\0';
        g_last_host_ms = millis();
        g_silence_tripped = false;
        proto_handle_line(g_line, g_len);
      }
      g_len = 0;
      g_overflow = false;
    } else if (c == '\r') {
      continue;
    } else if (g_len < HOST_LINE_MAX) {
      g_line[g_len++] = static_cast<char>(c);
    } else {
      g_overflow = true;
    }
  }
  return got;
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
  cfg.idle_core_mask = (1u << 0);
  cfg.trigger_panic = true;
  if (esp_task_wdt_reconfigure(&cfg) == ESP_ERR_INVALID_STATE) esp_task_wdt_init(&cfg);
  esp_task_wdt_add(nullptr);
}

bool start_sampling() {
  g_task = xTaskCreateStaticPinnedToCore(sample_task, "outlet_smp", SAMPLE_TASK_STACK, nullptr,
                                         SAMPLE_TASK_PRIORITY, g_stack, &g_tcb, SAMPLE_TASK_CORE);
  if (g_task == nullptr) return false;
  esp_timer_create_args_t args = {};
  args.callback = on_sample_timer;
  args.name = "outlet_smp";
  if (esp_timer_create(&args, &g_timer) != ESP_OK) return false;
  return esp_timer_start_periodic(g_timer, SAMPLE_PERIOD_US) == ESP_OK;
}

void flush_events() {
  uint32_t estop_t = 0;
  if (outlet_take_estop_event(&estop_t)) proto_event_estop(estop_t);

  PowerReport report;
  bool have = false;
  portENTER_CRITICAL(&g_mail_mux);
  if (g_mail_full) {
    report = g_mail;
    g_mail_full = false;
    have = true;
  }
  portEXIT_CRITICAL(&g_mail_mux);
  if (have) proto_event_power(report, outlet_snapshot().relay_on);

#if HOST_SILENCE_RELAY_OFF
  if (!g_silence_tripped && millis() - g_last_host_ms >= HOST_SILENCE_MS) {
    g_silence_tripped = true;
    if (outlet_host_silence_off()) proto_event_host_timeout();
  }
#endif
}

}  // namespace

void setup() {
  outlet_init();  // 릴레이를 가장 먼저 꺼짐으로 고정한다
  Serial.setRxBufferSize(HOST_RX_BUFFER_BYTES);
  Serial.setTxBufferSize(HOST_TX_BUFFER_BYTES);
  Serial.begin(HOST_SERIAL_BAUD);
  g_ct_ok = ct_init();
  setup_task_watchdog();
  const bool sampling_ok = start_sampling();
  g_last_host_ms = millis();
  proto_event_ready(reset_reason_name(), g_ct_ok);
  if (!g_ct_ok) proto_event_fault("ct_init");
  if (!sampling_ok) {
    // 샘플링 태스크가 없으면 버튼 차단도 없다 — 릴레이를 끈 채 두고 알린다. 호스트 relay_on은 켜 줄 수
    // 있으므로, 여기서는 재부팅으로 다시 시도하게 한다(태스크 워치독에 맡기지 않고 명시적으로).
    proto_event_fault("sampling_task");
    Serial.flush();
    esp_restart();
  }
}

void loop() {
  const int got = poll_host();
  flush_events();
  esp_task_wdt_reset();
  if (got == 0) vTaskDelay(1);
}
