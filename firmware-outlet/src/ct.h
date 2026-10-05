#pragma once
// CT 입력 — ADS1115(I2C 차동) 또는 ESP32 내장 ADC. config.h OUTLET_CT_SOURCE가 고른다.
// 샘플 한 점은 마이크로볼트(µV) 정수다. 실효값·전력 환산은 outlet_window_*가 창 단위로 한다.
#include <stdint.h>

// 초기화. 실패(ADS1115 무응답 등)면 false — 호스트에 fault 이벤트를 보내고 power 이벤트를 내지 않는다.
bool ct_init();
// CT 출력 한 점(µV). 읽기 실패면 false.
bool ct_read_uv(int32_t* out_uv);
// "ads1115" | "adc"
const char* ct_source_name();

// 창 하나의 누적값. 샘플링 태스크만 쓴다.
struct CtWindow {
  int64_t sum_uv;
  int64_t sum_sq_uv;  // µV² 합. ADS 최대 ±2.048 V(2.05e6 µV)² × 400 샘플 ≈ 1.7e15 < 9.2e18
  uint32_t n;
  uint32_t read_errors;
};

struct PowerReport {
  uint32_t t_ms;       // 창이 끝난 시각(millis)
  uint32_t seq;        // 보고 번호(부팅 뒤 0부터)
  float ct_mv_rms;     // DC(창 평균)를 뺀 CT 출력 실효값(mV)
  float irms_a;        // 보정 배율·잡음 바닥 적용 뒤 전류 추정(A rms)
  float watts;         // irms × MAINS_VRMS_EST × POWER_FACTOR_EST — 추정값
  uint32_t n;          // 창의 샘플 수
  uint32_t read_errors;
};

void ct_window_reset(CtWindow* w);
void ct_window_add(CtWindow* w, int32_t uv);
// 창을 보고값으로 바꾼다. 샘플이 하나도 없으면 false(보고하지 않는다 — 0 W를 지어내지 않는다).
bool ct_window_finish(const CtWindow& w, PowerReport* out);
