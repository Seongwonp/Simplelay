# firmware-motion — 모션 MCU(ESP32) 펌웨어

**컴파일만 확인했다. 실물(보드·모터·엔코더·스위치)로 한 번도 돌려 보지 않았다.**
`include/config.h`의 핀·방향·PID 게인·PWM·속도·기한·리밋 값은 전부 **자리표시자**다.
채우기 전까지 빌드 때 `#warning`이 뜬다. 실측값이 아니므로 실기기 설정의 근거로 쓰지 않는다.

## 역할과 위치 (2026-09-29 팀 결정)

```
폰 ─Wi-Fi─ RPi5(중앙) ─UART/LAN 직결─ RPi4(시퀀스·센서 검증·재시도, CT/전류는 RPi4 ADS1115)
                                          └─USB 시리얼─ 이 보드(ESP32 모션 MCU)
                                                          ├─ JMOD-MOTOR-1 #1 (TB6612FNG) ─ FIT0482 A, B (CoreXY)
                                                          └─ JMOD-MOTOR-1 #2 (TB6612FNG) ─ FIT0482 Z (누름)
```

- RPi4는 목표 위치·누름 명령·기한·상태 판정만 한다. 엔코더 계수·PWM·위치 PID·리밋은 이 보드가 한다.
- 좌표 변환(XY mm → CoreXY A/B 카운트)은 **RPi4**(`rpi/controller/kinematics.py`)가 한다. 이 보드는 모터별
  목표 카운트만 받는다. counts-per-mm·풀리·벨트 값은 RPi4 환경 변수(`SIMPLELAY_MOTION_*`)다.
- `firmware/`(BLE 브릿지 ESP32)는 폰 BLE 예비 경로 + 물리 비상정지 담당으로 따로 남는다. 가전별 ESP32
  노드·ESP-NOW(`firmware-node/`)는 본선 시연 범위에서 뺐다.
- RPi4와 이 보드는 한 세트로 제작한다.

## 규약

줄 단위 JSON(`\n` 종료). 호스트 쪽은 `rpi/controller/serial_motion.py`, 실행 가능한 기준은
`rpi/tools/fake_mcu.py`, 기계가 읽는 명령 표는 [`protocol_table.json`](protocol_table.json).
`rpi/tests/test_motion_protocol_table.py`가 셋의 명령·필드·오류 코드 이름을 대조한다.

| 명령 | 요청 필드 | 완료 응답 | 비고 |
|---|---|---|---|
| `status` | `id` | `id, ok, state, homed, a, b, z, alarm` | 동작 중에도 답한다 |
| `home` | `id` | `id, ok` | Z 위로 → X → Y. 각 축 접근 → 후퇴 → 저속 재접근 → 후퇴한 곳을 0 |
| `move` | `id, a, b, x_mm, y_mm` | (`position` 이벤트) → `id, ok` | a·b = 목표 카운트. x_mm·y_mm는 MCU 쪽 두 번째 리밋 검사용 |
| `press` | `id, mode, z_counts\|drive_ms, dwell_ms` | `press_start` → `press_end` → `position` 이벤트 → `id, ok` | depth=Z 카운트, duration=구동 시간 |
| `stop` | `id` | `id, ok` | 즉시 듀티 0 + STBY LOW. 진행 중 명령은 `error:"stopped"` |
| `ping` | `id` | `id, ok` | heartbeat. 동작을 건드리지 않고 즉시 답한다(2026-09-29) |
| `limits` | `id` | `id, ok, raw{x,y,z}, debounced{x,y,z}` | 리밋 입력 판독, 활성 = true. 동작 중에도 답한다(2026-09-29) |

- 오류 응답 `{"id":N,"ok":false,"error":"<코드>"}` — 코드 목록은 표의 `errors`.
- 위치 보고(2026-09-29 추가, 선택 이벤트) `{"event":"position","a":..,"b":..,"z":..}` — 이동·누름 중 `POSITION_EVENT_MS`(100ms)마다, 끝날 때 `ok` 직전 한 번. 호스트 `serial_motion.py`가 `last_position`으로 받아 RPi4 progress 프레임 → RPi5 실모드 트윈(`/twin`)의 "엔코더 보고 위치"가 된다. 실물 미검증.
- 부팅 배너(2026-09-29) `{"event":"ready","fw":"firmware-motion","protocol":"line-json/v0","reset":"<이유>"}` — setup 끝에
  한 줄. `reset`은 직전 리셋 이유(`poweron`·`sw`·`panic`·`task_wdt`·`int_wdt`·`wdt`·`brownout`·`ext`·`other`).
  호스트는 포트를 연 뒤 부트 로그(JSON 아님)를 버리고 이 줄 또는 `status` 재시도로 준비를 안다. 동작 중에 오면
  MCU가 재시작한 것 — 호스트는 진행 중 명령을 실패로 끝내고 재홈을 요구한다.
- 알람(`stall`·`limit`·`home_not_found`·`timeout`·`host_timeout`·`soft_limit`)은 **`{"event":"alarm"}`을 먼저**,
  대기 중 명령의 `ok:false`를 나중에 보낸다. 반대 순서면 호스트가 늦게 온 이벤트로 다음 요청(복구용 `home`)을
  실패 처리한다. 알람·정지 뒤에는 `homed=false`가 되고 `home`으로만 복구한다.
- 알람 이벤트의 `z_retract`(2026-09-29): 알람 때 Z가 눌린 쪽(`Z_RETRACT_ZONE_COUNTS` 초과)이면 XY는 제동하고 Z만 위로
  개루프 후퇴(`Z_RETRACT_DUTY`, 한도 `Z_RETRACT_MS`, Z 리밋·`Z_RETRACT_DONE_COUNTS`·스톨에서 멈춤)한 뒤 차단한다 — 이벤트·
  실패 응답은 후퇴가 끝난 뒤 온다. 값: `not_needed`·`done`·`timeout`·`stalled`·`skipped`(워치독 `host_timeout` 부류 또는
  원점 모름 — 즉시 차단)·`stopped`(후퇴 중 `stop`).
- 워치독: 출력이 켜진 동안 호스트 줄이 `HOST_WATCHDOG_MS`(2 s 자리표시자) 동안 하나도 없으면 멈춘다 — 동작 중이면 short
  brake 뒤 STBY LOW + `host_timeout`(Z 후퇴 없이 즉시), `IDLE_POLICY_HOLD`로 정지 유지 중이면 알람 없이 출력만 내린다.
  호스트는 동작 응답을 기다리는 동안 `HOST_HEARTBEAT_MS`(500 ms, 호스트 `SIMPLELAY_MOTION_HEARTBEAT_MS`와 같게)마다
  `ping`을 보내고, 받은 줄이면 무엇이든 워치독을 갱신한다. 워치독이 heartbeat의 3배 미만이면 빌드 오류.
- `limits`: X·Y·Z 리밋 입력의 즉시값(`raw`)·디바운스 값(`debounced`)을 돌려준다(움직이지 않음, 배선 확인용).
- 해석할 수 없는 줄은 무시한다(fake_mcu와 같다). 256바이트를 넘는 줄은 통째로 버린다.

## 구현 요약

- 엔코더: ESP32 PCNT(ESP-IDF 5 `pulse_cnt` 드라이버) 3유닛, **x4 직교 디코딩**, 글리치 필터, 16비트 넘침은
  드라이버 누적(`accum_count`)으로 32비트. → RPi4 `SIMPLELAY_MOTION_DECODING_MULTIPLIER=4`,
  `SIMPLELAY_MOTION_R_OUT`은 x4 기준 실측값.
- 모터: LEDC PWM + IN1/IN2, 드라이버 2개의 STBY. 0 = 공회전(IN1=IN2=LOW), 제동 = IN1=IN2=HIGH.
- 제어 주기(2026-09-29): `esp_timer`가 `CONTROL_HZ`로 깨우는 전용 태스크(`CONTROL_TASK_PRIORITY`, 코어 1)가 `motion_tick`을
  돈다. JSON 해석은 loop 태스크(우선순위 1)에서 잠금 밖에 하고, 상태 변경·시리얼 쓰기만 정적 뮤텍스 안에서 한다 —
  긴 줄 해석이 제어 주기를 밀지 않는다. 송신 링 버퍼(`HOST_TX_BUFFER_BYTES`)로 이벤트 쓰기가 제어 태스크를 막지 않게 했다.
- 위치 제어: 축별 PID + 속도 피드포워드(`KFF`). 적분은 작게(`KI`) 두고 출력이 포화된 쪽으로는 쌓지 않는다(anti-windup,
  `I_LIMIT`). 미분은 `VEL_WINDOW_TICKS` 창 속도에 1차 저역 필터(`VEL_FILTER_ALPHA`)를 건 값에 곱한다. 궤적이 끝난 축은
  허용 오차(`POS_TOLERANCE_COUNTS`) 안이면 **출력 0**(마찰 보상 킥 없음)이고, `POS_REENGAGE_COUNTS`를 넘기 전에는 다시
  밀지 않는다(히스테리시스). 마찰 보상(`PWM_MIN_EFFECTIVE`)은 밖에서만 더한다.
- 궤적: 사다리꼴(`MOVE_SPEED_CPS`·`MOVE_ACCEL_CPS2`, Z는 `Z_*`). A/B는 **한 시간 매개변수**를 공유한다(이동량이 큰 모터
  기준 거리 s(t), 각 축 = 시작 + Δ·s/L). 한 축 추종 오차가 `FOLLOW_ERR_HOLD_COUNTS`를 넘으면 그 주기에 시간을 멈춰
  두 모터가 같은 비율로 진행한다. 도착 = 궤적 끝 + 허용 오차 안에 `ARRIVE_DWELL_MS` 연속. 명령 기한 = 예상 궤적 시간 +
  `MOVE_TIMEOUT_MARGIN_MS`(상한 `MOVE_MAX_MS`·`PRESS_MAX_MS`).
- 원점 복귀: PID가 아니라 **개루프 듀티 프로파일**(`HOME_DUTY_FAST`·`HOME_DUTY_SLOW`, XY는 두 모터 이동량 차이를
  `HOME_SYNC_GAIN`으로 보정). 듀티를 주는데 `HOME_STALL_MS` 동안 안 움직이면 `stall` 알람(스위치 고장으로 끝에 닿아도
  기한까지 벽을 밀지 않는다). 단계별 예산 = 최대 이동 카운트(`HOME_XY/Z_MAX_TRAVEL_COUNTS`, 짧은 단계는 BACKOFF×
  `HOME_RELEASE_FACTOR`) / 최저 허용 속도(`HOME_FAST/SLOW_MIN_CPS`) + `HOME_PHASE_MARGIN_MS` — 넘거나 거리를 넘으면
  `home_not_found`. 후퇴 → 저속 재접근 → `HOME_BACKOFF_COUNTS` 후퇴 → 제동 `HOME_SETTLE_MS` → 0. 그룹 밖 축은 PID로 유지.
  `HOME_MAX_MS`는 전체 백스톱(단계 예산 합 이상 — `static_assert`).
- 정지 유지(`IDLE_POLICY`): 기본 `IDLE_POLICY_RELEASE` — 동작이 끝나면 `IDLE_RELEASE_BRAKE_MS` 제동 뒤 STBY LOW(엔코더는
  계속 센다, 다음 명령은 실제 위치에서 시작). `IDLE_POLICY_HOLD`는 PID로 유지하되 호스트가 조용하면 워치독 시간 뒤 내린다.
- 안전: 스톨(듀티를 주는데 카운트가 안 변함) → `stall`, 동작 중 리밋 눌림 → `limit`, 명령별 기한 → `timeout`,
  워치독 → `host_timeout`. short brake `FAULT_BRAKE_MS` 뒤 STBY LOW(Z가 눌린 쪽이면 그 전에 Z 후퇴 — 위 `z_retract`).
- MCU 태스크 워치독(`esp_task_wdt`, `MCU_TASK_WDT_MS`): loop·제어 태스크가 멈추면 패닉 → 재부팅 → 배너의 `reset`이
  `task_wdt`. 재부팅 중 GPIO는 High-Z라 **STBY 핀 외부 풀다운**이 있어야 출력이 꺼진 채 남는다.
- 인터럽트 핸들러를 직접 두지 않는다(리밋은 폴링+디바운스). 제어 루프에 동적 할당 없음, JSON은 고정 풀
  (esp_timer·태스크는 정적 스택·초기화 때만 생성).
- 코어 로그 레벨 0 — 로그가 같은 UART의 JSON 줄 사이에 끼지 않게 한다.

## 배선 표 (자리표시자 — 예솔 확정 전)

| 신호 | ESP32 GPIO(임시) | 연결 | 확인할 것 |
|---|---|---|---|
| 모터 A PWM / IN1 / IN2 | 25 / 26 / 27 | 드라이버1 PWMA / AIN1 / AIN2 | 모듈 논리 전원 5 V면 레벨 변환 |
| 모터 B PWM / IN1 / IN2 | 16 / 17 / 5 | 드라이버1 PWMB / BIN1 / BIN2 | 모듈 그림의 AIN/BIN 번호 엇갈림(검토 문서). GPIO5(스트래핑)는 출력으로만 |
| 모터 Z PWM / IN1 / IN2 | 18 / 19 / 23 | 드라이버2 PWMA / AIN1 / AIN2 | |
| STBY 드라이버1 / 2 | 22 / 21 | 각 모듈 STBY | HIGH = 출력 켬. **외부 풀다운**(리셋·패닉 중 출력 꺼짐) |
| 엔코더 A CHA / CHB | 34 / 35 | FIT0482 A 엔코더 | 입력 전용 핀, 내부 풀업 없음 |
| 엔코더 B CHA / CHB | 36 / 39 | FIT0482 B 엔코더 | 엔코더 출력 전압(5 V면 분압). ADC·Hall을 켜면 errata 3.11(~80 ns LOW) |
| 엔코더 Z CHA / CHB | 32 / 33 | FIT0482 Z 엔코더 | |
| 리밋 X / Y / Z(위) | 13 / 14 / 4 | NC 스위치 → GND, 풀업 | 9/29 Z를 스트래핑 핀 GPIO5에서 GPIO4로 옮김 |
| RPi4 링크 | USB(UART0) | RPi4 USB | `/dev/ttyUSB*` 또는 `/dev/ttyACM*` |
| 모터 전원 VM | — | E-STOP 경유 | 물리 E-STOP이 모터 전원을 끊는지 |

## 예솔이 채울 값 (`include/config.h`의 `TODO(HW 실측)`)

1. 실제 보드(FireBeetle ESP32 맞는지)와 **핀 배치 전부**, 드라이버 채널 배정.
2. 드라이버 모듈 논리 전원(3.3/5 V)과 레벨 변환 여부, 엔코더 출력 전압·출력 방식(푸시풀/오픈 컬렉터).
3. 모터 방향(`MOTOR_*_INVERT`)·엔코더 부호(`ENC_*_INVERT`): 양(+) 듀티에서 카운트가 느는 쪽으로.
4. 리밋 스위치 결선(NC 여부)·활성 레벨·풀업, 원점 쪽 위치 → `HOME_*_DIR_*` 부호.
5. 모터 공급 전압과 듀티 상한(`PWM_LIMIT_*`), 최소 기동 듀티(`PWM_MIN_EFFECTIVE`), PWM 주파수.
6. PID(무부하 → 벨트 장착 순): `PID_*_KP/KI/KD/KFF/I_LIMIT`, 속도 창·필터(`VEL_WINDOW_TICKS`·`VEL_FILTER_ALPHA`),
   데드밴드(`POS_TOLERANCE_COUNTS`·`POS_REENGAGE_COUNTS`), 도착 머묾(`ARRIVE_DWELL_MS`).
7. 궤적: 속도·가속(`MOVE_SPEED_CPS`·`MOVE_ACCEL_CPS2`·`Z_SPEED_CPS`·`Z_ACCEL_CPS2`), 추종 대기(`FOLLOW_ERR_HOLD_COUNTS`),
   기한 여유(`MOVE_TIMEOUT_MARGIN_MS`), 제어 주기(`CONTROL_HZ`).
8. 원점: 듀티(`HOME_DUTY_FAST`·`HOME_DUTY_SLOW` — 벨트 부하의 기동 듀티보다 확실히 크게), 동기 보정(`HOME_SYNC_GAIN`·
   `HOME_SYNC_MAX_DUTY`), 스톨(`HOME_STALL_MS`), 거리(`HOME_XY_MAX_TRAVEL_COUNTS`·`HOME_Z_MAX_TRAVEL_COUNTS`·`HOME_BACKOFF_COUNTS`·
   `HOME_RELEASE_FACTOR`), 최저 허용 속도(`HOME_FAST_MIN_CPS`·`HOME_SLOW_MIN_CPS` — 잰 속도의 절반쯤), `HOME_PHASE_MARGIN_MS`·
   `HOME_SETTLE_MS`·`HOME_MAX_MS`.
9. 소프트 리밋(A/B 카운트 범위, X/Y mm — RPi4 값과 같게), Z 누름 최대 카운트·시간.
10. Z 후퇴: `Z_RETRACT_DUTY`·`Z_RETRACT_MS`·`Z_RETRACT_ZONE_COUNTS`·`Z_RETRACT_DONE_COUNTS`(Z가 전원 없이 스스로 올라오는지 먼저).
11. 정지 유지 정책(`IDLE_POLICY`, `IDLE_RELEASE_BRAKE_MS`) — 벨트·Z가 전원 없이 밀리는지 보고 고른다.
12. 명령 기한(RPi4 `*_TIMEOUT_S`보다 짧게), 호스트 워치독, MCU 태스크 워치독(`MCU_TASK_WDT_MS`), 스톨 판정 값, 제동 시간.
13. STBY 외부 풀다운 저항 유무(재부팅 중 출력 꺼짐 보장).
14. RPi4 쪽: 보드레이트(`SIMPLELAY_MOTION_BAUD`), R_out(x4), 풀리 톱니·벨트 피치, `A_SIGN`/`B_SIGN`,
    `SIMPLELAY_MOTION_HOME_TIMEOUT_S`(> `HOME_MAX_MS`), `SIMPLELAY_MOTION_CONNECT_TIMEOUT_S`(기본 5 s, 부팅 시간보다 길게).

다 채웠으면 `MOTION_CONFIG_PLACEHOLDER`를 0으로 바꾼다(값을 채우지 않고 바꾸지 않는다). 잰 값은
[`docs/실측-기록표.md`](../docs/실측-기록표.md)에도 적는다.

## 빌드·플래시 (Windows, 이 저장소 기준)

PowerShell에서(Git Bash는 pioarduino 설치 단계가 거부된다). 경로에 한글이 있어 빌드 폴더를 ASCII로 돌린다
— 자세한 사정은 [firmware-build devlog](../docs/devlog_2026-09-28-firmware-build.md).

```powershell
$env:PLATFORMIO_CORE_DIR = 'C:\.platformio'
$env:PLATFORMIO_BUILD_DIR = 'C:\pio-build\firmware-motion'
.\.venv\Scripts\python.exe -m platformio run -d firmware-motion
.\.venv\Scripts\python.exe -m platformio run -d firmware-motion -t upload --upload-port COM<n>
```

2026-09-29 빌드(고정 플랫폼 pioarduino 55.03.312-1 / Arduino-ESP32 3.3.12, ArduinoJson 7.4.3), 첫날 위험 보완 뒤:
RAM 33,944 B(6.4%), Flash 298,263 B(22.8%). 경고는 자리표시자 `#warning` 하나(`-Wall -Wextra`로 따로 빌드해도 같음).

## 첫 시험 순서

**모터 전원(VM)은 끈 채로 시작한다.** 물리 E-STOP을 손 닿는 곳에.

1. 플래시 후 시리얼 모니터(115200 또는 정한 값)를 열면 부트 로그 뒤 `{"event":"ready",...,"reset":"poweron"}` 한 줄이
   오는지(모니터를 열 때 리셋되면 매번 온다). 이어서 `{"id":1,"cmd":"status"}` 입력 →
   `{"id":1,"ok":true,"state":"idle","homed":false,...}`가 오는지. 안 오면 여기서 멈춘다.
2. 모터 축을 손으로 돌리며 `status`의 `a`·`b`·`z`가 바뀌는지, 방향이 기대와 같은지(부호 기록).
3. 리밋 스위치: `{"id":2,"cmd":"limits"}`(또는 조그 CLI `limits`)를 부르며 X·Y·Z 스위치를 하나씩 누른다 —
   해당 축의 `raw`·`debounced`만 `true`가 되는지. 아무것도 안 눌렀는데 `true`면 단선·활성 레벨·풀업부터 확인한다.
4. 그다음은 [jog-cli devlog](../docs/devlog_2026-09-29-jog-cli.md) §5 "하드웨어 도착 첫날 순서" 6단계를 그대로 따른다
   (가짜 MCU 리허설 → 실제 포트 status → home → 1 mm 조그 → 가장 작은 누름).

## 하지 않은 것 / 알려진 한계

- 실물 검증 0건: PCNT 계수·PID 안정성·원점 절차·정지 거리·워치독 동작은 전부 확인 전이다.
- heartbeat·`limits`는 가짜 MCU·컴파일로만 확인했다. USB 시리얼 지연·RPi4 부하에서 `ping` 간격이 얼마나 벌어지는지 재고
  `HOST_WATCHDOG_MS`를 정한다.
- 정지(`stop`)는 STBY LOW로 출력을 끊을 뿐 기계적 즉시 정지·위치 유지를 보장하지 않는다. 누름 중 정지하면
  Z가 내려간 채 남을 수 있다 — `home`으로 올린다(알람은 Z를 한도 안에서 올리고 끊지만, `stop`과 `host_timeout`은
  즉시 끊는다). 최종 권한은 모터 전원을 끊는 물리 E-STOP이다.
- 첫날 위험 보완(원점 개루프·스톨, 사다리꼴 궤적·적분·데드밴드, 정지 유지 정책, Z 후퇴, 태스크 워치독, 제어 태스크,
  부팅 배너)은 **컴파일과 호스트 쪽 가짜 MCU 시험까지**다. 게인·듀티·시간은 전부 실제 모터로 다시 잡는다.
