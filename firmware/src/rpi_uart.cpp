#include "rpi_uart.h"
#include "config.h"
#include <Arduino.h>

RpiUart rpiUart;

void RpiUart::begin() {
    Serial2.begin(RPI_UART_BAUD, SERIAL_8N1, RPI_UART_RX_PIN, RPI_UART_TX_PIN);
    log_i("RPi UART ready — %d baud, RX=%d TX=%d", RPI_UART_BAUD, RPI_UART_RX_PIN, RPI_UART_TX_PIN);
}

void RpiUart::send(const JsonDocument& doc) {
    char buf[JSON_BUF_SIZE];
    size_t n = serializeJson(doc, buf, sizeof(buf));
    buf[n] = '\n';
    Serial2.write(reinterpret_cast<uint8_t*>(buf), n + 1);
}

void RpiUart::poll() {
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

void RpiUart::_dispatch(const char* line) {
    JsonDocument doc;
    if (deserializeJson(doc, line) != DeserializationError::Ok) {
        log_w("RPI UART: bad JSON: %s", line);
        return;
    }
    if (_cb) _cb(doc);
}
