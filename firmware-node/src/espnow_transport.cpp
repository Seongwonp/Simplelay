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

void EspNowTransport::_resetAssemblyLocked() {
    _bufferLen = 0;
    _fragCount = 0;
    _fragsSeenMask = 0;
}

// 프레임 하나를 왜 버렸는지. 로그는 임계구역 밖에서 찍어야 해서 이유만 들고 나온다.
enum class FrameDrop : uint8_t {
    None = 0,
    Busy,          // 앞 메시지를 아직 처리 중
    OtherMessage,  // 다른 msgId -- 진행 중인 재조립을 뒤엎지 않는다
    Shape,         // 같은 msgId인데 조각 수/종류가 다르다 = 옛 프레임
    AlreadyDone,   // 방금 끝낸 메시지의 뒤늦은 조각
    OutOfRange,    // 버퍼 밖으로 나가는 조각
};

// Wi-Fi 태스크에서 도는 짧은 구간 -- 담기만 하고 무거운 일은 poll()로 넘긴다.
void EspNowTransport::_handleFrame(const uint8_t* data, int len) {
    if (len < static_cast<int>(kHdr)) return;

    const uint8_t msgId = data[0];
    const uint8_t fragIndex = data[1];
    const uint8_t fragCount = data[2];
    const auto kind = static_cast<EspNowFrameKind>(data[3]);

    // 정지는 재조립을 기다리지 않고 즉시 반영한다 -- 실행 대기 중에 도착하는 것이
    // 정상이고, 그때 늦으면 정지의 의미가 없다. 버퍼 소유 상태와 무관하게 통과시킨다.
    if (kind == EspNowFrameKind::StopRequest) {
        _stopRequested.store(true);
        return;
    }

    if (fragCount == 0 || fragIndex >= fragCount || fragCount > 32) return;

    const size_t payloadLen = static_cast<size_t>(len) - kHdr;
    const size_t offset = static_cast<size_t>(fragIndex) * ESPNOW_MAX_PAYLOAD_BYTES;
    const uint32_t now = millis();

    FrameDrop drop = FrameDrop::None;
    uint8_t currentMsgId = 0;

    portENTER_CRITICAL(&_mux);
    currentMsgId = _msgId;
    if (_rxState == RxState::Ready || _rxState == RxState::Dispatching) {
        // loop가 버퍼를 쓰는 중이다. 지금 덮으면 처리 중인 JSON이 발밑에서 바뀐다.
        // 어차피 한 번에 한 요청만 다루므로 버리는 것이 맞다(정지는 위에서 이미 통과).
        drop = FrameDrop::Busy;
    } else if (offset + payloadLen > ESPNOW_MAX_MESSAGE_BYTES) {
        // 이 조각만 버린다. 예전에는 재조립 전체를 리셋해서, 엉뚱한 프레임 하나가
        // 진행 중인 정상 메시지를 통째로 없앨 수 있었다.
        drop = FrameDrop::OutOfRange;
    } else if (_rxState == RxState::Assembling && msgId != _msgId) {
        // 진행 중인 재조립을 다른 메시지가 뺏지 못하게 한다. 예전에는 서로 계속
        // 밀어내서 둘 다 완성되지 못하고 타임아웃까지 갔다(교차 리뷰 #10).
        drop = FrameDrop::OtherMessage;
    } else if (_rxState == RxState::Assembling &&
               (fragCount != _fragCount || kind != _readyKind)) {
        // 같은 msgId인데 모양이 다르다 = msgId 카운터가 한 바퀴 돈 옛 프레임
        drop = FrameDrop::Shape;
    } else if (_rxState == RxState::Idle && _hasLastDone && msgId == _lastDoneMsgId &&
               (now - _lastDoneMs) < ESPNOW_REASSEMBLY_TIMEOUT_MS) {
        // 방금 끝낸 메시지의 뒤늦은 조각. 이걸로 새 재조립을 시작해버리면 진짜
        // 새 메시지가 "다른 msgId"로 밀려나 버려진다 -- 위 규칙의 뒷면이다.
        drop = FrameDrop::AlreadyDone;
    } else {
        if (_rxState == RxState::Idle) {
            _resetAssemblyLocked();
            _rxState = RxState::Assembling;
            _msgId = msgId;
            _fragCount = fragCount;
            _readyKind = kind;
            _firstFragMs = now;
        }
        memcpy(_buffer + offset, data + kHdr, payloadLen);
        _fragsSeenMask |= (1UL << fragIndex);
        // 마지막 조각만 길이가 짧을 수 있으므로 끝 위치를 최대값으로 갱신한다
        if (offset + payloadLen > _bufferLen) _bufferLen = offset + payloadLen;

        // 완성 판정은 **저장된** _fragCount로 한다. 이 프레임이 들고 온 값을 쓰면,
        // fragCount=1이라고 주장하는 옛 프레임 하나가 10조각짜리 메시지를 "다 왔다"고
        // 만들어 잘린 JSON을 처리하게 만든다.
        const uint32_t complete = (_fragCount >= 32) ? 0xFFFFFFFFUL
                                                     : ((1UL << _fragCount) - 1UL);
        if (_fragsSeenMask == complete) {
            _readyLen = _bufferLen;
            _rxState = RxState::Ready;
        }
    }
    portEXIT_CRITICAL(&_mux);

    switch (drop) {
        case FrameDrop::Busy:
            log_w("frame dropped -- still handling the previous message");
            break;
        case FrameDrop::OutOfRange:
            log_w("fragment %u lands outside the reassembly buffer -- dropped",
                  fragIndex);
            break;
        case FrameDrop::OtherMessage:
            log_w("fragment of msg %u dropped -- assembling msg %u", msgId,
                  currentMsgId);
            break;
        case FrameDrop::Shape:
            log_w("fragment for msg %u has a different shape -- stale, dropped", msgId);
            break;
        case FrameDrop::AlreadyDone:
            log_i("late fragment of msg %u dropped -- already handled", msgId);
            break;
        case FrameDrop::None:
            break;
    }
}

void EspNowTransport::poll() {
    const uint32_t now = millis();
    bool timedOut = false;
    bool ready = false;
    uint8_t staleMsgId = 0;

    portENTER_CRITICAL(&_mux);
    // 조각이 유실돼 영영 안 오는 메시지가 버퍼를 붙잡지 않게 한다
    if (_rxState == RxState::Assembling &&
        (now - _firstFragMs) > ESPNOW_REASSEMBLY_TIMEOUT_MS) {
        staleMsgId = _msgId;
        _resetAssemblyLocked();
        _rxState = RxState::Idle;
        timedOut = true;
    }
    if (_rxState == RxState::Ready) {
        // 처리가 끝날 때까지 수신부를 막는다
        _rxState = RxState::Dispatching;
        ready = true;
    }
    portEXIT_CRITICAL(&_mux);

    if (timedOut) {
        log_w("reassembly timed out (msg %u) -- discarded", staleMsgId);
    }

    // 가져가면서 지운다 -- 유휴 상태에서 정지 프레임 하나가 abort를 무한 반복시키던
    // 문제(교차 리뷰 지적). 실행 대기 루프도 같은 함수를 쓰므로 소비는 항상 한 번이다.
    if (takeStopRequest() && _onStop) {
        _onStop();
    }

    if (ready) _dispatchReady();
}

void EspNowTransport::_dispatchReady() {
    _dispatchMessage();

    // 처리가 **완전히 끝난 뒤에야** 버퍼를 수신부에 돌려준다. 실행 핸들러는 RPi4
    // 응답을 최대 수십 초 기다리고, 그 사이 _buffer가 덮이면 ArduinoJson이 zero-copy로
    // 참조하던 버튼 라벨이 실행 도중에 바뀐다.
    const uint32_t doneMs = millis();
    portENTER_CRITICAL(&_mux);
    _lastDoneMsgId = _msgId;
    _lastDoneMs = doneMs;
    _hasLastDone = true;
    _resetAssemblyLocked();
    _rxState = RxState::Idle;
    portEXIT_CRITICAL(&_mux);
}

void EspNowTransport::_dispatchMessage() {
    JsonDocument in;
    // zero-copy 파싱이다 -- in의 문자열들은 _buffer를 그대로 가리킨다. 이 함수가
    // 끝날 때까지 수신부가 _buffer를 못 건드리는 이유(_dispatchReady 주석 참고).
    const DeserializationError err = deserializeJson(in, _buffer, _readyLen);

    // 요청 식별자를 먼저 챙긴다 -- 오류 응답에도 실어야 게이트웨이가 상관지을 수 있다.
    // 파싱 자체가 실패하면 알 방법이 없으므로 비워 둔다(게이트웨이가 그 경우를 따로 본다).
    _currentRid[0] = '\0';
    if (err == DeserializationError::Ok) {
        strlcpy(_currentRid, in["rid"] | "", sizeof(_currentRid));
    }

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

void EspNowTransport::_sendJson(JsonDocument& doc) {
    // 어느 요청에 대한 답인지 항상 밝힌다
    doc["rid"] = _currentRid;
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
