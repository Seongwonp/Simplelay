#include "espnow_transport.h"

#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <string.h>

EspNowTransport espNowTransport;

static const uint8_t kGatewayMac[6] = ESPNOW_GATEWAY_MAC;

// 프레임 머리 4바이트: [msg_id][frag_index][frag_count][kind]
// 나머지가 조각 본문. 길이는 수신 콜백이 알려주므로 따로 싣지 않는다.
static constexpr size_t kHdr = ESPNOW_FRAME_HEADER_BYTES;

// ESP-NOW 수신 콜백은 자유 함수여야 해서 전역 인스턴스로 넘긴다.
void espnowRecvBridge(const uint8_t* data, int len) {
    espNowTransport._handleFrame(data, len);
}

// 콜백 시그니처가 Arduino-ESP32 코어 3.x에서 바뀌었다(mac -> recv_info).
// 어느 쪽으로 빌드되든 돌아가게 둘 다 둔다.
#if ESP_ARDUINO_VERSION_MAJOR >= 3
static void onDataRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
    (void)info;
    espnowRecvBridge(data, len);
}
#else
static void onDataRecv(const uint8_t* mac, const uint8_t* data, int len) {
    (void)mac;
    espnowRecvBridge(data, len);
}
#endif

bool EspNowTransport::begin() {
    WiFi.mode(WIFI_STA);
    WiFi.disconnect();  // AP에 붙지 않는다 -- 공유기를 거치지 않는 것이 목적

    // 양쪽 채널이 같아야 통신된다. AP가 채널을 정해주지 않으므로 직접 고정한다.
    esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);

    if (esp_now_init() != ESP_OK) {
        log_e("esp_now_init failed");
        return false;
    }
    esp_now_register_recv_cb(onDataRecv);

    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, kGatewayMac, 6);
    peer.channel = ESPNOW_CHANNEL;
    peer.encrypt = false;
    if (esp_now_add_peer(&peer) != ESP_OK) {
        log_e("could not add gateway peer -- check ESPNOW_GATEWAY_MAC");
        return false;
    }

    log_i("ESP-NOW ready on channel %d, own MAC %s",
          ESPNOW_CHANNEL, WiFi.macAddress().c_str());
    return true;
}

void EspNowTransport::_resetAssembly() {
    _assembling = false;
    _bufferLen = 0;
    _fragCount = 0;
    _fragsSeenMask = 0;
}

// Wi-Fi 태스크에서 도는 짧은 구간 -- 담기만 하고 무거운 일은 poll()로 넘긴다.
void EspNowTransport::_handleFrame(const uint8_t* data, int len) {
    if (len < static_cast<int>(kHdr)) return;

    const uint8_t msgId = data[0];
    const uint8_t fragIndex = data[1];
    const uint8_t fragCount = data[2];
    const auto kind = static_cast<EspNowFrameKind>(data[3]);

    // 정지는 재조립을 기다리지 않고 즉시 반영한다 -- 실행 대기 중에 도착하는 것이
    // 정상이고, 그때 늦으면 정지의 의미가 없다.
    if (kind == EspNowFrameKind::StopRequest) {
        _stopRequested = true;
        return;
    }

    if (fragCount == 0 || fragIndex >= fragCount || fragCount > 32) return;

    // 앞 메시지를 아직 처리 못 했으면 새 메시지를 받지 않는다(덮어써서 섞이는 것 방지)
    if (_messageReady) return;

    const bool isNewMessage = !_assembling || msgId != _msgId;
    if (isNewMessage) {
        _resetAssembly();
        _assembling = true;
        _msgId = msgId;
        _fragCount = fragCount;
        _firstFragMs = millis();
    }

    const size_t payloadLen = static_cast<size_t>(len) - kHdr;
    const size_t offset = static_cast<size_t>(fragIndex) * ESPNOW_MAX_PAYLOAD_BYTES;
    if (offset + payloadLen > ESPNOW_MAX_MESSAGE_BYTES) {
        log_w("message exceeds reassembly buffer -- dropped");
        _resetAssembly();
        return;
    }

    memcpy(_buffer + offset, data + kHdr, payloadLen);
    _fragsSeenMask |= (1UL << fragIndex);
    // 마지막 조각만 길이가 짧을 수 있으므로 끝 위치를 최대값으로 갱신한다
    if (offset + payloadLen > _bufferLen) _bufferLen = offset + payloadLen;

    const uint32_t complete = (fragCount >= 32) ? 0xFFFFFFFFUL
                                                : ((1UL << fragCount) - 1UL);
    if (_fragsSeenMask == complete) {
        _readyKind = kind;
        _readyLen = _bufferLen;
        _messageReady = true;
        _assembling = false;
    }
}

void EspNowTransport::poll() {
    // 조각이 유실돼 영영 안 오는 메시지가 버퍼를 붙잡지 않게 한다
    if (_assembling && (millis() - _firstFragMs) > ESPNOW_REASSEMBLY_TIMEOUT_MS) {
        log_w("reassembly timed out (msg %u) -- discarded", _msgId);
        _resetAssembly();
    }

    if (_stopRequested && _onStop) {
        _onStop();
        // 플래그는 실행 대기 루프도 보므로 여기서 지우지 않는다.
        // 소비한 쪽이 clearStopRequest()를 부른다.
    }

    if (_messageReady) _dispatchReady();
}

void EspNowTransport::_dispatchReady() {
    JsonDocument in;
    const DeserializationError err = deserializeJson(in, _buffer, _readyLen);

    // 처리 여부와 무관하게 다음 메시지를 받을 수 있게 먼저 비운다
    _messageReady = false;
    _bufferLen = 0;

    if (err != DeserializationError::Ok) {
        log_w("could not parse message: %s", err.c_str());
        JsonDocument out;
        out["error"] = "invalid json";
        _sendJson(out);
        return;
    }

    if (_readyKind == EspNowFrameKind::AlertsRequest) {
        JsonDocument out;
        out["active"] = false;
        if (_onAlerts) _onAlerts(out);
        _sendJson(out);
        return;
    }

    if (_readyKind != EspNowFrameKind::ExecuteRequest) return;

    JsonArray buttons = in["buttons"].as<JsonArray>();
    JsonDocument out;
    if (buttons.isNull() || buttons.size() == 0) {
        out["error"] = "buttons must not be empty";
        _sendJson(out);
        return;
    }
    if (!_onExecute) {
        out["error"] = "no execute handler registered";
        _sendJson(out);
        return;
    }

    bool success = false;
    int retry = 0;
    const bool gotReply = _onExecute(buttons, success, retry);
    if (!gotReply) {
        // HTTP 경로의 504와 같은 뜻 -- RPi4에서 제때 응답이 오지 않았다.
        out["error"] = "no response from RPi4";
    } else {
        out["success"] = success;
        out["retry"] = retry;
    }
    _sendJson(out);
}

void EspNowTransport::_sendJson(const JsonDocument& doc) {
    uint8_t body[ESPNOW_MAX_MESSAGE_BYTES];
    const size_t len = serializeJson(doc, body, sizeof(body));
    if (len == 0) {
        log_e("response did not fit in send buffer");
        return;
    }
    _sendMessage(EspNowFrameKind::Response, body, len);
}

bool EspNowTransport::_sendMessage(EspNowFrameKind kind, const uint8_t* payload,
                                   size_t len) {
    static uint8_t outMsgId = 0;
    ++outMsgId;

    const size_t fragCount =
        (len + ESPNOW_MAX_PAYLOAD_BYTES - 1) / ESPNOW_MAX_PAYLOAD_BYTES;
    if (fragCount == 0 || fragCount > 32) {
        log_e("response too large to fragment (%u bytes)", (unsigned)len);
        return false;
    }

    uint8_t frame[ESPNOW_MAX_FRAME_BYTES];
    for (size_t i = 0; i < fragCount; ++i) {
        const size_t offset = i * ESPNOW_MAX_PAYLOAD_BYTES;
        const size_t chunk = min(ESPNOW_MAX_PAYLOAD_BYTES, len - offset);

        frame[0] = outMsgId;
        frame[1] = static_cast<uint8_t>(i);
        frame[2] = static_cast<uint8_t>(fragCount);
        frame[3] = static_cast<uint8_t>(kind);
        memcpy(frame + kHdr, payload + offset, chunk);

        const esp_err_t rc = esp_now_send(kGatewayMac, frame, kHdr + chunk);
        if (rc != ESP_OK) {
            log_e("esp_now_send failed on fragment %u/%u", (unsigned)(i + 1),
                  (unsigned)fragCount);
            return false;
        }
        // 연속 전송 시 게이트웨이 쪽 수신 큐가 넘치지 않게 아주 짧게 띄운다
        if (fragCount > 1) delay(2);
    }
    return true;
}
