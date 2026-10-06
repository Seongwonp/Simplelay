#include "ct.h"

#include <Arduino.h>
#include <Wire.h>
#include <math.h>

#include "config.h"

namespace {

// 채널별 보정(config.h *_CH 표, 전부 측정 필요). 쓰는 것은 앞의 OUTLET_CT_CHANNELS칸.
constexpr float kAmpsPerVolt[OUTLET_CT_MAX_CHANNELS] = CT_AMPS_PER_VOLT_CH;
constexpr float kCalGain[OUTLET_CT_MAX_CHANNELS] = CT_CAL_GAIN_CH;
constexpr float kNoiseFloorA[OUTLET_CT_MAX_CHANNELS] = CT_NOISE_FLOOR_A_CH;
constexpr float kPowerFactor[OUTLET_CT_MAX_CHANNELS] = POWER_FACTOR_EST_CH;

}  // namespace

#if OUTLET_CT_SOURCE == OUTLET_CT_ADS1115

namespace {

constexpr uint8_t kMux[OUTLET_CT_MAX_CHANNELS] = ADS1115_MUX_CH;

// 쓰는 채널의 MUX가 서로 달라야 한다(같으면 두 채널이 같은 CT를 읽는다).
constexpr bool mux_distinct(int i = 0, int j = 1) {
  return i >= OUTLET_CT_CHANNELS ? true
         : j >= OUTLET_CT_CHANNELS ? mux_distinct(i + 1, i + 2)
         : (kMux[i] != kMux[j] && kMux[i] <= 0x7 && mux_distinct(i, j + 1));
}
static_assert(mux_distinct(), "ADS1115_MUX_CH: 쓰는 채널의 MUX 값이 겹치거나 범위(0~7) 밖이다");

// 변환 중인 채널(-1 = 없음)과 다음에 시작할 채널, 끝나기를 기다린 틱 수. 샘플링 태스크만 쓴다.
int g_pending = -1;
int g_next = 0;
int g_wait_ticks = 0;

// 변환이 끝나기를 기다리는 최대 틱 수. 860 SPS 한 변환은 약 1.16 ms(내부 발진기 ±10%면 1.28 ms)라 2 ms 틱이면
// 보통 다음 틱에 끝난다. 이만큼 넘으면 판독 실패로 센다(MUX는 바꾸지 않는다 — 측정 필요).
constexpr int kMaxWaitTicks = 3;

// 설정 레지스터의 MUX(14:12)로 실제로 변환한 채널을 찾는다(쓰는 채널 밖이면 -1).
int channel_for_mux(uint16_t cfg) {
  const uint8_t mux = static_cast<uint8_t>((cfg >> 12) & 0x7);
  for (int ch = 0; ch < OUTLET_CT_CHANNELS; ++ch) {
    if ((kMux[ch] & 0x7) == mux) return ch;
  }
  return -1;
}

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

uint16_t config_for(int ch) {
  return static_cast<uint16_t>(ADS1115_CONFIG_BASE | (static_cast<uint16_t>(kMux[ch] & 0x7) << 12));
}

}  // namespace

bool ct_init() {
  if (!Wire.begin(PIN_I2C_SDA, PIN_I2C_SCL, ADS1115_I2C_HZ)) return false;
  // 채널 0으로 변환을 하나 시작하고 설정이 들어갔는지 되읽는다. OS 비트(15)는 읽을 때 '변환 중 아님'을 뜻해
  // 다를 수 있다 — 나머지만 비교한다.
  const uint16_t cfg = config_for(0);
  if (!ads_write_reg(0x01, cfg)) return false;
  uint16_t readback = 0;
  if (!ads_read_reg(0x01, &readback)) return false;
  if ((readback & 0x7FFF) != (cfg & 0x7FFF)) return false;
  g_pending = 0;
  g_next = OUTLET_CT_CHANNELS > 1 ? 1 : 0;
  return true;
}

void ct_sample_tick(CtWindow windows[OUTLET_CT_CHANNELS]) {
  // ① 지난 틱에 시작한 변환을 읽는다(2026-10-06 평가 A3).
  //    - 아직 변환 중(OS=0)이면 **새 변환을 시작하지 않고** 이 틱을 건너뛴다. 단발 모드에서 변환 중에 설정을 쓰면
  //      OS=1은 무시되고 MUX만 바뀌어, 끝난 값이 다음 채널 창에 들어갈 수 있었다.
  //    - 끝났으면 설정 레지스터의 MUX로 실제로 변환한 채널을 찾아 그 창에 넣는다. 시작할 때 기록과 다르면 버린다.
  if (g_pending >= 0) {
    uint16_t cfg = 0;
    const bool cfg_ok = ads_read_reg(0x01, &cfg);
    if (!cfg_ok || (cfg & 0x8000) == 0) {
      if (++g_wait_ticks <= kMaxWaitTicks) return;  // 아직 변환 중(또는 I2C 일시 오류) — 기다린다
      // 너무 오래 — 판독 실패로 센다. 설정 판독도 못 하면(버스 오류) 버리고 새로 시작한다. 변환 중이면 계속 기다린다.
      ++windows[g_pending].read_errors;
      g_wait_ticks = 0;
      if (cfg_ok) return;
      g_pending = -1;
    } else {
      const int converted = channel_for_mux(cfg);
      uint16_t raw = 0;
      if (converted == g_pending && ads_read_reg(0x00, &raw)) {
        const int16_t counts = static_cast<int16_t>(raw);
        ct_window_add(&windows[converted],
                      static_cast<int32_t>(lroundf(static_cast<float>(counts) * ADS1115_UV_PER_LSB)));
      } else {
        ++windows[g_pending].read_errors;  // 다른 채널 값이거나 판독 실패 — 어느 창에도 넣지 않는다
      }
      g_pending = -1;
      g_wait_ticks = 0;
    }
  }
  // ② 다음 채널 변환을 시작한다(앞 변환이 끝난 뒤에만 여기 온다). 쓰기 실패는 그 채널 판독 실패로 세고
  //    다음 틱에 그다음 채널로 넘어간다.
  const int ch = g_next;
  g_next = (g_next + 1) % OUTLET_CT_CHANNELS;
  if (ads_write_reg(0x01, config_for(ch))) {
    g_pending = ch;
  } else {
    ++windows[ch].read_errors;
  }
}

uint32_t ct_expected_samples(uint32_t ticks) { return ticks / OUTLET_CT_CHANNELS; }

const char* ct_source_name() { return "ads1115"; }

#else  // OUTLET_CT_ESP32_ADC

namespace {
constexpr uint8_t kPins[OUTLET_CT_ADC_MAX_CHANNELS] = PIN_CT_ADC_CH;
}  // namespace

bool ct_init() {
  analogReadResolution(12);
  for (int ch = 0; ch < OUTLET_CT_CHANNELS; ++ch) analogSetPinAttenuation(kPins[ch], ADC_11db);
  return true;  // 내장 ADC는 응답 확인 수단이 없다 — 값이 이상하면 호스트 기록에서 드러난다
}

void ct_sample_tick(CtWindow windows[OUTLET_CT_CHANNELS]) {
  // 공장 보정(eFuse)을 쓰는 mV 판독. 비선형·잡음은 보정 전이다(측정 필요). 채널 사이 시차는 수십 µs.
  for (int ch = 0; ch < OUTLET_CT_CHANNELS; ++ch) {
    ct_window_add(&windows[ch], static_cast<int32_t>(analogReadMilliVolts(kPins[ch])) * 1000);
  }
}

uint32_t ct_expected_samples(uint32_t ticks) { return ticks; }

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

bool ct_window_finish(const CtWindow& w, uint8_t ch, PowerReport* out) {
  if (w.n == 0 || ch >= OUTLET_CT_CHANNELS) return false;
  const double n = static_cast<double>(w.n);
  const double mean = static_cast<double>(w.sum_uv) / n;
  double var = static_cast<double>(w.sum_sq_uv) / n - mean * mean;  // DC(바이어스) 제거 = 분산
  if (var < 0.0) var = 0.0;
  const double v_rms = sqrt(var) / 1e6;  // V
  double amps = v_rms * kAmpsPerVolt[ch] * kCalGain[ch];
  // 잡음 바닥은 직교 성분으로 뺀다(잡음과 부하 전류가 무상관이라는 가정, 측정 필요). 기본 0 = 빼지 않음.
  const double floor_a = kNoiseFloorA[ch];
  amps = amps > floor_a ? sqrt(amps * amps - floor_a * floor_a) : 0.0;
  out->ch = ch;
  out->ct_mv_rms = static_cast<float>(v_rms * 1000.0);
  out->irms_a = static_cast<float>(amps);
  out->watts = static_cast<float>(amps * MAINS_VRMS_EST * kPowerFactor[ch]);
  out->n = w.n;
  out->read_errors = w.read_errors;
  return true;
}
