#pragma once
// 원작: 팀원(서예솔) Touch Bridge SwitchBot Bot BLE 클라이언트, SimpleLay 안전 규약에 맞게 수정
//
// BLE 연결·쓰기·notify 대기는 코어 0의 낮은 우선순위 작업에서만 수행한다. loop와 CoreXY 제어,
// USB 시리얼 stop 경로는 BLE 호출을 기다리지 않는다. 성공은 Bot notify의 0x01만 인정한다.

#include <Arduino.h>
#include <BLEClient.h>
#include <BLEDevice.h>

namespace sbble {

constexpr const char* SVC_UUID = "cba20d00-224d-11e6-9fb8-0002a5d5c51b";
constexpr const char* TX_UUID = "cba20002-224d-11e6-9fb8-0002a5d5c51b";
constexpr const char* RX_UUID = "cba20003-224d-11e6-9fb8-0002a5d5c51b";

enum Cmd : uint8_t { PRESS = 0x00, TURN_ON = 0x01, TURN_OFF = 0x02 };

// 양수는 Bot 상태 바이트, 음수는 ESP32 쪽 결과다.
enum ResultCode : int {
  SB_OK = 0x01,
  SB_ERR_CONNECT = -1,
  SB_ERR_SERVICE = -2,
  SB_ERR_NOTIFY = -3,
  SB_ERR_ACK_TIMEOUT = -4,
  SB_ERR_CANCELLED_BEFORE_WRITE = -5,
  SB_ERR_CANCELLED_AFTER_WRITE = -6,
};

struct Result {
  int code;
  bool commandSent;
};

constexpr uint32_t ACK_TIMEOUT_MS = 3000;

static BLEClient* client = nullptr;
static QueueHandle_t reqQ = nullptr;
static QueueHandle_t resQ = nullptr;
static char mac[18] = "";
static volatile bool inFlight = false;
static volatile bool cancelRequested = false;
static volatile bool commandSent = false;
static volatile bool gotAck = false;
static volatile uint8_t ackByte = 0;
static portMUX_TYPE stateMux = portMUX_INITIALIZER_UNLOCKED;

static void onNotify(BLERemoteCharacteristic*, uint8_t* data, size_t len, bool) {
  if (len > 0) {
    ackByte = data[0];
    gotAck = true;
  }
}

static Result doCommand(uint8_t cmd) {
  gotAck = false;
  commandSent = false;
  if (cancelRequested) return {SB_ERR_CANCELLED_BEFORE_WRITE, false};
  // SwitchBot Bot은 random static 주소를 쓴다.
  if (!client->connect(BLEAddress(mac), BLE_ADDR_TYPE_RANDOM)) return {SB_ERR_CONNECT, false};

  Result result = {SB_ERR_SERVICE, false};
  BLERemoteService* svc = client->getService(BLEUUID(SVC_UUID));
  BLERemoteCharacteristic* tx = svc ? svc->getCharacteristic(BLEUUID(TX_UUID)) : nullptr;
  BLERemoteCharacteristic* rx = svc ? svc->getCharacteristic(BLEUUID(RX_UUID)) : nullptr;
  if (cancelRequested) {
    result = {SB_ERR_CANCELLED_BEFORE_WRITE, false};
  } else if (tx == nullptr) {
    result = {SB_ERR_SERVICE, false};
  } else if (rx == nullptr || !rx->canNotify()) {
    // notify 없이 write 성공만으로 눌림 성공을 만들지 않는다.
    result = {SB_ERR_NOTIFY, false};
  } else {
    rx->registerForNotify(onNotify);
    if (cancelRequested) {
      result = {SB_ERR_CANCELLED_BEFORE_WRITE, false};
    } else {
      // stop과 write 직전의 경합: stop이 먼저면 쓰지 않고, 이쪽이 먼저면 "이미 보냄"으로 보수적으로 보고한다.
      portENTER_CRITICAL(&stateMux);
      const bool writeClaimed = !cancelRequested;
      if (writeClaimed) commandSent = true;
      portEXIT_CRITICAL(&stateMux);
      if (!writeClaimed) {
        result = {SB_ERR_CANCELLED_BEFORE_WRITE, false};
      } else {
        uint8_t packet[3] = {0x57, 0x01, cmd};
        tx->writeValue(packet, sizeof(packet), true);
        const uint32_t started = millis();
        while (!gotAck && !cancelRequested && millis() - started < ACK_TIMEOUT_MS) vTaskDelay(pdMS_TO_TICKS(10));
        if (cancelRequested) {
          result = {SB_ERR_CANCELLED_AFTER_WRITE, true};
        } else if (!gotAck) {
          result = {SB_ERR_ACK_TIMEOUT, true};
        } else {
          result = {static_cast<int>(ackByte), true};
        }
      }
    }
  }
  client->disconnect();
  vTaskDelay(pdMS_TO_TICKS(150));
  return result;
}

static void worker(void*) {
  uint8_t cmd = 0;
  for (;;) {
    if (xQueueReceive(reqQ, &cmd, portMAX_DELAY) == pdTRUE) {
      Result result = doCommand(cmd);
      xQueueOverwrite(resQ, &result);
      inFlight = false;
    }
  }
}

// BLEDevice::init("") 뒤 한 번 부른다. BLE 서버는 만들지 않는다.
inline bool begin(const char* botMac) {
  strncpy(mac, botMac, sizeof(mac) - 1);
  mac[sizeof(mac) - 1] = '\0';
  client = BLEDevice::createClient();
  reqQ = xQueueCreate(1, sizeof(uint8_t));
  resQ = xQueueCreate(1, sizeof(Result));
  if (client == nullptr || reqQ == nullptr || resQ == nullptr) return false;
  // CoreXY 1 kHz 제어는 코어 1의 높은 우선순위다. BLE는 코어 0의 낮은 우선순위에서만 돈다.
  return xTaskCreatePinnedToCore(worker, "sbble", 6144, nullptr, 2, nullptr, 0) == pdPASS;
}

inline bool request(uint8_t cmd) {
  if (client == nullptr || reqQ == nullptr || resQ == nullptr || inFlight) return false;
  xQueueReset(resQ);
  cancelRequested = false;
  commandSent = false;
  inFlight = true;
  if (xQueueSend(reqQ, &cmd, 0) != pdTRUE) {
    inFlight = false;
    return false;
  }
  return true;
}

inline bool poll(Result& result) {
  return resQ != nullptr && xQueueReceive(resQ, &result, 0) == pdTRUE;
}

// 기다림 중단만 표시하고 즉시 돌아온다. 이미 보낸 BLE 명령은 회수할 수 없다.
inline bool cancel() {
  portENTER_CRITICAL(&stateMux);
  cancelRequested = true;
  const bool sent = commandSent;
  portEXIT_CRITICAL(&stateMux);
  return sent;
}

inline bool busy() { return inFlight; }
inline bool sent() { return commandSent; }

}  // namespace sbble
