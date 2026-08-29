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

// ─── 송신 완료 대기 ─────────────────────────────────────────────────────────
// esp_now_send()의 성공은 "큐에 넣었다"이지 "상대가 받았다"가 아니다. 조각을
// 연달아 밀어 넣으면 큐가 넘쳐 중간 조각이 조용히 사라지고, 그 결과는 요청이면
// 실행 미시작 후 긴 타임아웃, 응답이면 물리 실행은 성공했는데 화면만 실패다.
// 그래서 조각마다 콜백을 기다린다. 응용 계층 재전송은 여전히 하지 않는다 --
// 같은 버튼을 두 번 누르는 위험 때문(espnow_gateway.h 주석 참고). 다만 "무엇이
// 안 나갔는지"는 알아야 위층에 제때 오류를 올릴 수 있다.
static volatile bool s_sendDone = true;
static volatile bool s_sendOk = false;

static void onDataSent(const uint8_t* mac, esp_now_send_status_t status) {
    (void)mac;
    s_sendOk = (status == ESP_NOW_SEND_SUCCESS);
    s_sendDone = true;
}

// true = 전달 확인. false = 상대가 ACK하지 않았거나 콜백 자체가 안 왔다.
static bool waitForSendResult() {
    const uint32_t deadline = millis() + ESPNOW_SEND_ACK_TIMEOUT_MS;
    while (!s_sendDone && static_cast<int32_t>(millis() - deadline) < 0) {
        delay(1);  // 스핀 대신 양보 -- Wi-Fi 태스크가 콜백을 돌려야 한다
    }
    if (!s_sendDone) {
        log_e("send callback did not arrive within %dms", ESPNOW_SEND_ACK_TIMEOUT_MS);
        return false;
    }
    return s_sendOk;
}

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
    esp_now_register_send_cb(onDataSent);

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
        _handleStopFrame(data, len);
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

// 정지 프레임 본문 = 대상 rid 문자열 그대로(JSON 아님). 비어 있으면 무조건 정지.
// 수신 콜백에서 도는 구간이라 파싱도 할당도 하지 않는다.
void EspNowTransport::_handleStopFrame(const uint8_t* data, int len) {
    size_t ridLen = (len > static_cast<int>(kHdr)) ? static_cast<size_t>(len) - kHdr : 0;
    if (ridLen > sizeof(_stopRid) - 1) ridLen = sizeof(_stopRid) - 1;

    portENTER_CRITICAL(&_mux);
    _stopPending = true;
    if (ridLen > 0) memcpy(_stopRid, data + kHdr, ridLen);
    _stopRid[ridLen] = '\0';
    portEXIT_CRITICAL(&_mux);
}

bool EspNowTransport::takeStopRequest() {
    char rid[sizeof(_stopRid)];
    portENTER_CRITICAL(&_mux);
    const bool had = _stopPending;
    _stopPending = false;
    memcpy(rid, _stopRid, sizeof(rid));
    portEXIT_CRITICAL(&_mux);

    if (!had) return false;
    if (rid[0] == '\0') return true;  // 무조건 정지

    // 지정 정지: 지금 다루는 요청의 것일 때만 통한다. _currentRid는 loop 태스크만
    // 만지므로(여기도 loop) 락이 필요 없다.
    if (strcmp(rid, _currentRid) == 0) return true;
    log_i("stop for rid %s ignored -- current request is %s", rid, _currentRid);
    return false;
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

    // 처리할 메시지가 있으면 정지 판정을 dispatch 안으로 미룬다. **여기서는 이 요청이
    // 어느 rid인지 아직 모르기 때문**이다 -- 앞 실행에서 늦게 온 정지를 지금 꺼내
    // 소비해버리면, 그 정지가 엉뚱하게 이번 실행을 끊거나(대상 확인 없이) 반대로
    // 사라진다(소비만 하고 실행은 시작).
    if (ready) {
        _dispatchReady();
        return;
    }

    // 유휴 상태의 정지. 가져가면서 지운다 -- 정지 프레임 하나가 매 loop마다 abort를
    // 내보내던 문제(교차 리뷰 지적). 대상이 지정된 정지가 지금 것과 안 맞으면
    // takeStopRequest가 조용히 버린다.
    if (takeStopRequest() && _onStop) {
        _onStop();
    }
}

void EspNowTransport::_dispatchReady() {
    _dispatchMessage();

    // 처리가 **완전히 끝난 뒤에야** 버퍼를 수신부에 돌려준다. 버퍼 수명 때문이
    // 아니라(ArduinoJson 7은 문자열을 문서로 복사한다), 실행 중에 들어온 요청을
    // 나중에 꺼내 실행하지 않기 위해서다 -- 그때는 위층이 이미 포기한 뒤다.
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

    // **승인과 시작 사이에 온 정지.** _currentRid가 방금 채워졌으므로 이제야
    // "이 요청을 겨냥한 정지인가"를 판정할 수 있다. 여기서 걸러내지 않으면, 정지를
    // 소비해 abort를 보내놓고(유휴 RPi4는 무시) 곧바로 실행을 시작하게 된다 --
    // 화면은 정지인데 실물이 그때부터 눌린다. 실행 도중의 정지는 waitForActReply가
    // 잡으므로 남은 구멍이 정확히 이 구간이었다.
    if (takeStopRequest()) {
        if (_onStop) _onStop();
        JsonDocument stoppedOut;
        stoppedOut["error"] = "stopped before execution";
        _sendJson(stoppedOut);
        log_w("execute cancelled -- stop arrived before the sequence started");
        return;
    }

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
        // min의 두 인자 타입을 맞춘다. ESPNOW_MAX_PAYLOAD_BYTES는 int 상수식이고
        // len - offset은 size_t라, ESP32 코어 3.x가 쓰는 std::min은 템플릿 인자를
        // 추론하지 못한다(Arduino의 min 매크로가 살아있던 시절엔 그냥 넘어갔다).
        const size_t chunk =
            min(static_cast<size_t>(ESPNOW_MAX_PAYLOAD_BYTES), len - offset);

        frame[0] = outMsgId;
        frame[1] = static_cast<uint8_t>(i);
        frame[2] = static_cast<uint8_t>(fragCount);
        frame[3] = static_cast<uint8_t>(kind);
        memcpy(frame + kHdr, payload + offset, chunk);

        s_sendDone = false;
        const esp_err_t rc = esp_now_send(kGatewayMac, frame, kHdr + chunk);
        if (rc != ESP_OK) {
            s_sendDone = true;
            log_e("esp_now_send failed on fragment %u/%u", (unsigned)(i + 1),
                  (unsigned)fragCount);
            return false;
        }
        // 다음 조각을 보내기 전에 이 조각의 전달 결과를 확인한다(공식 권장).
        // 고정 지연으로 띄우던 이전 방식은 전달 완료와 아무 상관이 없었다.
        if (!waitForSendResult()) {
            log_e("fragment %u/%u was not acked by the gateway", (unsigned)(i + 1),
                  (unsigned)fragCount);
            return false;
        }
    }
    return true;
}
