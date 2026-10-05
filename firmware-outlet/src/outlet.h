#pragma once
// 릴레이·비상정지 상태. 샘플링 태스크(버튼 차단)와 loop 태스크(호스트 명령)가 함께 쓰므로
// 상태 변경과 릴레이 핀 쓰기는 한 임계구역(portMUX) 안에서만 한다.
#include <stdint.h>

void outlet_init();

// 샘플링 태스크가 매 틱 부른다. 버튼이 ESTOP_TRIP_SAMPLES 연속 활성이면 **그 자리에서** 릴레이를 연다
// (호스트 응답을 기다리지 않는다). 새로 걸렸으면 true(이벤트는 loop가 보낸다).
bool outlet_poll_estop(uint32_t now_ms);

// 호스트 명령. 반환값은 오류 코드(성공이면 nullptr).
const char* outlet_relay_on();   // 비상정지가 걸려 있으면 "estop_latched"
void outlet_relay_off();
const char* outlet_estop_reset();  // 버튼이 아직 활성이면 "estop_active"
// 호스트 침묵 정책(HOST_SILENCE_RELAY_OFF). 릴레이를 열었으면 true.
bool outlet_host_silence_off();

struct OutletSnapshot {
  bool relay_on;
  bool estop_latched;
  bool button_active;  // 지금 버튼 판독(디바운스 전 즉시값)
  uint32_t estop_t_ms;  // 마지막으로 걸린 시각(없으면 0)
};
OutletSnapshot outlet_snapshot();

// 걸린 뒤 아직 호스트에 알리지 않은 비상정지가 있으면 true를 돌려주고 표시를 지운다.
bool outlet_take_estop_event(uint32_t* t_ms);
