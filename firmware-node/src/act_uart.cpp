#include "act_uart.h"
#include "config.h"
#include <Arduino.h>

ActUart actUart;

void ActUart::begin() {
    Serial2.begin(ACT_UART_BAUD, SERIAL_8N1, ACT_UART_RX_PIN, ACT_UART_TX_PIN);
    log_i("Act UART ready — %d baud, RX=%d TX=%d", ACT_UART_BAUD, ACT_UART_RX_PIN, ACT_UART_TX_PIN);
}

void ActUart::send(const JsonDocument& doc) {
    char buf[JSON_BUF_SIZE];
    size_t n = serializeJson(doc, buf, sizeof(buf));
    buf[n] = '\n';
    Serial2.write(reinterpret_cast<uint8_t*>(buf), n + 1);
}

void ActUart::poll() {
    while (Serial2.available()) {
        char c = static_cast<char>(Serial2.read());
        if (c == '\n' || c == '\r') {
            if (_pos > 0) {
                _buf[_pos] = '\0';
                _dispatch(_buf);
                _pos = 0;
            }
        } else if (_pos < sizeof(_buf) - 1) {
            _buf[_pos++] = c;
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
