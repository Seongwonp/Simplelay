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
    esp_now_register_send_cb(onDataSent);
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

    // len == 0은 본문 없는 정지 프레임("무조건 정지")이다 -- 조각 1개로 보낸다
    const size_t fragCount =
        (len == 0) ? 1
                   : (len + ESPNOW_MAX_PAYLOAD_BYTES - 1) / ESPNOW_MAX_PAYLOAD_BYTES;
    if (fragCount > 32) {
        log_e("payload too large to fragment (%u bytes)", (unsigned)len);
        return false;
    }

    uint8_t frame[ESPNOW_MAX_FRAME_BYTES];
    for (size_t i = 0; i < fragCount; ++i) {
        const size_t offset = i * ESPNOW_MAX_PAYLOAD_BYTES;
        // min의 두 인자 타입을 맞춘다. ESPNOW_MAX_PAYLOAD_BYTES는 int 상수식이고
        // len - offset은 size_t라, ESP32 코어 3.x가 쓰는 std::min은 템플릿 인자를
        // 추론하지 못한다(Arduino의 min 매크로가 살아있던 시절엔 그냥 넘어갔다).
        const size_t chunk =
            (len == 0) ? 0
                       : min(static_cast<size_t>(ESPNOW_MAX_PAYLOAD_BYTES), len - offset);

        frame[0] = outMsgId;
        frame[1] = static_cast<uint8_t>(i);
        frame[2] = static_cast<uint8_t>(fragCount);
        frame[3] = kind;
        if (chunk > 0) memcpy(frame + kHdr, payload + offset, chunk);

        s_sendDone = false;
        if (esp_now_send(mac, frame, kHdr + chunk) != ESP_OK) {
            s_sendDone = true;
            log_e("esp_now_send failed on fragment %u/%u", (unsigned)(i + 1),
                  (unsigned)fragCount);
            return false;
        }
        // 다음 조각을 보내기 전에 이 조각의 전달 결과를 확인한다(공식 권장).
        // 고정 지연으로 띄우던 이전 방식은 전달 완료와 아무 상관이 없었다.
        if (!waitForSendResult()) {
            log_e("fragment %u/%u was not acked by the peer", (unsigned)(i + 1),
                  (unsigned)fragCount);
            return false;
        }
    }
    return true;
}

bool EspNowGateway::sendExecute(const char* macText, const JsonArrayConst& buttons,
                                const char* sequenceId) {
    uint8_t mac[6];
    if (!parseMacText(macText, mac)) {
        log_e("bad node address: %s", macText ? macText : "(null)");
        return false;
    }
    if (!_ensurePeer(mac)) return false;

    JsonDocument out;
    // 요청 식별자를 함께 보낸다. 노드가 응답에 그대로 돌려주면 "이 답이 지금 기다리는
    // 요청의 것인지"를 확인할 수 있다 -- 없으면 포기한 요청의 지연 응답이 바로 다음
    // 요청의 결과로 둔갑한다(재시도가 섞이면 실패를 성공으로 보고할 수 있다).
    out["rid"] = sequenceId;
    JsonArray arr = out["buttons"].to<JsonArray>();
    size_t buttonCount = 0;
    for (JsonVariantConst v : buttons) {
        arr.add(v.as<const char*>());
        ++buttonCount;
    }

    uint8_t body[ESPNOW_MAX_MESSAGE_BYTES];
    const size_t len = serializeJson(out, body, sizeof(body));
    if (len == 0) {
        log_e("execute payload did not fit");
        return false;
    }
    // 앞 실행이 아직 안 끝났으면 새로 받지 않는다. 받아버리면 앞 요청의 결과가
    // 뒤 요청의 것으로 잘못 보고된다(RPi5는 한 번에 하나만 보내지만, 재시도나
    // 지연 응답이 겹칠 수 있다).
    //
    // **전송보다 먼저** pending을 세운다. 반대 순서였을 때는, 노드가 아주 빨리
    // (빈 버튼·잘못된 JSON 등으로 즉시) 응답하면 마지막 조각을 보내는 사이에
    // 응답이 도착하고, 수신 콜백이 `_pending == false`를 보고 그것을 버렸다.
    // 그러면 게이트웨이는 이미 온 답을 두고 타임아웃까지 기다렸다.
    //
    // 검사와 설정은 한 임계구역에서 끝낸다. 실제 전송(_sendFramed)은 조각 사이에
    // delay()가 있어 스핀락 안에서 하면 안 되므로 그 밖에서 한다.
    const uint32_t deadline = millis() + ESPNOW_GW_BASE_TIMEOUT_MS +
                              ESPNOW_GW_PER_BUTTON_TIMEOUT_MS * buttonCount;
    bool rejected = false;
    portENTER_CRITICAL(&_mux);
    if (_pending) {
        rejected = true;
    } else {
        _pending = true;
        strlcpy(_pendingSeqId, sequenceId, sizeof(_pendingSeqId));
        memcpy(_pendingMac, mac, 6);
        _pendingDeadlineMs = deadline;
        _rxState = RxState::Idle;  // 앞 요청의 재조립 찌꺼기를 끌고 가지 않는다
        _resetAssemblyLocked();
    }
    portEXIT_CRITICAL(&_mux);

    if (rejected) {
        log_w("execute rejected -- a previous request is still pending");
        return false;
    }

    if (!_sendFramed(mac, kKindExecute, body, len)) {
        portENTER_CRITICAL(&_mux);
        _pending = false;  // 보내지 못했으면 되돌린다
        portEXIT_CRITICAL(&_mux);
        return false;
    }
    return true;
}

void EspNowGateway::sendStop(const char* macText, const char* rid) {
    uint8_t mac[6];
    if (!parseMacText(macText, mac) || !_ensurePeer(mac)) return;
    // 본문 = 대상 rid 문자열 그대로. 노드가 수신 콜백에서 파싱 없이 읽을 수 있게
    // JSON을 쓰지 않는다. 비어 있으면 "무조건 정지".
    const size_t len = (rid != nullptr) ? strlen(rid) : 0;
    _sendFramed(mac, kKindStop, reinterpret_cast<const uint8_t*>(rid), len);
}

void EspNowGateway::_resetAssemblyLocked() {
    _bufferLen = 0;
    _fragCount = 0;
    _fragsSeenMask = 0;
}

// 프레임 하나를 왜 버렸는지. 로그는 임계구역 밖에서 찍어야 해서 이유만 들고 나온다.
enum class FrameDrop : uint8_t {
    None = 0,
    NotPending,    // 지금 기다리는 노드의 응답이 아니다 (흔하다 -- 조용히 버린다)
    Busy,          // 앞 메시지를 아직 처리 중
    OtherMessage,  // 다른 msgId -- 진행 중인 재조립을 뒤엎지 않는다
    Shape,         // 같은 msgId인데 조각 수가 다르다 = 옛 프레임
    AlreadyDone,   // 방금 끝낸 메시지의 뒤늦은 조각
    OutOfRange,    // 버퍼 밖으로 나가는 조각
};

void EspNowGateway::_handleFrame(const uint8_t* mac, const uint8_t* data, int len) {
    if (len < static_cast<int>(kHdr)) return;
    if (data[3] != kKindResponse) return;

    const uint8_t msgId = data[0];
    const uint8_t fragIndex = data[1];
    const uint8_t fragCount = data[2];
    if (fragCount == 0 || fragIndex >= fragCount || fragCount > 32) return;

    const size_t payloadLen = static_cast<size_t>(len) - kHdr;
    const size_t offset = static_cast<size_t>(fragIndex) * ESPNOW_MAX_PAYLOAD_BYTES;
    const uint32_t now = millis();

    FrameDrop drop = FrameDrop::None;
    uint8_t currentMsgId = 0;

    portENTER_CRITICAL(&_mux);
    currentMsgId = _msgId;
    if (!_pending || memcmp(mac, _pendingMac, 6) != 0) {
        // 대기 중인 노드가 아닌 곳에서 온 프레임
        drop = FrameDrop::NotPending;
    } else if (_rxState == RxState::Ready || _rxState == RxState::Dispatching) {
        // loop가 버퍼를 쓰는 중이다. 지금 덮으면 처리 중인 JSON이 발밑에서 바뀐다.
        drop = FrameDrop::Busy;
    } else if (offset + payloadLen > ESPNOW_MAX_MESSAGE_BYTES) {
        // 이 조각만 버린다 -- 엉뚱한 프레임 하나가 진행 중인 재조립을 없애지 않게
        drop = FrameDrop::OutOfRange;
    } else if (_rxState == RxState::Assembling && msgId != _msgId) {
        // 진행 중인 재조립을 다른 메시지가 뺏지 못하게 한다. 예전에는 서로 계속
        // 밀어내서 둘 다 완성되지 못하고 타임아웃까지 갔다(교차 리뷰 #10).
        drop = FrameDrop::OtherMessage;
    } else if (_rxState == RxState::Assembling && fragCount != _fragCount) {
        // 같은 msgId인데 조각 수가 다르다 = msgId 카운터가 한 바퀴 돈 옛 프레임
        drop = FrameDrop::Shape;
    } else if (_rxState == RxState::Idle && _hasLastDone && msgId == _lastDoneMsgId &&
               memcmp(mac, _lastDoneMac, 6) == 0 &&
               (now - _lastDoneMs) < ESPNOW_REASSEMBLY_TIMEOUT_MS) {
        // 방금 끝낸 메시지의 뒤늦은 조각. 이걸로 새 재조립을 시작하면 진짜 새
        // 메시지가 "다른 msgId"로 밀려 버려진다 -- 위 규칙의 뒷면이다.
        drop = FrameDrop::AlreadyDone;
    } else {
        if (_rxState == RxState::Idle) {
            _resetAssemblyLocked();
            _rxState = RxState::Assembling;
            _msgId = msgId;
            _fragCount = fragCount;
            _firstFragMs = now;
        }
        memcpy(_buffer + offset, data + kHdr, payloadLen);
        _fragsSeenMask |= (1UL << fragIndex);
        if (offset + payloadLen > _bufferLen) _bufferLen = offset + payloadLen;

        // 완성 판정은 **저장된** _fragCount로 한다. 이 프레임이 들고 온 값을 쓰면,
        // fragCount=1이라고 주장하는 옛 프레임 하나가 여러 조각짜리 메시지를
        // "다 왔다"고 만들어 잘린 JSON을 처리하게 만든다.
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
            log_w("frame dropped -- still handling the previous response");
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
        case FrameDrop::NotPending:  // 남의 트래픽이 흔하다 -- 조용히 버린다
        case FrameDrop::None:
            break;
    }
}

void EspNowGateway::poll() {
    const uint32_t now = millis();
    bool timedOut = false;
    bool ready = false;
    bool deadlinePassed = false;

    portENTER_CRITICAL(&_mux);
    if (_rxState == RxState::Assembling &&
        (now - _firstFragMs) > ESPNOW_REASSEMBLY_TIMEOUT_MS) {
        _resetAssemblyLocked();
        _rxState = RxState::Idle;
        timedOut = true;
    }
    if (_rxState == RxState::Ready) {
        _rxState = RxState::Dispatching;  // 처리가 끝날 때까지 수신부를 막는다
        ready = true;
    } else if (_pending && static_cast<int32_t>(now - _pendingDeadlineMs) >= 0) {
        deadlinePassed = true;
    }
    portEXIT_CRITICAL(&_mux);

    if (timedOut) {
        log_w("gateway reassembly timed out -- discarded");
        // 노드는 이미 답을 보냈고 조각이 유실된 것이다. 노드는 재전송하지 않으므로
        // 남은 마감까지 기다려봐야 얻을 게 없다 -- 바로 위로 올려서 RPi5가 그만큼
        // 빨리 정지를 보내게 한다(무엇이 잘못됐는지도 타임아웃보다 구체적이다).
        _failPending("node response incomplete");
        return;
    }

    if (ready) {
        _dispatchReady();
        return;
    }

    // 노드가 아예 응답하지 않는 경우. RPi5보다 먼저 포기해서 추측 대신 오류를 준다.
    if (deadlinePassed) {
        _failPending("node did not respond");
    }
}

void EspNowGateway::_dispatchReady() {
    _dispatchMessage();

    // 처리가 끝난 뒤에야 버퍼를 수신부에 돌려준다. 버퍼 수명 때문이 아니라
    // (ArduinoJson 7은 문자열을 문서로 복사한다) 같은 요청을 한 번만 처리하기 위해서다.
    const uint32_t doneMs = millis();
    portENTER_CRITICAL(&_mux);
    _lastDoneMsgId = _msgId;
    memcpy(_lastDoneMac, _pendingMac, 6);
    _lastDoneMs = doneMs;
    _hasLastDone = true;
    _resetAssemblyLocked();
    _rxState = RxState::Idle;
    portEXIT_CRITICAL(&_mux);
}

void EspNowGateway::_failPending(const char* reason) {
    // 대기를 닫는 것과 콜백을 부르는 것을 분리한다. 콜백은 UART로 한 줄을 쓰므로
    // 스핀락 안에서 부르면 그동안 다른 코어가 멈춰 선다.
    char seqId[sizeof(_pendingSeqId)];
    portENTER_CRITICAL(&_mux);
    const bool wasPending = _pending;
    _pending = false;
    memcpy(seqId, _pendingSeqId, sizeof(seqId));
    portEXIT_CRITICAL(&_mux);

    if (!wasPending) return;
    if (_onError) _onError(seqId, reason);
}

void EspNowGateway::_dispatchMessage() {
    JsonDocument in;
    const DeserializationError err = deserializeJson(in, _buffer, _readyLen);

    char seqId[sizeof(_pendingSeqId)];
    portENTER_CRITICAL(&_mux);
    const bool pending = _pending;
    memcpy(seqId, _pendingSeqId, sizeof(seqId));
    portEXIT_CRITICAL(&_mux);
    if (!pending) return;

    if (err != DeserializationError::Ok) {
        _failPending("unparseable node response");
        return;
    }

    // 어느 요청의 답인지 확인한다. 다르면 버리되 대기는 유지한다 -- 진짜 답이
    // 아직 올 수 있고, 안 오면 마감이 알아서 실패로 끝낸다.
    //
    // rid가 빈 응답(노드가 요청 JSON을 못 읽은 경우)도 **받지 않는다.** 한때는
    // "되돌릴 식별자가 없으니 현재 요청의 것으로 보자"고 예외를 뒀는데, 그러면 포기한
    // 요청 A의 늦은 파싱 오류가 지금 대기 중인 B의 실패로 둔갑하고 B의 진짜 응답은
    // 그 뒤 NotPending으로 버려진다. 애초에 요청 JSON은 이 게이트웨이가 직접 만들어
    // 보낸 것이라 정상 운용에서 파싱 실패가 나올 이유가 없다 -- 예외의 값어치보다
    // 오귀속의 대가가 크다. 로그만 남기고 현재 요청의 마감을 기다린다.
    const char* rid = in["rid"] | "";
    if (strcmp(rid, seqId) != 0) {
        log_w("dropping node response for '%s' while waiting on %s", rid, seqId);
        return;
    }

    // 여기부터는 이 응답이 대기 중인 요청의 것이다 -- 대기를 먼저 닫고 콜백을 부른다
    portENTER_CRITICAL(&_mux);
    _pending = false;
    portEXIT_CRITICAL(&_mux);

    if (in["error"].is<const char*>()) {
        if (_onError) _onError(seqId, in["error"].as<const char*>());
        return;
    }
    if (_onResult) {
        _onResult(seqId, in["success"] | false, in["retry"] | 0);
    }
}
