#pragma once

#include <WebServer.h>
#include <ArduinoJson.h>
#include <functional>

// RPi5가 이 노드를 부르는 dev-mode 전송 계층 — rpi/services/esp_node_controller.py
// 의 EspNodeController가 클라이언트, 여기가 서버. POST /execute만 있으면 되고
// (RPi4가 한 번에 하나의 시퀀스만 처리하므로 동시 요청 처리 불필요), GET /alerts
// 는 RPi4가 자체발신하는 위험소리 알림을 폴링으로 읽어갈 수 있게 얹어둔 것.
//
// 프로덕션(본선 데모) 전송은 ESP-NOW로 갈 예정 — 그때 이 클래스는 그대로 두고
// 별도의 EspNowTransport류를 새로 만들어 갈아끼우면 된다(양쪽 다 동일한
// ExecuteHandler/AlertsHandler 콜백 계약을 쓰면 main.cpp는 손댈 필요 없음).

// buttons를 실행하고 완료까지 기다린다. 반환값 true = RPi4로부터 응답을 받음
// (성공이든 실패든 -- outSuccess/outRetry에 실림). false = 응답을 못 받음
// (타임아웃/전송 실패) -- 호출부가 504로 변환한다.
using ExecuteHandler = std::function<bool(const JsonArray& buttons, bool& outSuccess, int& outRetry)>;

// 최근 alert 상태를 out에 채워 넣는다 (active/kind/band_energy_ratio/
// mean_period_seconds) -- rpi/api/schemas.py의 AlertResponse와 같은 모양.
using AlertsHandler = std::function<void(JsonDocument& out)>;

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
