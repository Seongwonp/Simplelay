#pragma once

#include <WebServer.h>
#include <ArduinoJson.h>

#include "transport.h"

// RPi5가 이 노드를 부르는 dev-mode 전송 계층 — rpi/services/esp_node_controller.py
// 의 EspNodeController가 클라이언트, 여기가 서버. POST /execute만 있으면 되고
// (RPi4가 한 번에 하나의 시퀀스만 처리하므로 동시 요청 처리 불필요), GET /alerts
// 는 RPi4가 자체발신하는 위험소리 알림을 폴링으로 읽어갈 수 있게 얹어둔 것.
//
// 본선 데모 전송은 espnow_transport.*가 맡는다. 콜백 계약(transport.h)이 같아서
// main.cpp의 실행 로직은 양쪽 어디에도 묶여 있지 않다.

class HttpServer {
public:
    HttpServer();

    void begin();
    void handleClient();  // loop()에서 매번 호출

    void onExecute(ExecuteHandler cb) { _onExecute = cb; }
    void onAlerts(AlertsHandler cb) { _onAlerts = cb; }

private:
    WebServer _server;
    ExecuteHandler _onExecute;
    AlertsHandler _onAlerts;

    void _handleExecuteRequest();
    void _handleAlertsRequest();
    void _handleNotFound();
};

extern HttpServer httpServer;
