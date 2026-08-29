#include "act_uart.h"
#include "config.h"
#include <Arduino.h>

ActUart actUart;

void ActUart::begin() {
    Serial2.begin(ACT_UART_BAUD, SERIAL_8N1, ACT_UART_RX_PIN, ACT_UART_TX_PIN);
    log_i("Act UART ready — %d baud, RX=%d TX=%d", ACT_UART_BAUD, ACT_UART_RX_PIN, ACT_UART_TX_PIN);
}

bool ActUart::send(const JsonDocument& doc) {
    // 버퍼에 안 들어가면 **자르지 않고 보내지 않는다.** 잘린 JSON은 상대가 파싱에
    // 실패하고 버릴 뿐이라, 보낸 쪽은 성공으로 알고 받는 쪽은 아무것도 못 받는
    // 가장 진단하기 어려운 상태가 된다. 여기서 실패를 알리면 호출부가 상위로
    // 오류를 올려 상대가 타임아웃까지 기다리지 않게 할 수 있다.
    const size_t needed = measureJson(doc) + 1;  // +1 = 개행
    if (needed > JSON_BUF_SIZE) {
        log_e("outgoing line %u bytes > buffer %u -- not sent",
              (unsigned)needed, (unsigned)JSON_BUF_SIZE);
        return false;
    }
    char buf[JSON_BUF_SIZE];
    size_t n = serializeJson(doc, buf, sizeof(buf));
    buf[n] = '\n';
    Serial2.write(reinterpret_cast<uint8_t*>(buf), n + 1);
    return true;
}

void ActUart::poll() {
    while (Serial2.available()) {
        char c = static_cast<char>(Serial2.read());
        if (c == '\n' || c == '\r') {
            // 넘친 줄은 앞부분만 파싱하면 안 된다 -- 잘린 JSON이 우연히
            // 유효해 보이는 경우가 최악이다. 개행까지 통째로 버린다.
            if (_overflow) {
                log_w("incoming line exceeded %u bytes -- discarded",
                      (unsigned)sizeof(_buf));
                _overflow = false;
                _pos = 0;
            } else if (_pos > 0) {
                _buf[_pos] = '\0';
                _dispatch(_buf);
                _pos = 0;
            }
        } else if (_overflow) {
            continue;  // 이 줄은 이미 버리기로 했다
        } else if (_pos < sizeof(_buf) - 1) {
            _buf[_pos++] = c;
        } else {
            _overflow = true;
        }
    }
}

void ActUart::_dispatch(const char* line) {
    JsonDocument doc;
    if (deserializeJson(doc, line) != DeserializationError::Ok) {
        log_w("ACT UART: bad JSON: %s", line);
        return;
    }
    if (_cb) _cb(doc);
}
