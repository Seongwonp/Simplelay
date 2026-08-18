#include "http_server.h"
#include "config.h"
#include <Arduino.h>
#include <WiFi.h>

HttpServer httpServer;

HttpServer::HttpServer() : _server(HTTP_PORT) {}

void HttpServer::begin() {
    WiFi.mode(WIFI_STA);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
    log_i("Connecting to WiFi SSID=%s ...", WIFI_SSID);
    while (WiFi.status() != WL_CONNECTED) {
        delay(300);
        Serial.print(".");
    }
    log_i("WiFi connected — IP=%s", WiFi.localIP().toString().c_str());

    _server.on("/execute", HTTP_POST, [this]() { _handleExecuteRequest(); });
    _server.on("/alerts", HTTP_GET, [this]() { _handleAlertsRequest(); });
    _server.onNotFound([this]() { _handleNotFound(); });
    _server.begin();
    log_i("HTTP server listening on port %d", HTTP_PORT);
}

void HttpServer::handleClient() {
    _server.handleClient();
}

void HttpServer::_handleExecuteRequest() {
    if (!_server.hasArg("plain")) {
        _server.send(400, "application/json", "{\"error\":\"missing body\"}");
        return;
    }

    JsonDocument in;
    if (deserializeJson(in, _server.arg("plain")) != DeserializationError::Ok) {
        _server.send(400, "application/json", "{\"error\":\"invalid json\"}");
        return;
    }

    JsonArray buttons = in["buttons"].as<JsonArray>();
    if (buttons.isNull() || buttons.size() == 0) {
        _server.send(400, "application/json", "{\"error\":\"buttons must not be empty\"}");
        return;
    }

    if (!_onExecute) {
        _server.send(500, "application/json", "{\"error\":\"no execute handler registered\"}");
        return;
    }

    bool success = false;
    int retry = 0;
    bool gotReply = _onExecute(buttons, success, retry);
    if (!gotReply) {
        // rpi/services/esp_node_controller.py's EspNodeController raises
        // EspNodeError on any non-200 -- 504 reads clearly as "the node
        // couldn't reach its RPi4 in time", distinct from a 400 (our fault)
        // or a 500 (this ESP32's own fault).
        _server.send(504, "application/json", "{\"error\":\"no response from RPi4\"}");
        return;
    }

    JsonDocument out;
    out["success"] = success;
    out["retry"] = retry;
    String body;
    serializeJson(out, body);
    _server.send(200, "application/json", body);
}

void HttpServer::_handleAlertsRequest() {
    JsonDocument out;
    out["active"] = false;
    if (_onAlerts) _onAlerts(out);

    String body;
    serializeJson(out, body);
    _server.send(200, "application/json", body);
}

void HttpServer::_handleNotFound() {
    _server.send(404, "application/json", "{\"error\":\"not found\"}");
}
