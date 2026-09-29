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
- 호스트는 명령 중 heartbeat를 보내지 않는다 → 워치독은 가장 긴 명령 기한보다 길게 둬야 한다(빌드 경고로 검사).
  줄이려면 호스트·fake_mcu·표·펌웨어를 함께 고친다.
- 리밋 스위치 상태 조회 명령이 없다. 첫 시험은 테스터로 확인.
- RPi4 쪽 CT(ADS1115) 경로와 RPi5↔RPi4 직결 기본값 전환은 이 로그 범위 밖이다.
- 다음: 하드웨어 도착 시 `firmware-motion/README.md` "첫 시험 순서" → [jog-cli devlog](devlog_2026-09-29-jog-cli.md) §5 6단계.
