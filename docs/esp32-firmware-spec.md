# ESP32 펌웨어 명세 (Phase B 구현 참조)

> BLE GATT 서버 + GRBL 브릿지. RPi/앱 명령을 받아 Arduino Uno GRBL로 UART 전달하고 응답을 BLE Notify로 포워딩한다.

---

## 1. GRBL 시리얼 프로토콜

### 연결 규칙

| 항목 | 값 |
|------|-----|
| Baud rate | **115200** |
| Line ending | `\n` (LF; CR+LF도 수락) |
| 인코딩 | ASCII |
| 흐름 제어 | 없음 |

GRBL 기동 응답:
```
Grbl 1.1h ['$' for help]
```

### 주요 명령어

| 명령 | 설명 | 응답 |
|------|------|------|
| `$$\n` | 전체 설정 조회 | `$0=10` … `ok` |
| `$H\n` | 홈 사이클 실행 | `ok` / `ALARM:9` |
| `?\n` | 실시간 상태 조회 (newline 불필요) | `<Idle\|MPos:…>` |
| `!\n` | Feed Hold — 즉시 감속 정지 | (응답 없음) |
| `~\n` | Cycle Start / Resume | (응답 없음) |
| `0x18` | Soft Reset (Ctrl+X, 1 바이트) | `Grbl 1.1h …` |
| `G0 X Y Z\n` | 급이송 이동 | `ok` |
| `G1 X Y Z F\n` | 지정 피드레이트 이동 | `ok` |
| `G90\n` | 절대좌표 모드 (기본값) | `ok` |
| `G91\n` | 상대좌표 모드 | `ok` |

### 에러 코드 (주요)

| 코드 | 원인 |
|------|------|
| `error:1` | 명령어 파싱 실패 |
| `error:2` | 숫자 형식 오류 |
| `error:5` | 홈 미완료 상태에서 이동 시도 |
| `error:9` | ALARM 상태 — `$X` 또는 `$H` 필요 |
| `error:20` | 지원하지 않는 G-code |

### 상태 응답 포맷

```
<Idle|MPos:0.000,10.500,0.000|FS:0,0>
<Run|MPos:5.120,10.500,-3.000|FS:500,0>
<Hold:0|MPos:5.120,10.500,-3.000|FS:0,0>
<Alarm|MPos:0.000,0.000,0.000|FS:0,0>
```

`MPos` = 기계 절대좌표 X,Y,Z / `FS` = 현재 피드레이트, 스핀들 RPM

### 버튼 누름 G-code 시퀀스

```gcode
; 기동 시 1회 — 홈 사이클
$H

; BT-05(시작 버튼) XY 위치로 급이송
G0 X52.0 Y80.0

; Z 하강 — 누름 (F200 mm/min)
G1 Z-4.5 F200

; Z 상승 — 복귀
G1 Z0.0 F400

; BT-03(1분) 위치로 이동 후 누름
G0 X26.0 Y80.0
G1 Z-4.5 F200
G1 Z0.0 F400
```

> **타이밍 규칙:** 각 명령 후 `ok` 수신 확인 후 다음 명령 전송 (1-command-1-ack 패턴). 폐루프 검증을 위해 파이프라인 버퍼(최대 15개) 사용 금지.

---

## 2. BLE GATT 서버 — UUID

Touch Bridge와 동일한 UUID 재사용.

| 항목 | 값 |
|------|-----|
| Service UUID | `0000FFE0-0000-1000-8000-00805F9B34FB` |
| Characteristic UUID | `0000FFE1-0000-1000-8000-00805F9B34FB` |
| Properties | READ / WRITE / NOTIFY |
| 기기 이름 | `SimpleLay-ESP32` |

---

## 3. 명령 JSON 포맷

### RPi/앱 → ESP32 (BLE Write)

```json
// 버튼 누름
{"type": "command", "x": 52.0, "y": 80.0, "sequence_id": "demo-001"}

// 비상 정지
{"type": "emergency_stop"}

// Feed Hold
{"type": "abort"}
```

### ESP32 → RPi/앱 (BLE Notify)

```json
// GRBL ok 응답 포워딩
{"type": "grbl_ok", "sequence_id": "demo-001"}

// GRBL error 포워딩
{"type": "grbl_error", "code": 5, "sequence_id": "demo-001"}

// GRBL 상태 포워딩
{"type": "grbl_status", "state": "Idle", "x": 0.0, "y": 0.0, "z": 0.0}
```

---

## 4. ESP32 Arduino 코드 구조

```
firmware/
├── src/
│   ├── main.cpp          # setup() / loop()
│   ├── ble_bridge.cpp    # BLE GATT 서버 + 콜백
│   ├── grbl_serial.cpp   # UART 전송 + 응답 파싱
│   └── estop.cpp         # 하드웨어 E-STOP 인터럽트
├── include/
│   └── config.h          # UUID, 핀 번호, baud rate 상수
└── platformio.ini        # ESP32 보드 설정
```

### 핵심 코드 (main.cpp 구조)

```cpp
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <ArduinoJson.h>

#define SERVICE_UUID  "0000FFE0-0000-1000-8000-00805F9B34FB"
#define CHAR_UUID     "0000FFE1-0000-1000-8000-00805F9B34FB"
#define ESTOP_PIN     4    // 물리 E-STOP 버튼 핀

BLECharacteristic* pChar;
bool deviceConnected = false;

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s)    { deviceConnected = true; }
  void onDisconnect(BLEServer* s) {
    deviceConnected = false;
    s->startAdvertising();    // 연결 끊기면 자동 재광고
  }
};

class CharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) {
    StaticJsonDocument<256> doc;
    if (deserializeJson(doc, c->getValue().c_str()) != DeserializationError::Ok) return;

    const char* type = doc["type"];
    if (strcmp(type, "command") == 0) {
      char buf[64];
      snprintf(buf, sizeof(buf), "G0 X%.3f Y%.3f\n",
               (float)doc["x"], (float)doc["y"]);
      Serial.print(buf);
      Serial.print("G1 Z-4.5 F200\n");
      Serial.print("G1 Z0.0 F400\n");
    } else if (strcmp(type, "emergency_stop") == 0) {
      Serial.write(0x18);    // GRBL Soft Reset
    } else if (strcmp(type, "abort") == 0) {
      Serial.print("!\n");   // Feed Hold
    }
  }
};

// E-STOP 하드웨어 인터럽트
void IRAM_ATTR onEstop() { Serial.write(0x18); }

void setup() {
  Serial.begin(115200);                  // GRBL UART
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
  // GRBL 응답 수신 → BLE Notify 포워딩
  if (Serial.available() && deviceConnected) {
    String resp = Serial.readStringUntil('\n');
    resp.trim();
    if (resp.length() > 0) {
      pChar->setValue(resp.c_str());
      pChar->notify();
    }
  }
}
```

> **NimBLE-Arduino 대안:** `#include <NimBLEDevice.h>`로 교체 시 API 동일, 메모리 사용량 ~50% 감소. 추가 GATT 서비스 계획 있으면 NimBLE 권장.

---

## 5. RPi에서 ESP32 BLE 연결 (bleak)

```python
import asyncio, json
from bleak import BleakClient, BleakScanner

CHAR_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"

def on_notify(sender, data: bytearray):
    print(f"[GRBL] {data.decode().strip()}")

async def press_button(x: float, y: float):
    device = await BleakScanner.find_device_by_name("SimpleLay-ESP32", timeout=10.0)
    if device is None:
        raise RuntimeError("ESP32를 찾을 수 없음")

    async with BleakClient(device) as client:
        await client.start_notify(CHAR_UUID, on_notify)
        cmd = json.dumps({"type": "command", "x": x, "y": y})
        await client.write_gatt_char(CHAR_UUID, cmd.encode(), response=True)
        await asyncio.sleep(3.0)
        await client.stop_notify(CHAR_UUID)
```

**주의사항:**
- RPi OS BlueZ **5.50 이상** 필요 (`bluetoothd --version`)
- `response=True` → GATT Write Request (ESP32의 `PROPERTY_WRITE` 필수)
- bleak은 asyncio 기반 → FastAPI 라우터와 자연 통합

### 필요 패키지

```bash
pip install bleak
```

---

## 6. 명령 흐름 요약

```
앱/RPi
  │  BLE Write (JSON)
  ▼
ESP32 CharCallbacks::onWrite()
  │  G-code 조립
  ▼
Serial.print() → Arduino Uno GRBL
  │  "ok" / "error:N" / "<Idle|...>"
  ▼
loop() Serial.readStringUntil('\n')
  │  BLE Notify (raw 문자열)
  ▼
앱/RPi on_notify()
```

---

## 7. platformio.ini

```ini
[env:esp32dev]
platform = espressif32
board = esp32dev
framework = arduino
monitor_speed = 115200
lib_deps =
    bblanchon/ArduinoJson@^7.0.0
    h2zero/NimBLE-Arduino@^1.4.0
```
