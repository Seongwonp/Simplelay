#include "ct.h"

#include <Arduino.h>
#include <Wire.h>
#include <math.h>

#include "config.h"

#if OUTLET_CT_SOURCE == OUTLET_CT_ADS1115

namespace {

bool ads_write_reg(uint8_t reg, uint16_t value) {
  Wire.beginTransmission(ADS1115_ADDR);
  Wire.write(reg);
  Wire.write(static_cast<uint8_t>(value >> 8));
  Wire.write(static_cast<uint8_t>(value & 0xFF));
  return Wire.endTransmission() == 0;
}

bool ads_read_reg(uint8_t reg, uint16_t* out) {
  Wire.beginTransmission(ADS1115_ADDR);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(static_cast<uint8_t>(ADS1115_ADDR), static_cast<uint8_t>(2)) != 2) return false;
  const uint8_t hi = Wire.read();
  const uint8_t lo = Wire.read();
  *out = static_cast<uint16_t>((hi << 8) | lo);
  return true;
}

}  // namespace

bool ct_init() {
  if (!Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, ADS1115_I2C_HZ)) return false;
  if (!ads_write_reg(0x01, ADS1115_CONFIG)) return false;
  uint16_t readback = 0;
  // OS 비트(15)는 읽을 때 '변환 중 아님'을 뜻해 다를 수 있다 — 나머지만 비교한다.
  if (!ads_read_reg(0x01, &readback)) return false;
  return (readback & 0x7FFF) == (ADS1115_CONFIG & 0x7FFF);
}

bool ct_read_uv(int32_t* out_uv) {
  uint16_t raw = 0;
  if (!ads_read_reg(0x00, &raw)) return false;
  const int16_t counts = static_cast<int16_t>(raw);
  *out_uv = static_cast<int32_t>(lroundf(static_cast<float>(counts) * ADS1115_UV_PER_LSB));
  return true;
}

const char* ct_source_name() { return "ads1115"; }

#else  // OUTLET_CT_ESP32_ADC

bool ct_init() {
  analogReadResolution(12);
  analogSetPinAttenuation(PIN_CT_ADC, ADC_11db);
  return true;  // 내장 ADC는 응답 확인 수단이 없다 — 값이 이상하면 호스트 기록에서 드러난다
}

bool ct_read_uv(int32_t* out_uv) {
  // 공장 보정(eFuse)을 쓰는 mV 판독. 비선형·잡음은 보정 전이다(측정 필요).
  *out_uv = static_cast<int32_t>(analogReadMilliVolts(PIN_CT_ADC)) * 1000;
  return true;
}

const char* ct_source_name() { return "adc"; }

#endif

void ct_window_reset(CtWindow* w) {
  w->sum_uv = 0;
  w->sum_sq_uv = 0;
  w->n = 0;
  w->read_errors = 0;
}

void ct_window_add(CtWindow* w, int32_t uv) {
  w->sum_uv += uv;
  w->sum_sq_uv += static_cast<int64_t>(uv) * uv;
  ++w->n;
}

bool ct_window_finish(const CtWindow& w, PowerReport* out) {
  if (w.n == 0) return false;
  const double n = static_cast<double>(w.n);
  const double mean = static_cast<double>(w.sum_uv) / n;
  double var = static_cast<double>(w.sum_sq_uv) / n - mean * mean;  // DC(바이어스) 제거 = 분산
  if (var < 0.0) var = 0.0;
  const double v_rms = sqrt(var) / 1e6;  // V
  double amps = v_rms * CT_AMPS_PER_VOLT * CT_CAL_GAIN;
  // 잡음 바닥은 직교 성분으로 뺀다(잡음과 부하 전류가 무상관이라는 가정, 측정 필요). 기본 0 = 빼지 않음.
  const double floor_a = CT_NOISE_FLOOR_A;
  amps = amps > floor_a ? sqrt(amps * amps - floor_a * floor_a) : 0.0;
  out->ct_mv_rms = static_cast<float>(v_rms * 1000.0);
  out->irms_a = static_cast<float>(amps);
  out->watts = static_cast<float>(amps * MAINS_VRMS_EST * POWER_FACTOR_EST);
  out->n = w.n;
  out->read_errors = w.read_errors;
  return true;
}
