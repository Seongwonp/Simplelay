#include <Arduino.h>
#include <ArduinoJson.h>

#include "config.h"
#include "act_uart.h"
#include "http_server.h"

// ─── Pending execute() state ─────────────────────────────────────────────────
// waitForActReply()가 채우고 비운다 -- HTTP 핸들러 하나가 끝날 때까지 RPi4는
// 한 시퀀스만 처리하므로(act_executor.py의 _busy 가드) 동시에 두 개를 기다릴
// 일은 없다.
static char pendingSeqId[64] = "";
static bool pendingActive = false;
static bool pendingHasReply = false;
static bool pendingSuccess = false;
static int pendingRetry = 0;

// ─── Latest danger-sound alert state ─────────────────────────────────────────
// RPi4가 요청 없이 언제든 alert/alert_cleared를 보낼 수 있어서(docs/protocol.md),
// UART 콜백이 도착하는 대로 여기 저장해두고 GET /alerts가 그때그때 읽어간다 --
// rpi/services/alert_store.py의 DangerAlertStore와 같은 역할, ESP32판.
static bool alertActive = false;
static char alertKind[32] = "";
static float alertBandEnergyRatio = 0.0f;
static float alertMeanPeriodSeconds = 0.0f;
static bool alertHasPeriod = false;

static uint32_t seqCounter = 0;

// ─── RPi4 UART message handler ───────────────────────────────────────────────
static void onActMessage(const JsonDocument& doc) {
    const char* type = doc["type"] | "";

    if (strcmp(type, "result") == 0 || strcmp(type, "error") == 0) {
        if (!pendingActive) return;
        const char* seqId = doc["sequence_id"] | "";
        if (strcmp(seqId, pendingSeqId) != 0) return;  // 우리가 기다리는 게 아님

        pendingHasReply = true;
        pendingSuccess = (strcmp(type, "result") == 0) && (doc["success"] | false);
        pendingRetry = doc["retry"] | 0;

    } else if (strcmp(type, "alert") == 0) {
        alertActive = true;
        strlcpy(alertKind, doc["kind"] | "", sizeof(alertKind));
        alertBandEnergyRatio = doc["band_energy_ratio"] | 0.0f;
        if (!doc["mean_period_seconds"].isNull()) {
            alertMeanPeriodSeconds = doc["mean_period_seconds"];
            alertHasPeriod = true;
        } else {
            alertHasPeriod = false;
        }
        log_w("danger sound alert raised (kind=%s)", alertKind);

    } else if (strcmp(type, "alert_cleared") == 0) {
        alertActive = false;
        log_i("danger sound alert cleared");
    }
}

// 최대 ACT_RESPONSE_TIMEOUT_MS까지 RPi4의 result/error를 기다린다. HTTP 핸들러
// 하나를 이 시간만큼 블로킹하는 게 맞나 싶을 수 있는데, act_client.py의
// ActClientController도 동기 호출부를 똑같이 블로킹시키는 구조라 대칭이다 --
// 폐루프 재시도가 실제로 그만큼 걸릴 수 있다는 걸 그대로 반영한 것.
static bool waitForActReply(const char* seqId, bool& outSuccess, int& outRetry) {
    strlcpy(pendingSeqId, seqId, sizeof(pendingSeqId));
    pendingActive = true;
    pendingHasReply = false;

    uint32_t start = millis();
    while (millis() - start < ACT_RESPONSE_TIMEOUT_MS) {
        actUart.poll();
        if (pendingHasReply) {
            outSuccess = pendingSuccess;
            outRetry = pendingRetry;
            pendingActive = false;
            return true;
        }
        delay(5);
    }

    pendingActive = false;
    log_w("timed out waiting for RPi4 reply to sequence_id=%s", seqId);
    return false;
}

// ─── HttpServer callbacks ─────────────────────────────────────────────────────
static bool onExecute(const JsonArray& buttons, bool& outSuccess, int& outRetry) {
    char seqId[32];
    snprintf(seqId, sizeof(seqId), "node-%lu", static_cast<unsigned long>(++seqCounter));

    JsonDocument out;
    out["type"] = "execute";
    out["sequence_id"] = seqId;
    JsonArray buttonsOut = out["buttons"].to<JsonArray>();
    for (JsonVariant v : buttons) {
        buttonsOut.add(v.as<const char*>());
    }
    actUart.send(out);

    return waitForActReply(seqId, outSuccess, outRetry);
}

static void onAlerts(JsonDocument& out) {
    out["active"] = alertActive;
    if (alertActive) {
        out["kind"] = alertKind;
        out["band_energy_ratio"] = alertBandEnergyRatio;
        if (alertHasPeriod) {
            out["mean_period_seconds"] = alertMeanPeriodSeconds;
        } else {
            out["mean_period_seconds"] = nullptr;
        }
    }
}

// ─── Arduino entry points ────────────────────────────────────────────────────
void setup() {
    Serial.begin(115200);  // debug only; does not conflict with Serial2
    log_i("SimpleLay node ESP32 booting...");

    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, HIGH);  // init 중 LED 켜짐

    actUart.onMessage(onActMessage);
    actUart.begin();

    httpServer.onExecute(onExecute);
    httpServer.onAlerts(onAlerts);
    httpServer.begin();

    digitalWrite(LED_PIN, LOW);  // init 완료
    log_i("Boot OK — HTTP serving, Act UART listening");
}

void loop() {
    httpServer.handleClient();
    actUart.poll();  // pending 응답을 안 기다리는 동안에도 alert는 계속 흡수
    delay(2);
}
