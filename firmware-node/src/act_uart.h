#pragma once

#include <HardwareSerial.h>
#include <ArduinoJson.h>
#include <functional>
#include "config.h"

// RPi5 -> RPi4의 UART 프로토콜(docs/protocol.md)을 이 노드의 ESP32가 그대로
// 이어받는다 — rpi4/services/act_executor.py가 반대편. execute/abort를 보내고
// result/error/alert/alert_cleared를 받는다는 점에서 rpi/services/act_client.py
// (Python판 클라이언트)와 동일한 프로토콜, 다른 구현.
using ActMessageCallback = std::function<void(const JsonDocument&)>;

class ActUart {
public:
    void begin();

    // Serialise doc as a single JSON line (\n terminated) and write to Serial2.
    // 버퍼를 넘으면 보내지 않고 false — 잘린 JSON을 흘리지 않는다
    bool send(const JsonDocument& doc);

    // Drain Serial2 receive buffer; fires onMessage for each complete line.
    // Must be called repeatedly while waiting for a reply (see main.cpp's
    // waitForActReply()), not just once per loop() -- a blocking HTTP
    // handler needs to keep draining while it waits.
    void poll();

    void onMessage(ActMessageCallback cb) { _cb = cb; }

private:
    char _buf[JSON_BUF_SIZE];
    size_t _pos = 0;
    bool _overflow = false;  // 현재 줄이 버퍼를 넘겨 버리는 중
    ActMessageCallback _cb;

    void _dispatch(const char* line);
};

extern ActUart actUart;
