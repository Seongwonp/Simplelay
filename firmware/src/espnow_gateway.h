#pragma once

#include <ArduinoJson.h>
#include <functional>

#include "config.h"

// RPi5를 대신해 ESP-NOW를 쏴주는 게이트웨이 역할.
//
// 이 보드는 원래 폰 BLE 폴백 브릿지다. ESP-NOW는 ESP32 라디오끼리만 통하고 RPi5에는
// 그 라디오가 없어서, 이미 UART로 붙어 있는 이 보드가 겸한다(전용 보드를 추가하지
// 않는 대신 BLE와 Wi-Fi 라디오를 함께 쓴다 -- ESP32 coexistence).
//
//     RPi5 --UART--> (이 보드) --ESP-NOW--> 노드 ESP32 --UART--> RPi4
//
// 프레임 형식은 노드 쪽(firmware-node/src/espnow_transport.*)과 **정확히 같아야
// 한다**: 머리 4바이트 [msg_id][조각번호][조각수][종류] + 본문. 250바이트 상한
// 때문에 큰 요청은 쪼개 보낸다.
//
// 대기 시간은 계층마다 다르게 잡는다 -- 아래쪽이 먼저 포기해야 위쪽이 추측 대신
// 실제 오류를 받는다(노드 < 게이트웨이 < RPi5).
//
// **상관관계**: 실행 요청에 rid(=RPi5의 sequence_id)를 실어 보내고, 노드가 응답에
// 그대로 되돌려준다. 대기 중인 rid와 다른 응답은 버린다 -- 포기한 요청의 지연 응답이
// 다음 요청의 결과로 둔갑하면, 실패한 실행을 성공으로 보고하게 된다.
//
// **ACK·재전송은 일부러 넣지 않았다.** ESP-NOW 자체가 링크 계층 ACK와 재시도를
// 하고(esp_now_send의 송신 콜백으로 성공 여부도 알 수 있다), 그 위에 응용 계층
// 재전송을 얹으면 "같은 버튼을 두 번 누르는" 위험이 생긴다. 물리 버튼을 누르는
// 시스템에서 중복 실행은 유실보다 나쁘다 -- 유실은 위층 타임아웃이 오류로 알려주고
// 정지까지 보내지만, 중복은 아무도 모른다. 실기기에서 유실률이 문제가 되면
// 멱등성 키(rid 기반 중복 무시)를 노드에 먼저 넣고 나서 재전송을 검토한다.

// 노드 응답이 도착했을 때. success/retry는 응답이 정상일 때만 의미가 있다.
using NodeResultHandler =
    std::function<void(const char* sequenceId, bool success, int retry)>;

// 노드에 도달하지 못했거나 제때 응답이 없을 때. RPi5가 추측하지 않도록 이유를 준다.
using NodeErrorHandler =
    std::function<void(const char* sequenceId, const char* reason)>;

class EspNowGateway {
public:
    bool begin();

    // loop()에서 매번 호출 -- 재조립 완료 처리와 대기 타임아웃을 여기서 본다.
    void poll();

    // RPi5의 node_execute 처리. 전송까지만 하고 결과는 콜백으로 돌아온다.
    // 반환 false = 보내지도 못함(주소 오류·피어 등록 실패 등).
    bool sendExecute(const char* macText, const JsonArray& buttons,
                     const char* sequenceId);

    // RPi5의 node_stop 처리. 응답을 기다리지 않는다(정지는 best-effort).
    void sendStop(const char* macText);

    void onResult(NodeResultHandler cb) { _onResult = cb; }
    void onError(NodeErrorHandler cb) { _onError = cb; }

private:
    NodeResultHandler _onResult;
    NodeErrorHandler _onError;

    // ── 대기 중인 실행 ──
    // 시스템 전체가 한 번에 하나만 실행하므로(RPi5의 실행 락) 하나만 추적한다.
    bool _pending = false;
    char _pendingSeqId[64] = "";
    uint8_t _pendingMac[6] = {0};
    uint32_t _pendingDeadlineMs = 0;

    // ── 수신 재조립 ──
    uint8_t _buffer[ESPNOW_MAX_MESSAGE_BYTES];
    size_t _bufferLen = 0;
    uint8_t _msgId = 0;
    uint8_t _fragCount = 0;
    uint32_t _fragsSeenMask = 0;
    uint32_t _firstFragMs = 0;
    bool _assembling = false;
    volatile bool _messageReady = false;
    size_t _readyLen = 0;

    // ── 피어 관리 ──
    uint8_t _peers[ESPNOW_MAX_PEERS][6] = {};
    size_t _peerCount = 0;

    bool _ensurePeer(const uint8_t* mac);
    bool _sendFramed(const uint8_t* mac, uint8_t kind, const uint8_t* payload,
                     size_t len);
    void _handleFrame(const uint8_t* mac, const uint8_t* data, int len);
    void _dispatchReady();
    void _resetAssembly();
    void _failPending(const char* reason);

    friend void espnowGatewayRecvBridge(const uint8_t* mac, const uint8_t* data,
                                        int len);
};

// MAC 문자열("AA:BB:CC:DD:EE:FF")을 바이트 6개로. 형식이 틀리면 false.
bool parseMacText(const char* text, uint8_t out[6]);

extern EspNowGateway espNowGateway;
