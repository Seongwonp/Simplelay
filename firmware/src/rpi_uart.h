#pragma once

#include <HardwareSerial.h>
#include <ArduinoJson.h>
#include <functional>
#include "config.h"

using RpiMessageCallback = std::function<void(const JsonDocument&)>;

class RpiUart {
public:
    void begin();

    // Serialise doc as a single JSON line (\n terminated) and write to Serial2.
    void send(const JsonDocument& doc);

    // Drain Serial2 receive buffer; fires onMessage for each complete line.
    // Must be called from loop().
    void poll();

    void onMessage(RpiMessageCallback cb) { _cb = cb; }

private:
    char _buf[JSON_BUF_SIZE];
    size_t _pos = 0;
    RpiMessageCallback _cb;

    void _dispatch(const char* line);
};

extern RpiUart rpiUart;
