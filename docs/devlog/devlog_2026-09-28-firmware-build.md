# 2026-09-28 — ESP32 펌웨어 첫 로컬 빌드·플랫폼 고정·비밀값 분리

`firmware/`(폰 BLE 폴백 브릿지 + ESP-NOW 게이트웨이)와 `firmware-node/`(가전별 Act 노드)를 이 PC에서 처음
빌드했다. 전에는 `.pio` 산출물이 없었고, `platformio.ini`가 `platform = espressif32`로 미고정이었다.
**보드가 하나도 없으므로 확인한 것은 "컴파일·링크가 된다"까지다.** 플래시·부팅·통신은 전부 미검증이다.

## 1. 도구

- PlatformIO Core 6.2.0을 리포 루트 `.venv`에 설치(`.venv\Scripts\python.exe -m pip install platformio`).
- 이 PC 환경 때문에 필요했던 것(코드 문제 아님):
  - 사용자 폴더 이름이 한글이라 기본 코어 폴더(`%USERPROFILE%\.platformio`)를 쓰지 않고
    `PLATFORMIO_CORE_DIR=C:\.platformio`로 지정했다.
  - pioarduino 플랫폼은 Git Bash(MSYS)에서 도구 설치 단계를 거부한다("MSys/Mingw is not supported") →
    **PowerShell에서 실행**한다.
  - 프로젝트 경로에 한글이 있으면 코어 3.x 링커가 `firmware.map`을 못 연다(`cannot open map file ... Invalid argument`) →
    `PLATFORMIO_BUILD_DIR=C:\pio-build\<프로젝트>`로 ASCII 경로에 빌드했다. 코어 2.x는 한글 경로에서도 링크됐다.
  - 두 플랫폼을 한 코어 폴더에 같이 설치하면 `tool-esptoolpy`가 pioarduino 판으로 바뀌어 7.0.1 빌드가
    `No module named 'intelhex'`로 깨진다 → 코어 2.x 확인은 별도 코어 폴더(`C:\.platformio-v2`)에서 했다.
  - 다운로드는 정상(레지스트리 미러 하나가 DNS 실패했지만 다른 미러로 받아짐).

## 2. 플랫폼 고정 — 코어 3.x

| 선택지 | 플랫폼 | Arduino 코어 | ESP-IDF |
|---|---|---|---|
| **고정(채택)** | pioarduino `55.03.312-1` (GitHub 릴리스 zip URL) | 3.3.12 | 5.5.5 |
| 대안(검증함) | 공식 `espressif32@7.0.1` | 2.0.17 | 4.4 |

- **공식 레지스트리 `platformio/espressif32`는 최신 7.1.3까지 모두 코어 2.0.17**이다(7.0.1은 `~3.20017.0`,
  7.1.3은 `~4.20017.0` 패키지 — 둘 다 2.0.17). 코어 3.x는 pioarduino 플랫폼으로만 받을 수 있다.
- 코드가 이미 코어 3.x(`esp_now_recv_info_t`)를 기준으로 적혀 있어 3.x로 고정했다. 두 코어 모두 `#if` 분기로
  빌드되므로 되돌릴 때는 `platformio.ini`의 `platform =` 한 줄만 `espressif32@7.0.1`로 바꾸면 된다.
- **이전 README 기록 정정:** "2026-08-29, espressif32@7.0.1 = 코어 3.x로 컴파일 검증"은 사실과 다르다. 7.0.1은
  코어 2.0.17을 설치하므로 그때 탄 것은 `mac` 분기였고, 코어 3.x 분기는 오늘 처음 컴파일됐다. 두 README를 고쳤다.

## 3. env 구성과 비밀값 분리

- 두 프로젝트에 env 두 개: `firebeetle32`(기본, `default_envs`) · `firebeetle32_espnow`.
  - `firmware`: `_espnow` = `-D ESPNOW_GATEWAY_ENABLED=1`(BLE 브릿지 + ESP-NOW 게이트웨이 겸용).
  - `firmware-node`: `_espnow` = `-D ESPNOW_ENABLED=1`(HTTP 대신 ESP-NOW).
  - `config.h`의 해당 값은 `#ifndef`로 감싸 기본 0을 유지. 소스를 고쳐 켜는 방식은 없앴다.
  - 참고: 두 플래그 모두 런타임 `if` 분기라 기본 env에서도 ESP-NOW 코드는 컴파일된다. `_espnow` env는 그 분기가
    실제로 링크되는 바이너리를 만든다.
- `firmware-node`의 Wi-Fi SSID/비밀번호와 게이트웨이 MAC을 소스에서 뺐다.
  - `platformio.ini`: `extra_configs = secrets.ini`, 빈 `[secrets] build_flags =` 기본값, `[env]`가 `${secrets.build_flags}`를 포함.
  - `firmware-node/secrets.ini.example`: 자리표시자만 담은 예시. 복사해 `secrets.ini`로 채운다.
  - `firmware-node/.gitignore`: `secrets.ini`(루트 `.gitignore`는 이 작업 범위 밖이라 건드리지 않았다).
  - `config.h`는 `#ifndef WIFI_SSID` / `WIFI_PASSWORD` / `ESPNOW_GATEWAY_MAC`으로 감싸 `secrets.ini`가 없어도
    자리표시자(`CHANGE_ME`, MAC 전부 0)로 컴파일된다.
  - 확인: 임시 `secrets.ini`(가짜 값 `TEST_SSID`, MAC `{0x24,0x6F,0x28,0x00,0x00,0x01}`)로 빌드 → 컴파일 명령에
    `-DWIFI_SSID=\"TEST_SSID\"`·`-DESPNOW_GATEWAY_MAC={...}`가 들어가고, HTTP env 바이너리에 `TEST_SSID` 문자열이 있음.
    임시 파일은 지웠고, 지운 뒤 기본 빌드 바이너리에는 `CHANGE_ME`가 들어간다.
  - 이 방식의 한계: SSID/비밀번호에 공백·따옴표가 있으면 build_flags 따옴표 처리가 까다롭다(예시 파일에 적음).

## 4. 고친 컴파일 오류·경고 (동작 변경 없음)

1. **ESP-NOW 송신 콜백 시그니처(오류, 두 프로젝트)** — ESP-IDF 5.5에서 `esp_now_send_cb_t`가
   `void(*)(const wifi_tx_info_t*, esp_now_send_status_t)`로 바뀌어 `onDataSent(const uint8_t* mac, ...)` 등록이
   `invalid conversion`으로 실패했다. 수신 콜백은 이미 `#if ESP_ARDUINO_VERSION_MAJOR >= 3` 분기가 있었고, 송신 콜백에
   `#if ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(5, 5, 0)` 분기를 더했다. 본문은 주소를 쓰지 않으므로 인자 형만 바뀐다.
   (`firmware/src/espnow_gateway.cpp`, `firmware-node/src/espnow_transport.cpp`, `<esp_idf_version.h>` 포함 추가)
2. **E-STOP ISR `-Wattributes` 경고(코어 3.x, `firmware`)** — `IRAM_ATTR`가 선언(`estop.h`)과 정의 양쪽에 있어
   섹션 이름이 `.iram1.0`/`.iram1.1`로 갈렸다. 선언에서 빼고 정의에만 남겼다. IRAM 배치는 그대로다.

최종 경고: 프로젝트 소스 기준 **0건**(코어 3.3.12·2.0.17 양쪽, 4개 env 모두).

## 5. 빌드 결과 (정적 사용량, 앱 파티션 1,310,720 B / DRAM 532,480 B 기준)

고정 플랫폼(코어 3.3.12):

| 프로젝트 / env | 결과 | RAM | Flash |
|---|---|---|---|
| firmware / firebeetle32 | 성공 | 48,764 B (9.2%) | 710,348 B (54.2%) |
| firmware / firebeetle32_espnow | 성공 | 62,452 B (11.7%) | **1,198,932 B (91.5%)** |
| firmware-node / firebeetle32 | 성공 | 54,024 B (10.1%) | 966,116 B (73.7%) |
| firmware-node / firebeetle32_espnow | 성공 | 54,144 B (10.2%) | 971,980 B (74.2%) |

대안(공식 7.0.1, 코어 2.0.17) — 모두 성공:

| 프로젝트 / env | RAM | Flash |
|---|---|---|
| firmware / firebeetle32 | 42,828 B (8.0%) | 627,197 B (47.9%) |
| firmware / firebeetle32_espnow | 60,156 B (11.3%) | 1,042,133 B (79.5%) |
| firmware-node / firebeetle32 | 51,640 B (9.7%) | 800,141 B (61.0%) |
| firmware-node / firebeetle32_espnow | 51,760 B (9.7%) | 805,881 B (61.5%) |

- 라이브러리: ArduinoJson 7.4.3, NimBLE-Arduino 1.4.3(`firmware`만).
- **주의: 게이트웨이 겸용 env(BLE + Wi-Fi/ESP-NOW)는 코어 3.x에서 앱 파티션의 91.5%**다(여유 약 109 KB).
  기능이 더 붙으면 넘칠 수 있다. 그때 선택지는 ① `board_build.partitions = huge_app.csv`(OTA 없음, 앱 3 MB — 보드 실제
  플래시 크기 확인 필요) ② 코어 2.x로 되돌리기(79.5%) ③ 게이트웨이 전용 보드 분리. 지금은 바꾸지 않았다.
- RAM 수치는 정적 할당만이다. 힙·태스크 스택 사용량은 실기기에서만 나온다. 특히 게이트웨이·노드가
  `uint8_t body[ESPNOW_MAX_MESSAGE_BYTES]`(3 KB)를 함수 지역 변수로 잡는 곳이 있어 loopTask 스택(기본 8 KB) 여유는
  실기기에서 확인해야 한다(`uxTaskGetStackHighWaterMark`).

## 6. 실기기에서 아직 확인하지 않은 것 (전부)

보드가 없어 아래는 하나도 확인하지 않았다.

- 플래시 업로드·부팅·시리얼 로그(두 프로젝트, 두 env 모두)
- `firmware`: BLE 광고·폰 연결·UART(RPi5) 왕복, E-STOP 인터럽트(GPIO33) 반응, ADC(GPIO36) 판독
- `firmware` ESP-NOW 겸용: **BLE와 ESP-NOW 동시 동작(coexistence)**, 노드 피어 등록
- `firmware-node` HTTP: Wi-Fi 연결, `POST /execute`·정지 포트(8081), UART(RPi4) 왕복
- `firmware-node` ESP-NOW: 게이트웨이와 채널 일치, 조각 분할·재조립 왕복(250 B 초과 메시지), 유실 시 3초 정리,
  송신 콜백 기반 전달 확인
- 태스크 스택·힙 여유, 코어 3.x에서의 전력·안정성

## 7. 하드웨어 담당이 채워 줄 값

`firmware-node/secrets.ini`(복사 원본 `secrets.ini.example`, **커밋 금지**)에 넣는다:

1. **`ESPNOW_GATEWAY_MAC`** — 게이트웨이 ESP32(`firmware/`를 `firebeetle32_espnow`로 올린 보드)의 부팅 로그
   `ESP-NOW gateway ready on channel 1, own MAC xx:xx:xx:xx:xx:xx`를 `{0xXX,0xXX,0xXX,0xXX,0xXX,0xXX}`로(공백 없이).
2. **`WIFI_SSID` / `WIFI_PASSWORD`** — HTTP(개발용) 노드를 쓸 때 붙을 공유기. ESP-NOW env만 쓸 거면 필요 없다.

그리고 확인해 줄 것:

3. 실제 보드가 FireBeetle ESP32(PlatformIO `firebeetle32`)가 맞는지, 모듈 플래시 용량(빌드 로그는 16 MB로 표시 —
   보드 정의 값이고 실물 확인 전).
4. 어느 보드가 게이트웨이(`firmware`)이고 어느 보드가 어느 가전의 노드(`firmware-node`)인지.
5. 배선 핀이 `config.h`와 같은지: UART RX 16 / TX 17(양쪽), E-STOP 33(active-low), LED 2, ADC 36.
6. 시연장에서 ESP-NOW 채널 1을 써도 되는지(양쪽 `ESPNOW_CHANNEL`이 같아야 한다).

## 8. 바뀐 파일

- `firmware/platformio.ini`, `firmware-node/platformio.ini` — 플랫폼 고정, env 두 개, (노드) `secrets.ini` 연결
- `firmware/include/config.h`, `firmware-node/include/config.h` — `#ifndef` 기본값
- `firmware/src/espnow_gateway.cpp`, `firmware-node/src/espnow_transport.cpp` — 송신 콜백 `#if`
- `firmware/src/estop.h` — ISR 선언의 `IRAM_ATTR` 제거
- `firmware/README.md`, `firmware-node/README.md` — 검증 기록 정정, env·secrets 사용법, Windows 빌드 주의
- 새 파일: `firmware-node/secrets.ini.example`, `firmware-node/.gitignore`
- 커밋·푸시는 하지 않았다. `rpi/tests/test_repo_guard.py` 5건 통과(작업 트리 기준).
