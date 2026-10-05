#pragma once
// CT 입력 — ADS1115(I2C 차동, 단발 변환 돌려 읽기) 또는 ESP32 내장 ADC. config.h OUTLET_CT_SOURCE가 고른다.
// 채널 수는 OUTLET_CT_CHANNELS(2026-10-06: 전자레인지 ch0 + 세탁기 ch1). 샘플 한 점은 마이크로볼트(µV) 정수다.
// 실효값·전력 환산은 ct_window_finish가 채널마다 그 채널의 보정값(config.h *_CH 표)으로 한다.
#include <stdint.h>

#include "config.h"

// 초기화. 실패(ADS1115 무응답 등)면 false — 호스트에 fault 이벤트를 보내고 power 이벤트를 내지 않는다.
bool ct_init();
// "ads1115" | "adc"
const char* ct_source_name();

// 창 하나의 누적값(채널 하나). 샘플링 태스크만 쓴다.
struct CtWindow {
  int64_t sum_uv;
  int64_t sum_sq_uv;  // µV² 합. ADS 최대 ±2.048 V(2.05e6 µV)² × 250 샘플 ≈ 1.1e15 < 9.2e18
  uint32_t n;
  uint32_t read_errors;
};

// 이번 틱의 CT 읽기. ADS1115: 지난 틱에 시작한 변환(채널 하나)을 읽어 그 채널 창에 넣고 다음 채널 변환을
// 시작한다. 내장 ADC: 모든 채널을 한 점씩 읽는다. 판독 실패는 그 채널 창의 read_errors로 센다.
void ct_sample_tick(CtWindow windows[OUTLET_CT_CHANNELS]);
// 창 하나(ticks 틱) 동안 채널 하나가 받을 것으로 기대하는 샘플 수.
uint32_t ct_expected_samples(uint32_t ticks);

struct PowerReport {
  uint8_t ch;          // CT 채널(0 = 전자레인지·릴레이 채널, 1 = 세탁기 — 배선 가정, 호스트가 가전에 잇는다)
  uint32_t t_ms;       // 창이 끝난 시각(millis)
  uint32_t seq;        // 채널별 보고 번호(부팅 뒤 0부터)
  float ct_mv_rms;     // DC(창 평균)를 뺀 CT 출력 실효값(mV)
  float irms_a;        // 보정 배율·잡음 바닥 적용 뒤 전류 추정(A rms)
  float watts;         // irms × MAINS_VRMS_EST × 채널 역률 — 추정값
  uint32_t n;          // 창의 샘플 수
  uint32_t read_errors;
};

void ct_window_reset(CtWindow* w);
void ct_window_add(CtWindow* w, int32_t uv);
// 창을 보고값으로 바꾼다(ch의 보정값 사용). 샘플이 하나도 없으면 false(보고하지 않는다 — 0 W를 지어내지 않는다).
bool ct_window_finish(const CtWindow& w, uint8_t ch, PowerReport* out);
