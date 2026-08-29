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
    // 버퍼를 넘으면 보내지 않고 false — 잘린 JSON을 흘리지 않는다
    bool send(const JsonDocument& doc);

    // Drain Serial2 receive buffer; fires onMessage for each complete line.
    // Must be called from loop().
    void poll();

    void onMessage(RpiMessageCallback cb) { _cb = cb; }

private:
    char _buf[JSON_BUF_SIZE];
    size_t _pos = 0;
    bool _overflow = false;  // 현재 줄이 버퍼를 넘겨 버리는 중
    RpiMessageCallback _cb;

    void _dispatch(const char* line);
};

extern RpiUart rpiUart;
