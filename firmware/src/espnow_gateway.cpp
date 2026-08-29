#include "espnow_gateway.h"

#include <Arduino.h>
#include <WiFi.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <string.h>

EspNowGateway espNowGateway;

static constexpr size_t kHdr = ESPNOW_FRAME_HEADER_BYTES;

// 노드 쪽 EspNowFrameKind와 같은 값이어야 한다
static constexpr uint8_t kKindExecute = 0;
static constexpr uint8_t kKindResponse = 2;
static constexpr uint8_t kKindStop = 3;

bool parseMacText(const char* text, uint8_t out[6]) {
    if (text == nullptr) return false;
    unsigned int b[6];
    if (sscanf(text, "%x:%x:%x:%x:%x:%x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) {
        return false;
    }
    for (int i = 0; i < 6; ++i) {
        if (b[i] > 0xFF) return false;
        out[i] = static_cast<uint8_t>(b[i]);
    }
    return true;
}

void espnowGatewayRecvBridge(const uint8_t* mac, const uint8_t* data, int len) {
    espNowGateway._handleFrame(mac, data, len);
}

// 콜백 시그니처가 Arduino-ESP32 코어 3.x에서 바뀌었다(mac -> recv_info).
#if ESP_ARDUINO_VERSION_MAJOR >= 3
static void onDataRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
    espnowGatewayRecvBridge(info->src_addr, data, len);
}
#else
static void onDataRecv(const uint8_t* mac, const uint8_t* data, int len) {
    espnowGatewayRecvBridge(mac, data, len);
}
#endif

bool EspNowGateway::begin() {
    // BLE가 이미 떠 있는 상태에서 Wi-Fi를 올린다(coexistence). AP에는 붙지 않는다 --
    // 공유기를 거치지 않는 것이 ESP-NOW를 쓰는 이유이기 때문.
    WiFi.mode(WIFI_STA);
    WiFi.disconnect();
    esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);

    if (esp_now_init() != ESP_OK) {
        log_e("esp_now_init failed");
        return false;
    }
    esp_now_register_recv_cb(onDataRecv);
    log_i("ESP-NOW gateway ready on channel %d, own MAC %s",
          ESPNOW_CHANNEL, WiFi.macAddress().c_str());
    return true;
}

bool EspNowGateway::_ensurePeer(const uint8_t* mac) {
    for (size_t i = 0; i < _peerCount; ++i) {
        if (memcmp(_peers[i], mac, 6) == 0) return true;
    }
    if (_peerCount >= ESPNOW_MAX_PEERS) {
        log_e("peer table full (%d) -- cannot add another node", ESPNOW_MAX_PEERS);
        return false;
    }
    esp_now_peer_info_t peer = {};
    memcpy(peer.peer_addr, mac, 6);
    peer.channel = ESPNOW_CHANNEL;
    peer.encrypt = false;
    if (esp_now_add_peer(&peer) != ESP_OK) {
        log_e("esp_now_add_peer failed");
        return false;
    }
    memcpy(_peers[_peerCount], mac, 6);
    ++_peerCount;
    return true;
}

bool EspNowGateway::_sendFramed(const uint8_t* mac, uint8_t kind,
                                const uint8_t* payload, size_t len) {
    static uint8_t outMsgId = 0;
    ++outMsgId;

    const size_t fragCount =
        (len + ESPNOW_MAX_PAYLOAD_BYTES - 1) / ESPNOW_MAX_PAYLOAD_BYTES;
    if (fragCount == 0 || fragCount > 32) {
        log_e("payload too large to fragment (%u bytes)", (unsigned)len);
        return false;
    }

    uint8_t frame[ESPNOW_MAX_FRAME_BYTES];
    for (size_t i = 0; i < fragCount; ++i) {
        const size_t offset = i * ESPNOW_MAX_PAYLOAD_BYTES;
        const size_t chunk = min(ESPNOW_MAX_PAYLOAD_BYTES, len - offset);

        frame[0] = outMsgId;
        frame[1] = static_cast<uint8_t>(i);
        frame[2] = static_cast<uint8_t>(fragCount);
        frame[3] = kind;
        memcpy(frame + kHdr, payload + offset, chunk);

        if (esp_now_send(mac, frame, kHdr + chunk) != ESP_OK) {
            log_e("esp_now_send failed on fragment %u/%u", (unsigned)(i + 1),
                  (unsigned)fragCount);
            return false;
        }
        if (fragCount > 1) delay(2);  // 노드 수신 큐가 넘치지 않게
    }
    return true;
}

bool EspNowGateway::sendExecute(const char* macText, const JsonArray& buttons,
                                const char* sequenceId) {
    uint8_t mac[6];
    if (!parseMacText(macText, mac)) {
        log_e("bad node address: %s", macText ? macText : "(null)");
        return false;
    }
    if (!_ensurePeer(mac)) return false;

    JsonDocument out;
    JsonArray arr = out["buttons"].to<JsonArray>();
    size_t buttonCount = 0;
    for (JsonVariant v : buttons) {
        arr.add(v.as<const char*>());
        ++buttonCount;
    }

    uint8_t body[ESPNOW_MAX_MESSAGE_BYTES];
    const size_t len = serializeJson(out, body, sizeof(body));
    if (len == 0) {
        log_e("execute payload did not fit");
        return false;
    }
    if (!_sendFramed(mac, kKindExecute, body, len)) return false;

    _pending = true;
    strlcpy(_pendingSeqId, sequenceId, sizeof(_pendingSeqId));
    memcpy(_pendingMac, mac, 6);
    _pendingDeadlineMs = millis() + ESPNOW_GW_BASE_TIMEOUT_MS +
                         ESPNOW_GW_PER_BUTTON_TIMEOUT_MS * buttonCount;
    return true;
}

void EspNowGateway::sendStop(const char* macText) {
    uint8_t mac[6];
    if (!parseMacText(macText, mac) || !_ensurePeer(mac)) return;
    const uint8_t empty[] = "{}";
    _sendFramed(mac, kKindStop, empty, sizeof(empty) - 1);
}

void EspNowGateway::_resetAssembly() {
    _assembling = false;
    _bufferLen = 0;
    _fragCount = 0;
    _fragsSeenMask = 0;
}

void EspNowGateway::_handleFrame(const uint8_t* mac, const uint8_t* data, int len) {
    if (len < static_cast<int>(kHdr)) return;
    // 대기 중인 노드가 아닌 곳에서 온 프레임은 무시한다
    if (!_pending || memcmp(mac, _pendingMac, 6) != 0) return;
    if (data[3] != kKindResponse) return;

    const uint8_t msgId = data[0];
    const uint8_t fragIndex = data[1];
    const uint8_t fragCount = data[2];
    if (fragCount == 0 || fragIndex >= fragCount || fragCount > 32) return;
    if (_messageReady) return;

    if (!_assembling || msgId != _msgId) {
        _resetAssembly();
        _assembling = true;
        _msgId = msgId;
        _fragCount = fragCount;
        _firstFragMs = millis();
    }

    const size_t payloadLen = static_cast<size_t>(len) - kHdr;
    const size_t offset = static_cast<size_t>(fragIndex) * ESPNOW_MAX_PAYLOAD_BYTES;
    if (offset + payloadLen > ESPNOW_MAX_MESSAGE_BYTES) {
        _resetAssembly();
        return;
    }
    memcpy(_buffer + offset, data + kHdr, payloadLen);
    _fragsSeenMask |= (1UL << fragIndex);
    if (offset + payloadLen > _bufferLen) _bufferLen = offset + payloadLen;

    const uint32_t complete = (fragCount >= 32) ? 0xFFFFFFFFUL
                                                : ((1UL << fragCount) - 1UL);
    if (_fragsSeenMask == complete) {
        _readyLen = _bufferLen;
        _messageReady = true;
        _assembling = false;
    }
}

void EspNowGateway::_failPending(const char* reason) {
    if (!_pending) return;
    _pending = false;
    if (_onError) _onError(_pendingSeqId, reason);
}

void EspNowGateway::poll() {
    if (_assembling && (millis() - _firstFragMs) > ESPNOW_REASSEMBLY_TIMEOUT_MS) {
        log_w("gateway reassembly timed out -- discarded");
        _resetAssembly();
    }

    if (_messageReady) {
        _dispatchReady();
        return;
    }

    // 노드가 아예 응답하지 않는 경우. RPi5보다 먼저 포기해서 추측 대신 오류를 준다.
    if (_pending && static_cast<int32_t>(millis() - _pendingDeadlineMs) >= 0) {
        _failPending("node did not respond");
    }
}

void EspNowGateway::_dispatchReady() {
    JsonDocument in;
    const DeserializationError err = deserializeJson(in, _buffer, _readyLen);
    _messageReady = false;
    _bufferLen = 0;

    if (!_pending) return;

    if (err != DeserializationError::Ok) {
        _failPending("unparseable node response");
        return;
    }
    if (in["error"].is<const char*>()) {
        _pending = false;
        if (_onError) _onError(_pendingSeqId, in["error"].as<const char*>());
        return;
    }

    _pending = false;
    if (_onResult) {
        _onResult(_pendingSeqId, in["success"] | false, in["retry"] | 0);
    }
}
