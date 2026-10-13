# ESP32 펌웨어 명세

> **BLE ↔ UART 순수 릴레이.** 폰 앱이 BLE로 보낸 JSON을 그대로 UART로 RPi5에 전달하고,
> RPi5가 UART로 보낸 JSON 응답을 그대로 BLE Notify로 되돌려준다. ESP32는 메시지 내용을
> 해석하지 않는다 — 의도 해석도, 모션 제어(G-code)도 ESP32의 역할이 아니다.
>
> (이 문서는 예전에 "ESP32가 G-code를 조립해서 Arduino Uno의 GRBL로 전달"하는 설계를
> 담고 있었다. 그 설계는 폐기됐다 — GRBL은 DC 기어드 모터와 호환되지 않아 커스텀 PID
> 펌웨어로 교체됐고, 그 모터 제어 링크는 RPi4↔Arduino 사이에 있지 ESP32와는 무관하다.
> 자세한 사유는 [actuator-design.md](actuator-design.md) 참고.)

---

## 1. 역할

| 구간 | 통신 | 내용 |
|------|------|------|
| 앱 ↔ ESP32 | BLE (GATT) | 폰이 Wi-Fi로 RPi5에 직접 못 붙을 때만 쓰는 폴백 경로 |
| ESP32 ↔ RPi5 | UART | JSON newline-delimited, 115200 baud |

ESP32는 위 두 링크 사이에서 **바이트를 그대로 전달**한다. JSON을 파싱해서 판단을 내리는
로직은 없다 — 그건 전부 RPi5(`rpi/` 패키지의 UartBridge)가 한다.

## 2. BLE GATT 서버 (Touch Bridge UUID 재사용)

| 항목 | 값 |
|------|-----|
| Service UUID | `0000FFE0-0000-1000-8000-00805F9B34FB` |
| Characteristic UUID | `0000FFE1-0000-1000-8000-00805F9B34FB` |
| Properties | READ / WRITE / NOTIFY |
| 기기 이름 | `SimpleLay-ESP32` |

## 3. UART (ESP32 ↔ RPi5)

| 항목 | 값 |
|------|-----|
| Baud rate | 115200 |
| Line ending | `\n` |
| 인코딩 | UTF-8 (한글 라벨 포함 가능) |

메시지 JSON 포맷은 [docs/protocol.md](protocol.md)의 "BLE 프로토콜 (App ↔ ESP32)"와
"UART 프로토콜 (ESP32 ↔ RPi5)" 절이 기준이다 — ESP32는 이 포맷을 알 필요 없이 그대로
중계만 하면 되지만, 디버깅 시 참고.

## 4. 명령 흐름

```
앱 ──BLE Write(JSON)──▶ ESP32 ──그대로 UART forward──▶ RPi5 (UartBridge)
앱 ◀──BLE Notify(JSON)── ESP32 ◀──그대로 UART 수신── RPi5 (UartBridge)
```

E-STOP 물리 버튼이 있다면, ESP32가 직접 UART로 `{"type":"abort"}`를 RPi5에 전송한다
(로컬 하드웨어 인터럽트 → 즉시 전달, BLE 경유하지 않음).

## 5. ESP32 Arduino 코드 구조

```
firmware/
├── src/
│   ├── main.cpp          # setup() / loop()
│   ├── ble_bridge.cpp    # BLE GATT 서버 + 콜백
│   ├── uart_relay.cpp    # RPi5 UART 송수신 (순수 바이트 릴레이)
│   └── estop.cpp         # 하드웨어 E-STOP 인터럽트
├── include/
│   └── config.h          # UUID, UART 핀 번호, baud rate 상수
└── platformio.ini        # ESP32 보드 설정
```

### 핵심 로직 (main.cpp 구조 — 릴레이만, JSON 파싱 없음)

```cpp
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>

#define SERVICE_UUID  "0000FFE0-0000-1000-8000-00805F9B34FB"
#define CHAR_UUID     "0000FFE1-0000-1000-8000-00805F9B34FB"
#define ESTOP_PIN     4    // 물리 E-STOP 버튼 핀 (실제 배선에 맞게 조정)

// RPi5와의 UART는 하드웨어 시리얼2 사용 예시 — 실제 배선에 맞게 핀 조정
#define RPI_UART_RX   16
#define RPI_UART_TX   17
HardwareSerial RpiSerial(2);

BLECharacteristic* pChar;
bool deviceConnected = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s)    { deviceConnected = true; }
  void onDisconnect(BLEServer* s) {
    deviceConnected = false;
    s->startAdvertising();
  }
};

// BLE로 받은 바이트를 그대로 RPi5 UART로 전달 — 내용을 해석하지 않는다.
class CharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) {
    std::string value = c->getValue();
    if (value.empty()) return;
    RpiSerial.write((const uint8_t*)value.data(), value.size());
    RpiSerial.write('\n');
  }
};

void IRAM_ATTR onEstop() {
  RpiSerial.print("{\"type\":\"abort\"}\n");
}

void setup() {
  RpiSerial.begin(115200, SERIAL_8N1, RPI_UART_RX, RPI_UART_TX);
  pinMode(ESTOP_PIN, INPUT_PULLUP);
  attachInterrupt(digitalPinToInterrupt(ESTOP_PIN), onEstop, FALLING);

  BLEDevice::init("SimpleLay-ESP32");
  BLEServer* pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);
  pChar = pService->createCharacteristic(
    CHAR_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_WRITE |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pChar->addDescriptor(new BLE2902());
  pChar->setCallbacks(new CharCallbacks());

  pService->start();
  pServer->getAdvertising()->start();
}

void loop() {
  // RPi5 UART 응답 → BLE Notify로 그대로 포워딩
  if (RpiSerial.available() && deviceConnected) {
    String resp = RpiSerial.readStringUntil('\n');
    resp.trim();
    if (resp.length() > 0) {
      pChar->setValue(resp.c_str());
      pChar->notify();
    }
  }
}
```

> **NimBLE-Arduino 대안:** `#include <NimBLEDevice.h>`로 교체 시 API 동일, 메모리 사용량
> ~50% 감소. 추가 GATT 서비스 계획 있으면 NimBLE 권장.

## 6. platformio.ini

```ini
[env:firebeetle32]
platform = espressif32
board = dfrobot_firebeetle2_esp32s3   ; FireBeetle Board-ESP32 V3.0 (DFRobot ESP WROOM-32)
framework = arduino
monitor_speed = 115200
lib_deps =
    h2zero/NimBLE-Arduino@^1.4.0
```

> **보드:** DFRobot FireBeetle Board-ESP32 V3.0 (ESP WROOM-32 모듈).
> 카메라 모듈이 있을 경우 `board = dfrobot_firebeetle2_esp32s3` 에서 카메라 핀 매핑 추가 필요.
> 향후 카메라 기반 버튼 위치 시각 확인(CV 판정)에 활용 가능.

## 관련 문서

- [docs/protocol.md](protocol.md) — BLE/UART 메시지 JSON 포맷 전체
- [docs/actuator-design.md](actuator-design.md) — 왜 GRBL을 버렸는지, 실제 구동부 구조
- [docs/개발현황.md](개발현황.md) — 전체 보드 역할 분담
