#include "sensor_reader.h"
#include "config.h"
#include <Arduino.h>

SensorReader sensorReader;

void SensorReader::begin() {
    // GPIO 36 (VP) is input-only ADC1_CH0 — no pinMode needed
    log_i("Sensor ADC stub ready (GPIO %d)", SENSOR_ADC_PIN);
}

void SensorReader::read(int& current_ma_out, int& sound_db_out) {
    // ACS712-05B on ADC1_CH0 (GPIO 36, 12-bit, 3.3 V reference)
    // Zero-current output = ACS712_ZERO_V (2.5 V)
    // Sensitivity = 185 mV/A → 1 A = 185 mV → 1 mA = 0.185 mV
    int raw = analogRead(SENSOR_ADC_PIN);
    float v = (float)raw * (ADC_VREF / ADC_MAX_RAW);
    float current_a = (v - ACS712_ZERO_V) / (ACS712_MV_PER_A / 1000.0f);
    current_ma_out = (int)(current_a * 1000.0f);

    // Sound dB: requires I2S microphone or separate ADC channel.
    // Phase C TODO: implement via I2S or INMP441.
    sound_db_out = 0;
}
