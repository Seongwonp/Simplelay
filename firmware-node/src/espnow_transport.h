#pragma once

#include <Arduino.h>
#include <ArduinoJson.h>
#include <esp_now.h>
#include <freertos/FreeRTOS.h>

#include <atomic>

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

// 재조립 버퍼를 지금 누가 만질 차례인가.
//
// 수신 콜백(_handleFrame)은 **Wi-Fi 태스크**에서, poll()/_dispatchReady()는
// **Arduino loop 태스크**에서 돈다 -- ESP32는 듀얼코어라 둘이 다른 코어에서 동시에
// 실행될 수 있다. 예전에는 `volatile bool _messageReady` 하나로 이 경계를 표현했는데,
// volatile은 원자성도 메모리 순서도 보장하지 않는다.
//
// 더 큰 문제는 소유 구간이었다. _dispatchReady()가 맨 앞에서 버퍼를 "비었다"고
// 표시한 뒤 실행 핸들러를 부르는데, 그 핸들러는 RPi4 응답을 최대 수십 초 기다린다.
// 그동안 수신부는 자유롭게 _buffer를 덮어썼고, ArduinoJson은 이 버퍼를 **zero-copy로
// 참조**하므로(비-const 버퍼를 넘기면 문자열이 버퍼를 직접 가리킨다) 지금 누르고 있는
// 버튼 라벨이 실행 도중에 바뀔 수 있었다.
//
// 그래서 "비었다/찼다"가 아니라 소유자를 상태로 명시한다. 처리가 끝나야 Idle로
// 돌아가고, 그 전까지 수신부는 새 프레임을 버린다(어차피 한 번에 한 요청만 다룬다).
enum class RxState : uint8_t {
    Idle,         // 수신부가 새 메시지를 시작할 수 있다
    Assembling,   // 수신부가 조각을 채우는 중
    Ready,        // 완성 -- loop가 가져갈 차례
    Dispatching,  // loop가 처리 중(실행 핸들러가 오래 블로킹할 수 있다)
};

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

    // 정지 요청을 **한 번만** 꺼내 간다(가져가면서 지운다).
    //
    // 이전에는 확인과 소거가 나뉘어 있었고 poll()이 소거하지 않아서, 실행 중이
    // 아닐 때 정지 프레임이 한 번 오면 매 loop마다 abort를 계속 내보냈다 --
    // UART를 포화시키고 다음 실행을 반복 중단시킬 수 있었다. 소비 지점이
    // 둘(대기 루프·poll)이므로 "확인하면서 지우는" 하나의 연산으로 합친다.
    //
    // 그 "하나의 연산"이 실제로 원자적이어야 한다. 읽고-쓰는 사이에 수신 콜백이
    // 새 정지를 세우면 그 정지가 지워져 사라진다 -- **놓친 긴급 정지**이므로 이
    // 프로젝트에서 가장 비싼 종류의 경쟁이다. exchange로 한 번에 처리한다.
    bool takeStopRequest() { return _stopRequested.exchange(false); }

private:
    ExecuteHandler _onExecute;
    AlertsHandler _onAlerts;
    StopHandler _onStop;

    // ── 재조립 상태 ──
    // 한 번에 한 메시지만 재조립한다. RPi4가 어차피 시퀀스를 하나씩만 처리하므로
    // 노드가 동시에 두 요청을 다룰 일이 없다 -- 여러 메시지를 병행 재조립하는
    // 복잡도를 일부러 지지 않았다.
    //
    // 아래 필드는 전부 _mux가 지킨다. 임계구역은 짧게 유지하고, 그 안에서 로그·
    // 핸들러·delay를 절대 부르지 않는다(스핀락이라 그동안 다른 코어가 멈춘다).
    portMUX_TYPE _mux = portMUX_INITIALIZER_UNLOCKED;
    RxState _rxState = RxState::Idle;

    uint8_t _buffer[ESPNOW_MAX_MESSAGE_BYTES];
    size_t _bufferLen = 0;
    uint8_t _msgId = 0;
    uint8_t _fragCount = 0;
    uint32_t _fragsSeenMask = 0;  // 32조각까지 추적 (= 최대 약 7.8KB, 상한보다 넉넉)
    uint32_t _firstFragMs = 0;

    // 방금 처리를 끝낸 메시지. 뒤늦게 도착한 그 메시지의 조각이 새 재조립을
    // 시작해버리면, 정작 진짜 새 메시지가 "다른 msgId"로 밀려 버려진다.
    uint8_t _lastDoneMsgId = 0;
    uint32_t _lastDoneMs = 0;
    bool _hasLastDone = false;

    EspNowFrameKind _readyKind = EspNowFrameKind::ExecuteRequest;
    size_t _readyLen = 0;

    std::atomic<bool> _stopRequested{false};

    // 요청에 실려 온 식별자. 응답에 그대로 되돌려 게이트웨이가 "이 답이 어느 요청의
    // 것인지" 확인할 수 있게 한다. 없으면 지연 응답이 다음 요청 결과로 잘못 쓰인다.
    char _currentRid[48] = "";

    void _handleFrame(const uint8_t* data, int len);
    void _dispatchReady();   // _dispatchMessage 후 버퍼를 수신부에 돌려준다
    void _dispatchMessage();
    void _resetAssemblyLocked();  // 반드시 _mux를 쥔 채로 부를 것
    bool _sendMessage(EspNowFrameKind kind, const uint8_t* payload, size_t len);
    void _sendJson(JsonDocument& doc);  // rid를 찍어 보내므로 const 아님

    // 수신 콜백에서 인스턴스로 들어오는 통로 (ESP-NOW 콜백은 자유 함수여야 함)
    friend void espnowRecvBridge(const uint8_t* data, int len);
};

extern EspNowTransport espNowTransport;
