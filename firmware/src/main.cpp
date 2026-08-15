#include <Arduino.h>
#include <ArduinoJson.h>

#include "config.h"
#include "ble_bridge.h"
#include "rpi_uart.h"
#include "sensor_reader.h"
#include "estop.h"

// Current in-flight sequence ID (empty string = none).
static char activeSeqId[64] = "";

static uint32_t lastSensorMs = 0;

// ─── Helpers ────────────────────────────────────────────────────────────────

static void notifyApp(JsonDocument& doc) { bleServer.notify(doc); }
static void sendRpi(JsonDocument& doc)   { rpiUart.send(doc); }

// ─── BLE message handler (App → ESP32) ──────────────────────────────────────
//
// Implements:
//   command       → forward to RPi4 as `intent`
//   confirm       → forward to RPi4 as `confirm`
//   emergency_stop→ set estopTriggered (handled in loop)
//
static void onBleMessage(const JsonDocument& doc) {
    const char* type = doc["type"] | "";

    if (strcmp(type, "command") == 0) {
        JsonDocument out;
        out["type"] = "intent";
        out["text"] = doc["text"] | "";
        // Uptime in seconds; replace with Unix time if RTC is added later.
        out["timestamp"] = static_cast<unsigned long>(millis() / 1000UL);
        sendRpi(out);

    } else if (strcmp(type, "confirm") == 0) {
        JsonDocument out;
        out["type"] = "confirm";
        out["sequence_id"] = doc["sequence_id"] | "";
        out["approved"] = doc["approved"] | false;
        sendRpi(out);

    } else if (strcmp(type, "emergency_stop") == 0) {
        // ISR pattern: set flag, let loop() dispatch cleanly.
        estopTriggered = true;
    }
}

// ─── RPi4 UART message handler (RPi4 → ESP32) ───────────────────────────────
//
// Implements:
//   sequence → forward to App as `suggestion`
//   result   → forward to App as `result`
//   sensor   → forward to App as `sensor` (RPi4 aggregated sensor data)
//   abort    → cancel active sequence, notify App
//
static void onRpiMessage(const JsonDocument& doc) {
    const char* type = doc["type"] | "";

    if (strcmp(type, "sequence") == 0) {
        const char* id = doc["id"] | "";
        strlcpy(activeSeqId, id, sizeof(activeSeqId));

        JsonDocument out;
        out["type"] = "suggestion";
        out["sequence_id"] = id;
        out["label"] = doc["label"] | "";
        JsonArray stepsOut = out["steps"].to<JsonArray>();
        for (JsonVariant v : doc["buttons"].as<JsonArray>()) {
            stepsOut.add(v.as<const char*>());
        }
        notifyApp(out);

    } else if (strcmp(type, "result") == 0) {
        JsonDocument out;
        out["type"] = "result";
        out["sequence_id"] = doc["sequence_id"] | activeSeqId;
        out["success"] = doc["success"] | false;
        notifyApp(out);
        activeSeqId[0] = '\0';

    } else if (strcmp(type, "sensor") == 0) {
        // RPi4 can push aggregated sensor data for the App to display.
        JsonDocument out;
        out["type"] = "sensor";
        out["current_ma"] = doc["current_ma"] | 0;
        out["sound_db"] = doc["sound_db"] | 0;
        out["status"] = doc["status"] | "idle";
        out["completed_steps"] = doc["completed_steps"] | 0;
        notifyApp(out);

    } else if (strcmp(type, "abort") == 0) {
        JsonDocument out;
        out["type"] = "result";
        out["sequence_id"] = activeSeqId;
        out["success"] = false;
        notifyApp(out);
        activeSeqId[0] = '\0';
    }
}

// ─── E-STOP dispatch (called from loop, not ISR) ────────────────────────────

static void handleEstop() {
    estopTriggered = false;
    log_e("E-STOP triggered");

    // 1. Notify RPi4 to abort execution.
    JsonDocument rpiMsg;
    rpiMsg["type"] = "abort";
    sendRpi(rpiMsg);

    // 2. Notify App so the UI can update.
    JsonDocument appMsg;
    appMsg["type"] = "result";
    appMsg["sequence_id"] = activeSeqId;
    appMsg["success"] = false;
    appMsg["aborted"] = true;
    notifyApp(appMsg);

    activeSeqId[0] = '\0';

    // Visual feedback: rapid LED blink.
    for (int i = 0; i < 6; i++) {
        digitalWrite(LED_PIN, HIGH);
        delay(100);
        digitalWrite(LED_PIN, LOW);
        delay(100);
    }
}

// ─── Periodic sensor log (ESP32 ADC → RPi4 + App) ───────────────────────────

static void maybeSendSensorLog() {
    uint32_t now = millis();
    if (now - lastSensorMs < SENSOR_INTERVAL_MS) return;
    lastSensorMs = now;

    int current_ma, sound_db;
    sensorReader.read(current_ma, sound_db);

    JsonDocument out;
    out["type"] = "sensor_log";
    out["current_ma"] = current_ma;
    out["sound_db"] = sound_db;
    sendRpi(out);
}

// ─── Arduino entry points ────────────────────────────────────────────────────

void setup() {
    Serial.begin(115200);   // debug only; does not conflict with Serial2
    log_i("SimpleLay ESP32 booting...");

    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, HIGH);   // LED on during init

    estopBegin();
    sensorReader.begin();

    rpiUart.onMessage(onRpiMessage);
    rpiUart.begin();

    bleServer.onMessage(onBleMessage);
    bleServer.begin();

    digitalWrite(LED_PIN, LOW);    // init complete
    log_i("Boot OK — BLE advertising, Serial2 listening");
}

void loop() {
    if (estopTriggered) handleEstop();
    rpiUart.poll();
    maybeSendSensorLog();
    delay(10);
}
