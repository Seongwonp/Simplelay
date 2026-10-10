# 2026-10-10 모션 펌웨어 합치기 — 팀원 CoreXY 펌웨어를 SimpleLay 규약으로

> **실물 검증 0건.** 아래 전부 컴파일과 정적 시험까지다. 보드에 올리지 않았고 모터·엔코더·솔레노이드를 한 번도
> 돌리지 않았다. 기구·게인·시간 값은 원작 값 그대로이며 전부 `실측 필요`다.

## 1. 무엇을 받았나

팀원(서예솔)이 ESP32에서 시험하던 모션 펌웨어 **Touch Bridge CoreXY 펌웨어 v3**(Arduino IDE 스케치)를 받았다.

- 하드웨어: ESP32 DevKit + JMOD-MOTOR-1(TB6612FNG) + DFRobot FIT0482 ×2, 엔코더 폐루프 CoreXY.
- Z: 솔레노이드(SparkFun ROB-11015), GPIO23 → MOSFET.
- 통신: BLE(앱 특성 FFE0/FFE1 + Nordic UART), 앱 JSON v2(+ challenge/auth/provision), GRBL 호환 G-code, 사람용 텍스트
  명령. BLE와 USB 시리얼 모두 같은 명령을 받았다.
- 파일: `config.h`, `CoreXYMotion.h`, `QuadEncoder.h`, `Tb6612Motor.h`, `touchbridge_corexy.ino`, `README.md`.

사용자 결정: SimpleLay용으로 이름과 통신을 바꿔 쓰고, 출처는 정직하게 적는다. 원작 압축본은 저장소에 넣지 않았다.

## 2. 폴더 — `firmware-motion/`에 합치지 않고 `firmware-motion-corexy/`를 새로 만든 이유

`firmware-motion/` README는 팀원 코드를 합칠 때 **`board_config.h` 한 파일(핀·방향·Z 방식)** 만 바뀌도록 준비돼 있었다.
받은 코드는 핀만 다른 것이 아니라 제어 구조가 다르다.

| | `firmware-motion/`(SimpleLay 작성) | 받은 코드 |
|---|---|---|
| 엔코더 | PCNT 하드웨어 계수 | GPIO 인터럽트 x4 디코딩(`QuadEncoder.h`) |
| 목표 단위 | 모터별 카운트(A/B) | XY mm(코어 안에 역기구학) |
| 원점 | 리밋 스위치 + 개루프 듀티 | 스톨(벽) 감지, 리밋은 선택 |
| 동시성 | 전역 뮤텍스 + esp_timer 제어 태스크 | 코어 내부 뮤텍스 + 1 kHz 태스크, 출력은 loop 전용 |

`board_config.h`로 합치려면 원작 제어 핵심을 버리고 우리 상태기계에 다시 써야 한다 — "원작 제어 핵심을 최대한
그대로" 라는 요구와 반대다. 그래서 원작 코어를 그대로 두는 새 폴더를 만들고, `firmware-motion/`의 **규약 계층
(`src/protocol.cpp`)** 만 옮겨 와 원작 코어에 이었다. `firmware-motion/`는 규약 기준(`protocol_table.json`)과 대안 구현으로
남기고 README 머리에 이 사정을 적었다(기존 시험 `test_motion_protocol_table.py`·`test_motion_z_mode.py`도 그대로 통과).

## 3. 남긴 것 / 뺀 것 / 더한 것

### 남긴 것(원작 그대로)
- `include/QuadEncoder.h`, `include/Tb6612Motor.h` — 머리말 두 줄(출처)만 더함.
- `include/CoreXYMotion.h` — PID(속도 피드포워드·안티 와인드업·정지 마찰 보상), CoreXY 기구학(A=X+Y, B=X−Y),
  사다리꼴 궤적(대각선 모터 속도 제한), 스톨 원점 복귀(X→Y→3 mm 후퇴), 추종 오차 감시(4 mm·0.2 s), 정착 실패 감시.
- `src/main.cpp` 안의 원작 부분 — 1 kHz 제어 태스크, 모션 이벤트 큐, 솔레노이드 구동(100% 60 ms → 유지 듀티 90/255,
  강제 해제 백스톱), 단일 동작 큐와 `startStep`·`pump`·`handleEvent` 흐름("이동이 끝나기 전에는 누르지 않고, 실패·정지가
  오면 남은 큐를 버림"), 시리얼 줄 받기.
- `include/config.h`의 핀·방향·PWM·기구·모션·게인·안전 값(값은 그대로, 전부 `실측 필요` 표시).

### 뺀 것
- BLE 서버·앱 특성·Nordic UART·BLE 이름, 앱 JSON v2(commandId·positionToken·상태 notify), challenge/auth/provision
  (HMAC 세션·페어링 키 NVS 저장), KEYRESET.
- GRBL 호환 G-code(G0/G1/G4/G90/G91/G92/$H/$$), SET_GRID·BTN_n, set_servo/get_servo, `SOL_DOWN`·`SOL_UP`·`DWELL` 단계.
- `!` 한 글자 즉시 정지(JSON 줄 안의 글자와 섞일 수 있다 — 정지는 `{"cmd":"stop"}`).
- 사람용 텍스트 명령은 기본 빌드에서 뺐다. 방향 시험에 꼭 필요한 M·Z·G·T·H·S·P·K만 `-DBRINGUP_TEXT_COMMANDS=1`
  빌드(`esp32dev_bringup`)에 남겼다. 이 빌드는 `ready`의 `fw`가 `firmware-motion-corexy-bringup`이고 `#warning`을 낸다.
  `M`은 듀티 0.5·2 s로 묶었다. 이 명령들은 원점·알람 규칙을 우회할 수 있으므로(`Z` = 수동 원점, `M` = PWM 직접)
  **시연·RPi4 연결 보드에는 올리지 않는다.**
- "Touch Bridge" 이름 — 식별자·문자열에서 모두 빼고 파일 머리말 출처 표기에만 남겼다.

### 원작 코어에 고친 곳(`CoreXYMotion.h`, 머리말에 표시)
- STBY: 원작은 부팅 때 HIGH. **LOW로 시작**하고 `home`·`moveTo`·`rawPwm`이 받아들일 때만 올린다(`driverOn`).
- `release()`(브레이크 뒤 STBY LOW), `hold()`(출력을 내린 뒤 누름 직전 현재 위치를 다시 잡아 유지),
  `clearHomed()`(정지·알람 뒤 원점 기준 버림), `outputsOn()`(STBY 상태 — 출력 핀은 되읽을 수 없어 플래그로).

### 더한 것(SimpleLay)
- 규약 계층 `src/host_protocol.{h,cpp}` — `firmware-motion/src/protocol.cpp`에서 옮김(고정 풀 ArduinoJson, 응답 형식).
- 부팅 배너, 7개 명령, 거절 코드, 알람 이벤트 → 대기 명령 실패 순서, `position` 이벤트(100 ms + `ok` 직전).
- 호스트 워치독(2 s, heartbeat 500 ms의 3배 이상이면 빌드 검사), 명령 기한(원점 70 s·이동 15 s·누름 켜짐+1 s),
  리밋 스위치를 켜면 이동·누름 중 `limit` 알람, MCU 태스크 워치독(loop·제어 태스크 1 s).
- 솔레노이드 켜짐 상한 `SOLENOID_ON_MAX_MS`(800, `soft_limit`), 냉각(최소 300 ms 또는 켜짐×3, `z_cooldown`+`retry_ms`,
  부팅 직후에도), 원작 강제 해제 백스톱을 3000 ms → 상한+50 ms로.
- 원작 positionToken의 뜻을 옮긴 누름 위치 검사: 마지막으로 끝난 이동(또는 원점) 위치에서 0.7 mm 넘게 밀렸으면
  `not_homed`로 거절하고 원점 기준을 버린다.
- `move`의 a·b(카운트)를 원작 식으로 mm로 되돌려 함께 온 x_mm·y_mm과 0.5 mm 넘게 다르면 `bad_args` — RPi4와 펌웨어
  기구 값이 어긋난 채 움직이지 않게.
- 원작 config의 잘못된 리밋 핀 수리: `PIN_LIMIT_X=30`·`PIN_LIMIT_Y=100`은 ESP32에 없는 GPIO였다(`USE_LIMIT_SWITCHES=false`라
  쓰이지 않았을 뿐). 내부 풀업이 있는 빈 핀 21·22로 옮기고, 모든 핀을 `static_assert`로 검사한다(핀 30으로 되돌리면
  컴파일 오류가 나는 것을 확인).
- 시험 `rpi/tests/test_motion_corexy_firmware.py`(정적): 규약 표 이름이 소스에 다 있는지, BLE·인증 식별자가 없는지,
  원작 이름이 출처 줄에만 있는지, 출처 표기, 리밋 핀, 호스트 카운트 ↔ 펌웨어 mm 왕복, 워치독 박자, bring-up 명령이
  빌드 플래그 블록 안에만 있는지. 4가지 변형(핀 30, BLEDevice 삽입, host_timeout 이름 바꿈, 워치독 1 s)에서 실패 확인.

## 4. 규약 대응표 (호스트 줄 → 펌웨어 동작)

| 호스트(RPi4) 줄 | 펌웨어 동작 | 응답·이벤트 |
|---|---|---|
| (부팅) | setup 끝 | `{"event":"ready","fw":"firmware-motion-corexy","protocol":"line-json/v0","reset":"<이유>","z_mode":"solenoid","z_on_max_ms":800}` |
| `{"id":1,"cmd":"status"}` | 원작 `motion.status()` + 규약 상태 | `state` idle·homing·moving·pressing·stopped·alarm, `homed`, `a`·`b`(엔코더), `z`(솔레노이드 1/0), `alarm`, `z_mode`, `z_on_max_ms` |
| `{"id":2,"cmd":"ping"}` | 워치독 갱신만(받은 줄이면 무엇이든 갱신) | 즉시 `ok` |
| `{"id":3,"cmd":"limits"}` | 리밋 핀 즉시값·디바운스(5 샘플) | 리밋 미사용(기본)이면 x·y·z 모두 `false` |
| `{"id":4,"cmd":"home"}` | 알람 지움 → 단일 큐에 HOME → 원작 `motion.home()` | 원작 `HOME_DONE` → `ok` / `FAULT_HOME` → alarm `home_not_found` |
| `{"id":5,"cmd":"move","a":..,"b":..,"x_mm":..,"y_mm":..}` | 거절 검사 → X=(a+b)/2/CPM, Y=(a−b)/2/CPM → 큐에 MOVE → 원작 `motion.moveTo(x,y)` | `position`(100 ms마다) → 원작 `MOVE_DONE` → `position` → `ok` |
| `{"id":6,"cmd":"press","mode":"duration","drive_ms":..,"dwell_ms":..}` | 거절 검사 → 큐에 TAP(켜짐 = drive+dwell) → `hold()` → 원작 솔레노이드 당김·유지 → 끔 → 60 ms | `press_start` → `press_end` → `position` → `ok` |
| `press` `mode:"depth"` | — | `z_unsupported` |
| `{"id":7,"cmd":"stop"}` | 남은 이벤트 처리 → 원작 `emergencyStop`(브레이크·솔레노이드 끔·큐 비움) → 100 ms 뒤 STBY LOW. 동작 중이었으면 원점 기준 버림 | 진행 중 명령 `ok:false,"stopped"` → `ok` |
| 알 수 없는 `cmd` | — | `unknown_cmd` |
| JSON 아닌 줄 | 무시(bring-up 빌드에서만 사람용 명령) | — |

| 거절(움직이기 전) | 조건 |
|---|---|
| `busy` | 동작 중(큐가 비지 않음) |
| `alarm` | 알람 뒤 `home` 전 |
| `not_homed` | 원점 전, 또는 누름 위치가 마지막 목표에서 0.7 mm 넘게 밀림 |
| `soft_limit` | X·Y가 0~`X_MAX_MM`/`Y_MAX_MM` 밖, `drive_ms` > 500, 켜짐 > 800 ms |
| `bad_args` | 필드 형식, id 없는 동작 명령, a·b ↔ x_mm·y_mm 불일치 > 0.5 mm |
| `z_cooldown` + `retry_ms` | 솔레노이드 냉각 중 |
| `hw_init` | 제어 태스크·이벤트 큐 생성 실패(`home` 거절, 상태 alarm) |

| 알람(이벤트 먼저 → 대기 명령 실패) | 출처 |
|---|---|
| `stall` | 원작 `FAULT_FOLLOW`(추종 오차 4 mm·0.2 s), 원작 도착 위치 검사 |
| `timeout` | 원작 `FAULT_SETTLE`(정착 1 s 실패), 명령 기한, 솔레노이드 백스톱 |
| `home_not_found` | 원작 `FAULT_HOME`(최대 이동 거리 넘김) |
| `host_timeout` | 동작 중 호스트 줄 2 s 없음 |
| `limit` | 이동·누름 중 리밋 눌림(리밋 사용 시) |

`z_retract`는 솔레노이드가 켜져 있었으면 `done`, 아니면 `not_needed`. 알람 뒤에는 `homed=false`, `home`으로만 복구.
위치 유지(IDLE) 중 호스트가 2 s 조용하면 알람 없이 출력만 내린다(원작은 계속 유지).

## 5. 컴파일 결과

도구: 저장소 밖 venv `C:\pio-venv`(PlatformIO Core 6.2.0), 코어 `C:\pio`, 빌드 `C:\pio-build\firmware-motion-corexy`
(outlet devlog와 같은 환경). 플랫폼은 다른 펌웨어와 같은 고정판 pioarduino `55.03.312-1`(Arduino-ESP32 3.3.12),
ArduinoJson `^7.0.0`(firmware-motion·firmware-outlet과 같은 지정).

| env | 결과 | RAM | Flash |
|---|---|---|---|
| `esp32dev`(시연용) | **SUCCESS** | 27,936 B (8.5%) | 296,747 B (22.6%) |
| `esp32dev_bringup` | **SUCCESS** | 27,936 B (8.5%) | 305,679 B (23.3%) |
| `esp32dev` + `-Wall -Wextra`(별도 빌드 폴더) | SUCCESS, 이 폴더 소스 경고 0 | | |
| 리밋 핀 30으로 되돌린 사본 | **FAILED**(의도) — `static_assert` | | |

bring-up 빌드의 경고는 의도한 `#warning` 하나. **플래시하지 않았다.**

## 6. 시험

- `PYTHONUTF8=1 .venv/Scripts/python.exe -m pytest -q rpi/tests/test_repo_guard.py rpi/tests/test_motion_protocol_table.py rpi/tests/test_motion_z_mode.py rpi/tests/test_motion_corexy_firmware.py --basetemp C:/pyt_fw/run1 -p no:cacheprovider`
  → **67 passed**. 새 파일은 아직 git 추적 전이라 저장소 가드가 내용을 보지 않는다 — 금지어는 따로 grep(없음).

## 7. 처음 켤 때 순서 (원작 README "처음 켤 때 순서"를 옮김)

모터 전원(VM)은 끈 채로 시작하고 물리 E-STOP을 손 닿는 곳에 둔다. **bring-up 빌드**를 올리고 시리얼 모니터 115200.

0. 부팅 배너(`fw":"firmware-motion-corexy-bringup"`)와 도움말이 오는지. VM 끈 채로 모터 축을 손으로 돌리며 `P`의 `enc`가
   바뀌는지.
1. VM 켜고 **벨트 걸기 전** `M 0.3 0 500` → 모터 A가 돌고 `P`에서 enc 첫 값이 **증가**해야 한다. 감소하면 `ENC_A_INVERT` 토글.
2. `M 0 0.3 500` → 모터 B 같은 방식(`ENC_B_INVERT`).
3. 벨트를 건 뒤 `M 0.3 0.3 300` → **+X(오른쪽)**, `M 0.3 -0.3 300` → **+Y**. 반대면 `MOTOR_x_INVERT`와 `ENC_x_INVERT`를
   **같이** 토글(모터만 바꾸면 양의 피드백으로 폭주). X·Y가 뒤바뀌면 A/B 모터 배선을 서로 바꾼다.
4. `Z`(현재 위치를 원점으로) → `G 20 0` → `G 20 20` → `G 0 0`. 진동하면 `K`로 kp를 낮추고, 도착이 느리거나
   `FAULT timeout`(원작 FAULT SETTLE)이면 ki를 올린다(예 `K 0.015 0.05 0.00005 0.00012`). 정한 값은 `config.h`에 옮긴다.
5. `T 100`으로 솔레노이드를 공중에서 한 번 — 복귀·발열을 본다.
6. 기구가 안정되면 `H`(스톨 원점). 벽을 너무 세게 밀면 `HOMING_PWM_LIMIT`·`STALL_ERR_MM`을 낮춘다.
7. **시연 빌드(`esp32dev`)를 다시 올리고** RPi4 환경 변수를 펌웨어 `config.h`와 같게 둔 뒤(README "RPi4 설정과 맞출 값"),
   [jog-cli devlog](devlog_2026-09-29-jog-cli.md) §5(가짜 MCU 리허설 → 실제 포트 status → home → 1 mm 조그 → 가장 작은 누름).

## 8. 문서

- `docs/reuse-boundary.md`: 모션 제어 펌웨어를 **재사용(수정)** 으로 고치고, 10/7 판의 "기구·모션 구현 범위에서는 독립적으로
  작업했다"를 철회. 기구부(갠트리)의 Touch Bridge와의 관계는 단정하지 않고 "확인 필요"로. Z 누름 = 솔레노이드(팀원 코드 기준).
  승인·검증·제안 로직이 신규라는 문장은 유지. 발표용 한 문장도 바꿈.
- `README.md`: Act 하드웨어 줄, 핵심 문단(재사용 표기), 디렉터리 구조에 `firmware-motion-corexy/`.
- `docs/submission/개발완료보고서-초안.md`·`작품소개서-초안.md`: 모션 MCU "미정" → ESP32 + 팀원 코드 재사용(컴파일만), Z 솔레노이드
  (실물 확정 전). `제출-체크리스트.md` G6: 원작 코드의 공개·라이선스 동의 확인 항목.
- `docs/protocol.md`: 이 펌웨어의 `fw` 이름·차이점 한 단락. `firmware-motion/README.md`: 합치지 않은 이유.

## 9. 남은 위험

1. **실물 0건.** ISR 엔코더(모터당 최대 약 7,200 카운트/s × 2) 부하, PID·스톨 원점, 솔레노이드 당김·발열 전부 확인 전.
2. **기구 값 일치.** 펌웨어 `COUNTS_PER_MM`(35, GT2 20T 가정)과 RPi4 `SIMPLELAY_MOTION_*`가 다르면 모든 `move`가 `bad_args`.
   실측 뒤 두 곳을 같이 고친다. RPi4 `X/Y_MIN_MM`은 원점 후퇴(3 mm) 이상으로 — 0이면 벽을 민다.
3. **IDLE 중 알람.** 원작은 위치 유지 중에도 추종 오차를 본다. 유지 중 캐리지가 밀리면 자발 `alarm` 이벤트가 나가고,
   그때 호스트가 다른 요청(status 포함)을 하던 중이면 그 요청이 실패한다(firmware-motion의 HOLD 정책과 같은 성질).
4. **원점 기준 단일성.** 리밋 없이 스톨로 원점을 잡는다. 벽·충돌 위치가 매번 같은지, `STALL_ERR_MM` 1.5 mm가 벨트 탄성에
   맞는지 측정 필요. 엔코더가 모터 축이라 벨트 미끄럼은 보이지 않는다.
5. **외부 풀다운.** STBY(GPIO4)·솔레노이드 게이트(GPIO23)에 외부 풀다운이 없으면 리셋·패닉 중 출력이 뜰 수 있다.
6. **bring-up 빌드 오용.** `Z`·`M`이 원점·알람 규칙을 우회한다. `fw` 이름으로 구분되지만 RPi4가 이를 거절하지는 않는다
   (호스트 쪽 검사는 아직 없음 — 필요하면 `ready.fw` 확인을 추가).
7. **출처·공개.** 제어 핵심이 Touch Bridge 펌웨어에서 왔다. 공개 저장소(MIT)에 올리기 전에 원작자 동의와 원 프로젝트 쪽
   공개 범위를 확인한다(체크리스트 G6). 대회 재사용 규정에 비추어 발표·보고서는 재사용 경계 문서 문장을 따른다.
8. RPi4 운영 경로의 모션은 아직 mock(`SIMPLELAY_MOTION_MODE` 기본). 이 펌웨어로 바꾸는 것은 실물 시험 뒤.

## 10. HW 팀원에게 확인할 것

배선이 README 표와 같은지(특히 B모터 BIN2 = GPIO13, 엔코더 3.3 V), STBY·게이트 외부 풀다운 유무, 실제 풀리 톱니·벨트,
작업 영역(X/Y 최대), 원작 게인을 잡은 조건(벨트 장착 여부), 솔레노이드 전원(5 V 전류 여유)과 연속 누름 발열, 리밋 스위치를
달 계획인지(달면 GPIO21·22, NO → GND), 원작 코드의 공개 동의.
