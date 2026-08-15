#pragma once

// ─── BLE ───────────────────────────────────────────────────────────────────
#define BLE_DEVICE_NAME   "SimpleLay-ESP32"
#define BLE_SERVICE_UUID  "0000FFE0-0000-1000-8000-00805F9B34FB"
#define BLE_CHAR_UUID     "0000FFE1-0000-1000-8000-00805F9B34FB"
#define BLE_MTU           512

// ─── UART (Serial2) → RPi4 ────────────────────────────────────────────────
// Serial2 default pins on FireBeetle WROOM-32
#define RPI_UART_BAUD    115200
#define RPI_UART_RX_PIN   16
#define RPI_UART_TX_PIN   17

// ─── Pins ──────────────────────────────────────────────────────────────────
// GPIO 33: E-STOP button (active-low; INPUT_PULLUP, 10 kΩ external also OK)
#define ESTOP_PIN         33
// GPIO 2: built-in status LED (FireBeetle WROOM-32)
#define LED_PIN            2
// GPIO 36: ADC1_CH0 (VP, input-only) — current sensor stub
#define SENSOR_ADC_PIN    36

// ─── Timing ────────────────────────────────────────────────────────────────
// Sensor sample interval sent to RPi4 (ms)
#define SENSOR_INTERVAL_MS  500
// JSON line buffer for UART and BLE
#define JSON_BUF_SIZE       512
// Max BLE notify payload (JSON serialised, must be <= negotiated MTU - 3)
#define NOTIFY_BUF_SIZE     509

// ─── ACS712-05B calibration (used by sensor_reader.cpp) ───────────────────
// Zero-current output voltage at 3.3 V supply (data-sheet: 2.5 V nominal)
#define ACS712_ZERO_V       2.5f
// mV per ampere sensitivity (05B variant: 185 mV/A)
#define ACS712_MV_PER_A   185.0f
// ESP32 ADC full-scale (12-bit, 3.3 V reference)
#define ADC_VREF            3.3f
#define ADC_MAX_RAW        4095
