// 원작: 팀원(서예솔) Touch Bridge CoreXY 펌웨어 v3, SimpleLay용으로 통신·이름 수정
// (이 파일은 원작 그대로 — 머리말 두 줄만 더함. 2026-10-10 수령, 실물 미검증)
// 쿼드러처 엔코더 (A/B 양 에지 인터럽트, x4 디코딩)
#pragma once
#include <Arduino.h>
#include "driver/gpio.h"

// 이전상태(AB) << 2 | 현재상태(AB) -> 증감. 잘못된 전이(노이즈)는 0
static const int8_t DRAM_ATTR kQuadTable[16] = {
   0, -1,  1,  0,
   1,  0,  0, -1,
  -1,  0,  0,  1,
   0,  1, -1,  0
};

class QuadEncoder;
static void quadEncoderIsr(void* arg);

class QuadEncoder {
public:
  QuadEncoder(int pinA, int pinB, bool invert)
    : pinA_(pinA), pinB_(pinB), invert_(invert) {}

  void begin() {
    pinMode(pinA_, INPUT_PULLUP);
    pinMode(pinB_, INPUT_PULLUP);
    state_ = readState();
    attachInterruptArg(digitalPinToInterrupt(pinA_), quadEncoderIsr, this, CHANGE);
    attachInterruptArg(digitalPinToInterrupt(pinB_), quadEncoderIsr, this, CHANGE);
  }

  int32_t read() {
    portENTER_CRITICAL(&mux_);
    int32_t c = count_;
    portEXIT_CRITICAL(&mux_);
    return invert_ ? -c : c;
  }

  void write(int32_t v) {
    portENTER_CRITICAL(&mux_);
    count_ = invert_ ? -v : v;
    portEXIT_CRITICAL(&mux_);
  }

private:
  friend void quadEncoderIsr(void* arg);

  uint8_t readState() {
    return (uint8_t)((gpio_get_level((gpio_num_t)pinA_) << 1) |
                      gpio_get_level((gpio_num_t)pinB_));
  }

  const int pinA_, pinB_;
  const bool invert_;
  volatile int32_t count_ = 0;
  volatile uint8_t state_ = 0;
  portMUX_TYPE mux_ = portMUX_INITIALIZER_UNLOCKED;
};

// ISR은 클래스 밖에 정의 (클래스 안 inline 정의 + IRAM_ATTR 조합은 xtensa 링크 오류)
static void IRAM_ATTR quadEncoderIsr(void* arg) {
  QuadEncoder* self = static_cast<QuadEncoder*>(arg);
  uint8_t s = (uint8_t)((gpio_get_level((gpio_num_t)self->pinA_) << 1) |
                         gpio_get_level((gpio_num_t)self->pinB_));
  portENTER_CRITICAL_ISR(&self->mux_);
  self->count_ += kQuadTable[(self->state_ << 2) | s];
  self->state_ = s;
  portEXIT_CRITICAL_ISR(&self->mux_);
}
