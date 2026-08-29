#pragma once

#include <ArduinoJson.h>
#include <esp_now.h>

#include "config.h"
#include "transport.h"

// 본선 데모용 전송 계층.
//
// 왜 ESP-NOW인가: 시연장 공유 Wi-Fi가 혼잡해도 영향을 받지 않아야 한다. ESP-NOW는
// 공유기를 아예 거치지 않고 라디오끼리 직접 주고받는다.
//
// 토폴로지 -- ESP-NOW는 ESP32 라디오끼리만 통하므로 RPi5도 게이트웨이가 필요하다:
//     RPi5 --UART--> ESP32 게이트웨이 --ESP-NOW--> 이 노드 --UART--> RPi4
//
// HTTP 경로와 다른 점 두 가지가 구현의 대부분이다:
//
// 1. **한 프레임 250바이트 상한.** 상한(버튼 20개 × 라벨 40자)의 최악 본문이 약
//    2.5KB라 한 번에 안 들어간다 -- 한글이 UTF-8 3바이트라 글자 수로 세면 3배
//    과소평가한다. 그래서 조각내어 보내고 이쪽에서 다시 붙인다. HTTP엔 없던
//    문제라 "전송만 갈아끼우면 된다"가 여기서는 성립하지 않는다.
// 2. **포트가 없다.** HTTP는 긴급 정지를 별도 포트로 분리했지만(단일 스레드
//    WebServer가 실행 처리 중 새 연결을 못 받으므로), 여기서는 프레임 종류로
//    구분한다. 수신은 콜백이라 실행 대기 중에도 도착한다 -- 오히려 폴링보다 낫다.

enum class EspNowFrameKind : uint8_t {
    ExecuteRequest = 0,
    AlertsRequest = 1,
    Response = 2,
    StopRequest = 3,
};

class EspNowTransport {
public:
    // 게이트웨이와 통신 준비. 실패하면 false -- 호출부가 HTTP로 후퇴할 수 있게
    // 예외 대신 반환값으로 알린다.
    bool begin();

    // loop()에서 매번 호출. 수신 콜백은 Wi-Fi 태스크에서 도는 짧은 구간이라
    // 거기서는 버퍼에 담기만 하고, 실제 처리(JSON 파싱·핸들러 호출)는 여기서 한다.
    void poll();

    void onExecute(ExecuteHandler cb) { _onExecute = cb; }
    void onAlerts(AlertsHandler cb) { _onAlerts = cb; }
    void onStop(StopHandler cb) { _onStop = cb; }

    // 실행 대기 루프가 이걸 확인해 중간에 빠져나온다. 정지 프레임은 수신 콜백에서
    // 곧바로 플래그를 세우므로, 실행이 진행 중이어도 즉시 반영된다.
    bool stopRequested() const { return _stopRequested; }
    void clearStopRequest() { _stopRequested = false; }

private:
    ExecuteHandler _onExecute;
    AlertsHandler _onAlerts;
    StopHandler _onStop;

    // ── 재조립 상태 ──
    // 한 번에 한 메시지만 재조립한다. RPi4가 어차피 시퀀스를 하나씩만 처리하므로
    // 노드가 동시에 두 요청을 다룰 일이 없다 -- 여러 메시지를 병행 재조립하는
    // 복잡도를 일부러 지지 않았다.
    uint8_t _buffer[ESPNOW_MAX_MESSAGE_BYTES];
    size_t _bufferLen = 0;
    uint8_t _msgId = 0;
    uint8_t _fragCount = 0;
    uint32_t _fragsSeenMask = 0;  // 32조각까지 추적 (= 최대 약 7.8KB, 상한보다 넉넉)
    uint32_t _firstFragMs = 0;
    bool _assembling = false;

    // 완성된 메시지를 poll()이 가져갈 때까지 보관
    volatile bool _messageReady = false;
    EspNowFrameKind _readyKind = EspNowFrameKind::ExecuteRequest;
    size_t _readyLen = 0;

    volatile bool _stopRequested = false;

    void _handleFrame(const uint8_t* data, int len);
    void _dispatchReady();
    void _resetAssembly();
    bool _sendMessage(EspNowFrameKind kind, const uint8_t* payload, size_t len);
    void _sendJson(const JsonDocument& doc);

    // 수신 콜백에서 인스턴스로 들어오는 통로 (ESP-NOW 콜백은 자유 함수여야 함)
    friend void espnowRecvBridge(const uint8_t* data, int len);
};

extern EspNowTransport espNowTransport;
