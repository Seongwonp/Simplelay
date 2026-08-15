#pragma once

#include <NimBLEDevice.h>
#include <ArduinoJson.h>
#include <functional>

using BleMessageCallback = std::function<void(const JsonDocument&)>;

class BleServer {
public:
    void begin();

    bool isConnected() const { return _connected; }

    // Serialise doc and send as a BLE notification.
    // No-op when no client is connected.
    void notify(const JsonDocument& doc);

    void onMessage(BleMessageCallback cb) { _cb = cb; }

private:
    NimBLECharacteristic* _pChar = nullptr;
    bool _connected = false;
    BleMessageCallback _cb;

    class ServerCb;
    class CharCb;
    friend class ServerCb;
    friend class CharCb;
};

extern BleServer bleServer;
