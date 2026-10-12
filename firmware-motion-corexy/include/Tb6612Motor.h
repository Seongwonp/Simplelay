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

  // SimpleLay 수정(2026-10-12): 코어 3.x에서도 채널을 명시적으로 고정한다. 자동 배정(ledcAttach)은
  // 먼저 붙은 솔레노이드(8비트)와 같은 타이머를 나눠 B 출력이 나오지 않는 일이 실기기에서 있었다.
  // 붙이기에 실패하면 false — 호출부가 hw_init으로 거절한다.
  bool begin() {
    pinMode(in1_, OUTPUT);
    pinMode(in2_, OUTPUT);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
    const bool ok = ledcAttachChannel(pwm_, PWM_FREQ_HZ, PWM_RES_BITS, ch_);
#else
    ledcSetup(ch_, PWM_FREQ_HZ, PWM_RES_BITS);
    ledcAttachPin(pwm_, ch_);
    const bool ok = true;
#endif
    brake();
    return ok;
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
