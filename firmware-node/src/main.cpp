#include <Arduino.h>
#include <ArduinoJson.h>
#include <WiFi.h>

#include "config.h"
#include "act_uart.h"
#include "http_server.h"
#include "espnow_transport.h"

// ─── Emergency stop listener (STOP_PORT) ─────────────────────────────────────
// 이 포트로 들어온 "/stop" 요청 = 정지 요청. waitForActReply의 대기 루프에서도
// 폴링되므로 실행 중에도 정지가 통한다 — RPi4가 중단 후 pending sequence의
// error/result를 보내면 블로킹 중이던 /execute 핸들러가 그 결과로 마무리된다.
//
// 경로를 확인하는 이유: 이전에는 TCP 연결만으로 즉시 정지했는데, 시연장
// 공유 네트워크의 포트 스캔이나 오접속 한 번이 실행을 끊을 수 있었다.
// 다만 여전히 "덜 멈추는 것"이 더 위험하므로 인증까지 요구하지는 않는다 —
// 요청 라인을 못 읽었을 때는 안전하게 정지 쪽으로 판단한다.
static WiFiServer stopServer(STOP_PORT);

// 정지 요청 처리의 알맹이 — HTTP(STOP_PORT)와 ESP-NOW(정지 프레임)가 같이 쓴다.
static void sendAbortToAct(const char* via) {
    JsonDocument abortMsg;
    abortMsg["type"] = "abort";
    actUart.send(abortMsg);
    log_w("stop requested via %s - abort sent to RPi4", via);
}

static void pollStopServer() {
    if (ESPNOW_ENABLED) return;  // ESP-NOW 모드에서는 정지가 프레임으로 온다

    WiFiClient client = stopServer.accept();
    if (!client) return;

    // 요청 라인만 짧게 읽는다 (정지 경로를 오래 붙잡지 않기)
    char line[96] = "";
    size_t len = 0;
    uint32_t start = millis();
    while (client.connected() && millis() - start < 150 && len < sizeof(line) - 1) {
        if (!client.available()) continue;
        char c = static_cast<char>(client.read());
        if (c == '\r' || c == '\n') break;
        line[len++] = c;
    }
    line[len] = '\0';

    // 아무것도 못 읽었으면(len == 0) 판단 근거가 없다 → 안전하게 정지
    const bool isStop = (len == 0) || (strstr(line, "/stop") != nullptr);

    if (isStop) {
        sendAbortToAct("HTTP stop port");
        client.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                     "Connection: close\r\nContent-Length: 11\r\n\r\n{\"ok\":true}");
    } else {
        log_i("ignored non-stop request on :%d (%s)", STOP_PORT, line);
        client.print("HTTP/1.1 404 Not Found\r\nConnection: close\r\n"
                     "Content-Length: 0\r\n\r\n");
    }
    client.stop();
}

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
static bool waitForActReply(const char* seqId, bool& outSuccess, int& outRetry,
                            uint32_t timeoutMs) {
    strlcpy(pendingSeqId, seqId, sizeof(pendingSeqId));
    pendingActive = true;
    pendingHasReply = false;

    uint32_t start = millis();
    while (millis() - start < timeoutMs) {
        actUart.poll();
        pollStopServer();  // 실행 중에도 긴급 정지를 받는다 (STOP_PORT)
        if (ESPNOW_ENABLED && espNowTransport.stopRequested()) {
            // 수신 콜백이 세운 플래그 -- 폴링을 기다리지 않아 HTTP 경로보다 빠르다
            espNowTransport.clearStopRequest();
            sendAbortToAct("ESP-NOW stop frame");
        }
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

    // 버튼 수에 비례한 대기 — RPi5보다 먼저 포기해야 RPi5가 504를 받아
    // 정지까지 보낼 수 있다(고정 30s 시절엔 RPi5가 먼저 조용히 포기했다).
    uint32_t timeoutMs =
        ACT_BASE_TIMEOUT_MS + ACT_PER_BUTTON_TIMEOUT_MS * buttons.size();
    if (timeoutMs > ACT_MAX_TIMEOUT_MS) timeoutMs = ACT_MAX_TIMEOUT_MS;

    bool gotReply = waitForActReply(seqId, outSuccess, outRetry, timeoutMs);
    if (!gotReply) {
        // 우리가 포기해도 RPi4는 계속 누르고 있을 수 있다 — 504를 돌려주기
        // 전에 중단부터 시킨다(RPi5의 정지 요청을 기다리지 않는다).
        JsonDocument abortMsg;
        abortMsg["type"] = "abort";
        actUart.send(abortMsg);
        log_w("no RPi4 reply within %lums — abort sent",
              static_cast<unsigned long>(timeoutMs));
    }
    return gotReply;
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

    // 전송 계층 선택 -- 실행 로직(onExecute/onAlerts)은 양쪽에 그대로 넘어간다.
    // 자동 폴백을 두지 않는 것은 의도다: 어느 전송으로 도는지 모호하면 시연장에서
    // "왜 안 되는지"를 못 좁힌다(SIMPLELAY_ACT_MODE와 같은 원칙).
    if (ESPNOW_ENABLED) {
        espNowTransport.onExecute(onExecute);
        espNowTransport.onAlerts(onAlerts);
        espNowTransport.onStop([]() { sendAbortToAct("ESP-NOW stop frame"); });
        if (!espNowTransport.begin()) {
            log_e("ESP-NOW init failed - node is unreachable until fixed");
        }
    } else {
        httpServer.onExecute(onExecute);
        httpServer.onAlerts(onAlerts);
        httpServer.begin();
        stopServer.begin();
        log_i("stop listener on port %d", STOP_PORT);
    }

    digitalWrite(LED_PIN, LOW);  // init 완료
    log_i("Boot OK - transport=%s, Act UART listening",
          ESPNOW_ENABLED ? "ESP-NOW" : "HTTP");
}

void loop() {
    if (ESPNOW_ENABLED) {
        espNowTransport.poll();
    } else {
        httpServer.handleClient();
        pollStopServer();  // 유휴 중의 정지 요청도 응답해 준다 (RPi4가 무시하면 무해)
    }
    actUart.poll();  // pending 응답을 안 기다리는 동안에도 alert는 계속 흡수
    delay(2);
}
