// 원작: 팀원(서예솔) Touch Bridge CoreXY 펌웨어 v3, SimpleLay용으로 통신·이름 수정
// (이 파일은 원작 그대로 — 머리말 두 줄만 더함. 2026-10-10 수령, 실물 미검증)
// TB6612FNG 한 채널 (JMOD-MOTOR-1의 A 또는 B)
//   IN1  IN2  PWM  -> 동작
//    H    L    H      정회전
//    L    H    H      역회전
//    H/L  L/H  L      쇼트 브레이크
//    H    H    x      쇼트 브레이크
#pragma once
#include <Arduino.h>
#include <esp_arduino_version.h>
#include "config.h"

class Tb6612Motor {
public:
  Tb6612Motor(int pinPwm, int pinIn1, int pinIn2, uint8_t ledcCh, bool invert)
    : pwm_(pinPwm), in1_(pinIn1), in2_(pinIn2), ch_(ledcCh), invert_(invert) {}

  void begin() {
    pinMode(in1_, OUTPUT);
    pinMode(in2_, OUTPUT);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
    ledcAttach(pwm_, PWM_FREQ_HZ, PWM_RES_BITS);
#else
    ledcSetup(ch_, PWM_FREQ_HZ, PWM_RES_BITS);
    ledcAttachPin(pwm_, ch_);
#endif
    brake();
  }

  // u: -1.0 ~ 1.0 (부호 = 방향, 크기 = 듀티)
  void set(float u) {
    if (invert_) u = -u;
    if (u > 1.0f) u = 1.0f;
    if (u < -1.0f) u = -1.0f;
    uint32_t duty = (uint32_t)(fabsf(u) * PWM_MAX + 0.5f);
    if (duty == 0) { brake(); return; }
    digitalWrite(in1_, u > 0 ? HIGH : LOW);
    digitalWrite(in2_, u > 0 ? LOW : HIGH);
    writeDuty(duty);
  }

  void brake() {
    digitalWrite(in1_, HIGH);
    digitalWrite(in2_, HIGH);
    writeDuty(0);
  }

private:
  void writeDuty(uint32_t d) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
    ledcWrite(pwm_, d);
#else
    ledcWrite(ch_, d);
#endif
  }

  const int pwm_, in1_, in2_;
  const uint8_t ch_;
  const bool invert_;
};
