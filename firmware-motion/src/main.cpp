// firmware-motion — RPi4 옆 모션 MCU(ESP32). **컴파일만 확인, 실물 미검증.**
//
// RPi4(rpi/controller/serial_motion.py) ─USB 시리얼, 줄 단위 JSON─ 이 보드
//   ─ JMOD-MOTOR-1(TB6612FNG) ×2 ─ FIT0482 ×3 (CoreXY A/B + Z 누름)
// 규약의 실행 가능한 기준은 rpi/tools/fake_mcu.py, 명령 표는 firmware-motion/protocol_table.json.
//
// 구조: loop()가 시리얼 바이트를 고정 버퍼로 모아 줄 단위로 처리하고, CONTROL_PERIOD_US마다
// motion_tick()을 돈다. 인터럽트 핸들러는 두지 않는다(엔코더 넘침 누적은 PCNT 드라이버 몫,
// 리밋 스위치는 폴링). 제어 루프에는 동적 할당이 없고 JSON 해석은 고정 풀을 쓴다.
#include <Arduino.h>

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
uint32_t g_next_tick_us = 0;

void poll_host() {
  int budget = HOST_LINE_MAX;  // 한 번에 너무 오래 붙잡지 않는다(제어 주기 보호)
  while (budget-- > 0 && Serial.available() > 0) {
    const int c = Serial.read();
    if (c < 0) break;
    if (c == '\n') {
      if (!g_overflow && g_len > 0) {
        g_line[g_len] = '\0';
        motion_note_host_line(millis());
        proto_handle_line(g_line, g_len);
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
}

}  // namespace

void setup() {
  Serial.setRxBufferSize(HOST_RX_BUFFER_BYTES);
  Serial.begin(HOST_SERIAL_BAUD);
  const bool hw_ok = drivers_init();
  motion_init(hw_ok);
  g_next_tick_us = micros();
}

void loop() {
  poll_host();
  const uint32_t now_us = micros();
  if (static_cast<int32_t>(now_us - g_next_tick_us) >= 0) {
    g_next_tick_us += CONTROL_PERIOD_US;
    // 크게 밀렸으면 따라잡으려 연속 실행하지 않고 기준을 다시 잡는다.
    if (static_cast<int32_t>(now_us - g_next_tick_us) > static_cast<int32_t>(CONTROL_PERIOD_US * 10)) {
      g_next_tick_us = now_us + CONTROL_PERIOD_US;
    }
    motion_tick(millis());
  }
}
