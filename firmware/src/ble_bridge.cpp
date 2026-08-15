#include "ble_bridge.h"
#include "config.h"
#include <Arduino.h>

BleServer bleServer;

// ─── Server callbacks (connect / disconnect) ────────────────────────────────

class BleServer::ServerCb : public NimBLEServerCallbacks {
    BleServer& _s;
public:
    explicit ServerCb(BleServer& s) : _s(s) {}

    void onConnect(NimBLEServer* pServer) override {
        _s._connected = true;
        log_i("BLE client connected");

        // Send handshake so the app knows the ESP32 is ready.
        JsonDocument doc;
        doc["type"] = "connected";
        _s.notify(doc);
    }

    void onDisconnect(NimBLEServer* pServer) override {
        _s._connected = false;
        log_i("BLE client disconnected — restarting advertising");
        pServer->startAdvertising();
    }
};

// ─── Characteristic callbacks (write from app) ──────────────────────────────

class BleServer::CharCb : public NimBLECharacteristicCallbacks {
    BleServer& _s;
public:
    explicit CharCb(BleServer& s) : _s(s) {}

    void onWrite(NimBLECharacteristic* c) override {
        const std::string& raw = c->getValue();
        JsonDocument doc;
        if (deserializeJson(doc, raw.c_str()) != DeserializationError::Ok) {
            log_w("BLE: bad JSON: %s", raw.c_str());
            return;
        }
        if (_s._cb) _s._cb(doc);
    }
};

// ─── Public API ─────────────────────────────────────────────────────────────

void BleServer::begin() {
    NimBLEDevice::init(BLE_DEVICE_NAME);
    NimBLEDevice::setMTU(BLE_MTU);

    NimBLEServer* pServer = NimBLEDevice::createServer();
    pServer->setCallbacks(new ServerCb(*this));

    NimBLEService* pService = pServer->createService(BLE_SERVICE_UUID);
    _pChar = pService->createCharacteristic(
        BLE_CHAR_UUID,
        NIMBLE_PROPERTY::READ  |
        NIMBLE_PROPERTY::WRITE |
        NIMBLE_PROPERTY::NOTIFY
    );
    _pChar->setCallbacks(new CharCb(*this));

    pService->start();
    pServer->getAdvertising()->start();
    log_i("BLE advertising as '%s'", BLE_DEVICE_NAME);
}

void BleServer::notify(const JsonDocument& doc) {
    if (!_connected || !_pChar) return;
    char buf[NOTIFY_BUF_SIZE];
    size_t n = serializeJson(doc, buf, sizeof(buf));
    _pChar->notify(reinterpret_cast<uint8_t*>(buf), n);
}
