#pragma once

// ─── BLE ───────────────────────────────────────────────────────────────────
#define BLE_DEVICE_NAME   "SimpleLay-ESP32"
#define BLE_SERVICE_UUID  "0000FFE0-0000-1000-8000-00805F9B34FB"
#define BLE_CHAR_UUID     "0000FFE1-0000-1000-8000-00805F9B34FB"
#define BLE_MTU           512

// ─── UART (Serial2) → RPi5 ────────────────────────────────────────────────
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
// Sensor sample interval sent to RPi5 (ms)
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

// ─── ESP-NOW 게이트웨이 (본선 데모 전송) ────────────────────────────────────
// 이 보드는 폰 BLE 폴백 브릿지이면서 동시에 ESP-NOW 게이트웨이 역할을 겸한다.
// RPi5는 ESP-NOW 라디오가 없어서 직접 쏠 수 없기 때문:
//     RPi5 --UART--> (이 보드) --ESP-NOW--> 노드 ESP32 --UART--> RPi4
// 겸용이라 BLE와 Wi-Fi 라디오를 함께 쓴다(ESP32 coexistence). 전용 보드로
// 분리하려면 이 값만 0으로 두고 새 보드에서 1로 켜면 된다.
#define ESPNOW_GATEWAY_ENABLED    0

// 노드와 반드시 같아야 하는 값들 (firmware-node/include/config.h와 짝)
#define ESPNOW_CHANNEL            1
#define ESPNOW_FRAME_HEADER_BYTES 4
#define ESPNOW_MAX_FRAME_BYTES    250
#define ESPNOW_MAX_PAYLOAD_BYTES  (ESPNOW_MAX_FRAME_BYTES - ESPNOW_FRAME_HEADER_BYTES)
#define ESPNOW_MAX_MESSAGE_BYTES  1280
#define ESPNOW_REASSEMBLY_TIMEOUT_MS 3000

// 동시에 등록해 둘 수 있는 노드 수 (가전 수)
#define ESPNOW_MAX_PEERS          8

// 응답 대기 상한. **계층마다 달라야 한다** — 아래쪽이 먼저 포기해야 위쪽이
// 추측 대신 실제 오류를 받는다:
//     노드(20s + 6s/버튼) < 게이트웨이(25s + 6s/버튼) < RPi5(30s + 6s/버튼)
#define ESPNOW_GW_BASE_TIMEOUT_MS      25000
#define ESPNOW_GW_PER_BUTTON_TIMEOUT_MS 6000
