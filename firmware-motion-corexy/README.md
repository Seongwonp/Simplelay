# firmware-motion-corexy — 모션 MCU 펌웨어 (ESP32 CoreXY + 솔레노이드)

> 원작: 팀원(서예솔) Touch Bridge CoreXY 펌웨어 v3, SimpleLay용으로 통신·이름 수정 (2026-10-10 수령·이식).
> 재사용 경계는 [docs/reuse-boundary.md](../docs/reuse-boundary.md), 이식 기록은
> [devlog 2026-10-10](../docs/devlog_2026-10-10-motion-firmware-merge.md).

**컴파일만 확인했다. 보드에 올리지 않았고, 모터·엔코더·솔레노이드로 한 번도 돌려 보지 않았다.**
기구·게인·시간 값은 `include/config.h`에 있고 전부 `실측 필요`다.

ESP32 DevKit + JMOD-MOTOR-1(TB6612FNG) + DFRobot FIT0482 ×2, 엔코더 폐루프 CoreXY. Z 누름은 솔레노이드
(SparkFun ROB-11015, GPIO23 → N-MOSFET 로우사이드 + 플라이백 다이오드).

## 위치

```
RPi4 (rpi/controller/serial_motion.py) ─USB 시리얼 115200, 줄 단위 JSON─ 이 보드
                                                                 ├─ TB6612 A/B ─ FIT0482 A(왼쪽), B(오른쪽)
                                                                 └─ GPIO23 ─ MOSFET ─ 솔레노이드
```

- 무선은 쓰지 않는다. 원작의 BLE(앱 특성·NUS)·앱 JSON v2·인증·G-code는 뺐다(정지 명령은 유선 하나로).
- 규약은 [`firmware-motion/protocol_table.json`](../firmware-motion/protocol_table.json) 그대로다(`rpi/tools/fake_mcu.py`가
  실행 가능한 기준). `rpi/tests/test_motion_corexy_firmware.py`가 이 소스에 표의 이름이 다 있는지, BLE·원작 이름이
  남지 않았는지 본다(이름만 — 동작은 실물로만 확인된다).
- 제어 핵심 `include/CoreXYMotion.h`·`QuadEncoder.h`·`Tb6612Motor.h`는 원작 그대로다. `CoreXYMotion.h`에는 STBY를 켜고 끄는
  것(`driverOn`·`release`·`hold`)과 원점 기준을 버리는 `clearHomed`만 더했다(머리말에 표시).

## 규약 대응 (호스트 줄 → 이 펌웨어)

| 호스트 요청 | 이 펌웨어 | 응답·이벤트 |
|---|---|---|
| (부팅) | setup 끝 | `{"event":"ready","fw":"firmware-motion-corexy","protocol":"line-json/v0","reset":..,"z_mode":"solenoid","z_on_max_ms":800}` |
| `status` | 원작 `motion.status()` + 규약 상태 | `state`(idle·homing·moving·pressing·stopped·alarm), `homed`, `a`·`b`(엔코더 카운트), `z`(솔레노이드 1/0), `alarm` |
| `ping` | 워치독 갱신만 | 즉시 `ok` |
| `limits` | 리밋 핀 판독 | `USE_LIMIT_SWITCHES=false`(기본)면 x·y·z 모두 `false` |
| `home` | 큐에 HOME → 원작 `motion.home()`(스톨 감지 원점, X → Y → 3 mm 후퇴) | `HOME_DONE` → `ok` |
| `move` `a,b,x_mm,y_mm` | X=(a+b)/2/CPM, Y=(a−b)/2/CPM → 원작 `motion.moveTo(x, y)` | (`position`) → `MOVE_DONE` → `ok` |
| `press` `duration` | 큐에 TAP(켜짐 = drive_ms + dwell_ms) → 원작 솔레노이드 100% 당김 → 유지 듀티 → 끔 → 60 ms | `press_start` → `press_end` → `position` → `ok` |
| `press` `depth` | — | `z_unsupported` |
| `stop` | 원작 `emergencyStop`(브레이크·솔레노이드 끔·큐 비움) + 100 ms 뒤 STBY LOW | 진행 중 명령 `stopped`, 그다음 `ok` |

거절(움직이기 전): `busy`(동작 중), `alarm`(알람 뒤 home 전), `not_homed`, `soft_limit`(0~X_MAX/Y_MAX 밖, 켜짐 > 800 ms),
`bad_args`(필드 오류, a·b와 x_mm·y_mm 불일치 > 0.5 mm), `z_cooldown`+`retry_ms`, `hw_init`(제어 태스크 생성 실패).
알람: 원작 `FAULT_FOLLOW` → `stall`, `FAULT_SETTLE` → `timeout`, `FAULT_HOME` → `home_not_found`, 명령 기한 → `timeout`,
호스트 침묵(`HOST_WATCHDOG_MS` 2 s) → `host_timeout`, 이동·누름 중 리밋 → `limit`. 알람은 이벤트를 먼저, 대기 명령의 `ok:false`를
나중에 보내고, 원점 기준을 버린다(home으로만 복구). `z_retract`는 솔레노이드가 켜져 있었으면 `done`, 아니면 `not_needed`.

## RPi4 설정과 맞출 값

펌웨어 `config.h`와 RPi4 환경 변수는 **같은 기구 값**이어야 한다(다르면 `move`가 `bad_args`로 거절된다).

| config.h | RPi4 |
|---|---|
| `COUNTS_PER_REV` = 28 × 50 = 1400 (x4, 출력축) | `SIMPLELAY_MOTION_R_OUT=1400`, `DECODING_MULTIPLIER=4` |
| `PULLEY_TEETH` 20, `BELT_PITCH_MM` 2 | `SIMPLELAY_MOTION_PULLEY_TEETH=20`, `BELT_PITCH_MM=2` |
| 엔코더 부호는 펌웨어 `ENC_*_INVERT`로 맞춘다 | `SIMPLELAY_MOTION_A_SIGN=1`, `B_SIGN=1` |
| 원점(0,0) = 스톨 지점, 원점 뒤 (3,3) mm | `X_MIN_MM`·`Y_MIN_MM` ≥ 3 권장(0이면 벽을 민다), `X_MAX_MM` ≤ `X_MAX_MM`(200) |
| 솔레노이드만 | `SIMPLELAY_MOTION_PRESS_MODE=duration`, `PRESS_DRIVE_MS` + 유지 ≤ 800 |
| `HOME_MAX_MS` 70 s | `SIMPLELAY_MOTION_HOME_TIMEOUT_S` > 70 |
| `HOST_SERIAL_BAUD` 115200 | `SIMPLELAY_MOTION_BAUD=115200` |

## 배선 (원작 README 기준, 팀원 확인 필요)

| JMOD-MOTOR-1 | ESP32 |
|---|---|
| PWMA / AIN1 / AIN2 | 25 / 26 / 27 |
| PWMB / BIN1 / BIN2 | 32 / 33 / 13 |
| STBY | 4 (**외부 풀다운** — 리셋·패닉 중 출력 꺼짐) |
| VCC(로직) | 3.3V |
| VM(모터 전원) | 6V 전원 (모터 정격 6V), 물리 E-STOP 경유 |
| GND | GND (모터 전원 GND와 공통) |

| FIT0482 6핀 | 연결 |
|---|---|
| M+ / M- | 드라이버 AO1/AO2 (B모터는 BO1/BO2) |
| 엔코더 VCC / GND | 3.3V / GND (5V로 먹이면 출력도 5V일 수 있다 — 레벨 변환) |
| 엔코더 A / B | 모터A: 16 / 17, 모터B: 18 / 19 |

| 기타 | ESP32 |
|---|---|
| 솔레노이드 MOSFET 게이트 | 23 (**게이트 외부 풀다운** + 플라이백 다이오드) |
| 리밋 X / Y (선택, NO → GND) | 21 / 22 (SimpleLay 수정: 원작 30·100은 ESP32에 없는 GPIO였다) |

모터 A = 왼쪽, B = 오른쪽. 원점은 좌하단(X-, Y- 방향 벽).

## 빌드 (Windows, 이 저장소 기준)

PowerShell에서. 짧은 코어 경로가 필요하다(사용자 폴더 코어는 Windows 경로 길이 제한으로 프레임워크 압축 해제 실패 —
[outlet devlog](../docs/devlog_2026-10-05-outlet-module.md)).

```powershell
$env:PLATFORMIO_CORE_DIR = 'C:\pio'
$env:PLATFORMIO_BUILD_DIR = 'C:\pio-build\firmware-motion-corexy'
C:\pio-venv\Scripts\python.exe -m platformio run -d firmware-motion-corexy                    # 시연용(esp32dev)
C:\pio-venv\Scripts\python.exe -m platformio run -d firmware-motion-corexy -e esp32dev_bringup # 첫 시험용
C:\pio-venv\Scripts\python.exe -m platformio run -d firmware-motion-corexy -e esp32dev_bringup -t upload --upload-port COM<n>
```

2026-10-10 빌드(pioarduino 55.03.312-1 / Arduino-ESP32 3.3.12, ArduinoJson 7.x): `esp32dev` SUCCESS — RAM 27,936 B(8.5%),
Flash 296,747 B(22.6%). `esp32dev_bringup` SUCCESS — Flash 305,679 B(23.3%), 경고는 의도한 bring-up `#warning` 하나.
`-Wall -Wextra`로 따로 빌드해도 이 폴더 소스에서 경고 없음.

## 처음 켤 때 순서 (원작 README "처음 켤 때 순서"를 옮김 — bring-up 빌드, **벨트 걸기 전**)

**모터 전원(VM)은 끈 채로 시작한다. 물리 E-STOP을 손 닿는 곳에.** bring-up 빌드(`esp32dev_bringup`)를 올리고 시리얼
모니터(115200)를 연다. 부팅하면 `{"event":"ready","fw":"firmware-motion-corexy-bringup",...}`과 도움말 한 줄이 온다.

0. VM 끈 채로 `P` → `STATE OFF homed=0 ...`. 모터 축을 손으로 돌리며 `P`의 `enc`가 바뀌는지 본다.
1. VM 켜고 `M 0.3 0 500` → 모터 A가 돌고 `P`에서 enc 첫 값이 **증가**해야 한다. 감소하면 `ENC_A_INVERT`를 바꾼다.
2. `M 0 0.3 500` → 모터 B도 같은 방식(`ENC_B_INVERT`). (bring-up `M`은 듀티 0.5·2 s로 묶여 있다.)
3. 벨트를 건 뒤 `M 0.3 0.3 300` → 캐리지가 **+X(오른쪽)**, `M 0.3 -0.3 300` → **+Y**.
   - 반대로 가면 `MOTOR_x_INVERT`와 `ENC_x_INVERT`를 **같이** 바꾼다(모터만 바꾸면 양의 피드백으로 폭주).
   - X와 Y가 뒤바뀌면 A/B 모터 배선을 서로 바꾼다.
4. 가운데쯤에 손으로 두고 `Z`(현재 위치를 원점으로) → `G 20 0` → `G 20 20` → `G 0 0` 작은 이동.
   (`Z`는 bring-up 빌드에만 있다 — 시연 빌드는 `home`으로만 원점을 잡는다.)
5. 진동하면 `K`로 kp를 낮추고, 도착이 느리거나 `FAULT timeout`(원작 FAULT SETTLE)이 나면 ki를 올린다.
   예: `K 0.015 0.05 0.00005 0.00012`. 정한 값은 `config.h`의 `DEFAULT_*`에 옮겨 적는다(`K`는 재부팅하면 사라진다).
6. `T 100` → 솔레노이드 한 번(누를 곳 없이 공중에서). 발열·복귀를 본다. 연속으로 보내면 냉각 시간 안이라 거절된다.
7. 기구가 안정되면 `H`로 원점 복귀(스톨 감지) → `HOMED`. 벽을 너무 세게 밀면 `HOMING_PWM_LIMIT`·`STALL_ERR_MM`을 낮춘다.
8. 그다음 **시연 빌드(`esp32dev`)를 다시 올리고** RPi4에서 [jog-cli devlog](../docs/devlog_2026-09-29-jog-cli.md) §5 순서
   (가짜 MCU 리허설 → 실제 포트 status → home → 1 mm 조그 → 가장 작은 누름)를 따른다.

잰 값은 [`docs/실측-기록표.md`](../docs/실측-기록표.md)와 RPi4 환경 변수에 같이 적는다.

## 알려진 한계

- 실물 검증 0건: ISR 엔코더 계수, PID 안정성, 스톨 원점, 정지 거리, 워치독, 솔레노이드 발열·복귀 전부 확인 전.
- 엔코더가 모터 축에 있어 풀리–벨트 미끄럼은 보이지 않는다. 원작의 추종 오차(4 mm·0.2 s)는 걸림·충돌을 잡지만 미끄럼은
  원점 복귀와 L3 검증으로 잡는다.
- 위치 유지(IDLE)는 원작처럼 PID로 잡고 있다가 호스트가 2 s 조용하면 출력을 내린다. 유지 중 손으로 밀면 원작 추종 오차
  감시가 `stall` 알람을 낸다 — 호스트가 다른 요청을 하는 중이면 그 요청이 이 알람으로 실패한다.
- `stop`은 브레이크 100 ms 뒤 STBY LOW일 뿐 위치 유지를 보장하지 않는다. 최종 권한은 모터 전원을 끊는 물리 E-STOP이다.
- STBY·솔레노이드 게이트의 외부 풀다운이 없으면 리셋·패닉·재부팅 중 출력이 떠 있을 수 있다(펌웨어로 막을 수 없다).
