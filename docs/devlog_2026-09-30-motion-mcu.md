# 2026-09-30 — 모션 MCU 확정(ESP32)과 `firmware-motion` 첫 빌드

**확인한 것은 "컴파일·링크가 된다"와 "호스트·가짜 MCU·펌웨어 명령 표의 이름이 맞는다"까지다.**
보드·모터·엔코더·리밋 스위치가 없어 플래시·구동은 한 번도 하지 않았다. 핀·게인·기한은 전부 자리표시자다.

## 1. 결정 (사용자 확인 2026-09-30)

```
폰 ─Wi-Fi─ RPi5(중앙) ─UART/LAN 직결─ RPi4(시퀀스 실행·센서 검증·재시도, CT/전류는 RPi4 ADS1115)
   ─USB 시리얼─ ESP32 모션 MCU ─ JMOD-MOTOR-1(TB6612FNG) ×2 ─ FIT0482 ×3 (CoreXY A/B + Z 누름)
```

- 모션 MCU = ESP32. RPi4와 한 세트로 만든다. 통신은 USB 시리얼, 줄 단위 JSON(기존 `serial_motion.py` 규약 그대로).
- `firmware/`(BLE 브릿지 ESP32)는 폰 BLE 예비 경로 + 물리 비상정지 담당으로 남긴다.
- 가전별 ESP32 노드·ESP-NOW 경로는 본선 시연 범위에서 뺐다(`firmware-node/`는 지우지 않고 둔다).

## 2. 9/22 컨설팅 발표 대비 바뀐 점

| 항목 | 9/22 발표 | 지금 |
|---|---|---|
| 모션 제어기 | Arduino(PID) | **ESP32** 모션 MCU(`firmware-motion/`) |
| Z 누름 | 스위치봇 방식 | **FIT0482** 엔코더 DC 모터(A/B와 같은 모터) |
| RPi5 ↔ RPi4 | 가전별 ESP32 노드 경유(ESP-NOW) | **UART/LAN 직결** |
| 전류(CT) 검증 | 콘센트 모듈 측정 | **RPi4 ADS1115**로 측정. 콘센트 모듈은 확장 계획 |

발표 자료에서 옛 구성을 말한 부분은 이 표 기준으로 바꿔 말한다. 모두 설계 결정이며 실물 확인 전이다.

## 3. `firmware-motion/` (새 PlatformIO 프로젝트)

- 플랫폼: `firmware/`와 같은 고정 버전(pioarduino 55.03.312-1 = Arduino-ESP32 3.3.12 / ESP-IDF 5.5.5), 보드 `firebeetle32`.
- 규약: `rpi/controller/serial_motion.py` 머리말과 `rpi/tools/fake_mcu.py`를 기준으로 `status`·`home`·`move`·`press`·`stop`.
  호스트가 XY mm를 CoreXY 카운트로 바꿔 보내므로 MCU는 카운트만 다룬다(counts-per-mm는 호스트 설정).
  Z는 카운트(`depth`) 또는 시간(`duration`).
- 엔코더: PCNT 3유닛 x4 디코딩(호스트 `DECODING_MULTIPLIER=4`). 모터: LEDC PWM + IN1/IN2 + STBY 2개.
- 원점: Z 위 → X → Y, 각 축 접근 → 스위치 해제까지 후퇴 → 저속 재접근 → 후퇴한 곳을 0. 리밋은 NC·활성 레벨 설정.
- 안전: 스톨·예상 밖 리밋·명령 기한·워치독 → short brake 뒤 STBY LOW + `alarm` 이벤트. `stop`은 즉시 듀티 0 + STBY LOW.
  알람은 이벤트를 먼저, 대기 명령의 `ok:false`를 나중에 보낸다(반대면 호스트가 다음 요청을 실패 처리).
- 설정: `include/config.h`에 전부 `TODO(HW 실측)` 자리표시자, `MOTION_CONFIG_PLACEHOLDER`가 1이면 빌드 `#warning`.
- 명령 표: `firmware-motion/protocol_table.json`. 배선 표·채울 값·첫 시험 순서: `firmware-motion/README.md`.

빌드(기본 env, 이 PC): **성공, RAM 29,232 B(5.5%) / Flash 294,091 B(22.4%)**. 경고는 의도한 자리표시자 `#warning` 하나.

## 4. 시험

- 새 `rpi/tests/test_motion_protocol_table.py`(5건): ① `SerialMotionClient`가 실제로 내보내는 요청 줄(depth·duration 두 방식,
  `request_stop` 포함)의 명령·필드 = 표 ② `fake_mcu`의 명령·응답 필드·이벤트·오류 코드 = 표 ③ 표의 이름이 펌웨어 소스에 문자열로 있음.
  표의 필드 이름을 바꾸거나 펌웨어 오류 코드 문자열을 바꾸면 실패하는 것을 확인했다(되돌림).
- 같이 돌린 것: `test_serial_motion.py`, `test_jog_cli.py` — 셋 합쳐 50 통과. 전체 백엔드는 이번에 돌리지 않았다.

## 5. 하지 않은 것 / 남은 것

- 실물 검증 0건: PCNT 계수, PID 안정성, 원점 절차, 정지 거리, 워치독, 스톨 판정 전부 확인 전.
- ~~호스트는 명령 중 heartbeat를 보내지 않는다~~ → §6에서 `ping` heartbeat 추가, 워치독 25 s → 2 s.
- ~~리밋 스위치 상태 조회 명령이 없다~~ → §6에서 `limits` 추가(조그 CLI `limits`).
- RPi4 쪽 CT(ADS1115) 경로와 RPi5↔RPi4 직결 기본값 전환은 이 로그 범위 밖이다.
- 다음: 하드웨어 도착 시 `firmware-motion/README.md` "첫 시험 순서" → [jog-cli devlog](devlog_2026-09-29-jog-cli.md) §5 6단계.

## 6. heartbeat·limits 추가 (같은 날 후속)

**확인한 것은 가짜 MCU 시험과 컴파일까지다.** USB 시리얼 지연·실제 스위치로는 확인 전.

- **heartbeat:** `SerialMotionClient`가 `home`·`move`·`press` 응답을 기다리는 동안 `heartbeat_ms`(기본 500,
  `SIMPLELAY_MOTION_HEARTBEAT_MS`, `0`/`off`면 끔)마다 `{"id":N,"cmd":"ping"}`을 보낸다. 새 명령 대신 `status`를
  재사용하지 않은 이유: 응답이 짧고 상태를 싣지 않아 표·펌웨어가 단순하다. `ping`도 자기 `id`를 받으므로 응답이
  진행 중 명령의 응답으로 오인되지 않는다(기존 `id` 대조가 거른다). 조회(`status`·`limits`)에는 섞지 않는다.
- **펌웨어:** `ping`은 동작을 건드리지 않고 즉시 `ok`. 워치독은 원래부터 받은 줄이면 무엇이든 갱신한다(`poll_host`).
  `HOST_WATCHDOG_MS` 25000 → **2000**, `HOST_HEARTBEAT_MS` 500 추가, 워치독 < 3×heartbeat면 `#error`(옛 "명령 기한보다
  짧다" 경고는 삭제). 둘 다 `TODO(HW 실측)` — RPi4 부하·USB 지연에서 ping 간격이 얼마나 벌어지는지 재고 정한다.
- **limits:** `{"id":N,"cmd":"limits"}` → `raw{x,y,z}`(디바운스 없는 즉시 판독)·`debounced{x,y,z}`(동작 판정 값),
  `true` = 활성(눌림·단선). 리밋 입력은 A/B 모터가 아니라 **X·Y·Z 스위치**(config.h `PIN_LIMIT_X/Y/Z`)라 키도 x·y·z다.
  움직이지 않고 동작 중에도 답한다. 호스트 `SerialMotionClient.limits()`, 조그 CLI `limits`
  (`x=raw:off/deb:off …` — 스위치를 하나씩 눌러 해당 축만 바뀌는지). README "첫 시험 순서" 3번을 테스터 대신 이것으로 바꿨다.
- **가짜 MCU(실행 가능한 기준):** `delays[cmd]`로 응답을 늦추고 그동안 다른 줄을 처리(움직이는 명령은 `busy`),
  `watchdog_s`를 주면 받은 줄 없이 그 시간이 지나면 `alarm(host_timeout)` 이벤트 → 대기 명령 `ok:false`(펌웨어와 같은
  순서). `cmds()`는 `ping`을 빼고 센다(`pings()` 따로).
- 표(`protocol_table.json`)에 `ping`·`limits`·`limit_inputs`·설명 두 줄, `docs/protocol.md` 모션 MCU 링크 절 갱신.

빌드(기본 env, 이 PC): **성공, RAM 29,232 B(5.5%) / Flash 294,651 B(22.5%)**(+560 B). 경고는 자리표시자 `#warning` 하나.

시험: `test_motion_protocol_table.py` 5 → 11(heartbeat 100ms·가짜 워치독 0.3 s에서 1.0 s 원점 복귀가 끝남 — ping 응답을
home 응답으로 받았다면 1.0 s 전에 끝났을 것 / heartbeat 끄면 1.0 s 전에 `host_timeout` 알람 / 조회에는 ping 없음 /
limits 즉시값·디바운스 / 환경 변수 끄기 / config.h 워치독·heartbeat 관계), `test_jog_cli.py` +2(`limits` 출력).
heartbeat를 끄거나 `id` 대조를 풀면 첫 시험이 실패하는 것을 확인했다(되돌림). 관련 76 통과, 백엔드 전체 1회
**1,879 통과·1 실패**(기존 `test_dbus_native` — 이 PC에 `dbus_fast` 없음).
