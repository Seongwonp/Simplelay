# 2026-09-29 — 모션 MCU 확정(ESP32)과 `firmware-motion` 첫 빌드

**확인한 것은 "컴파일·링크가 된다"와 "호스트·가짜 MCU·펌웨어 명령 표의 이름이 맞는다"까지다.**
보드·모터·엔코더·리밋 스위치가 없어 플래시·구동은 한 번도 하지 않았다. 핀·게인·기한은 전부 자리표시자다.

## 1. 결정 (사용자 확인 2026-09-29)

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

## 7. 첫날 위험 보완(2026-09-29)

`firmware-motion/` 임베디드 코드 리뷰가 짚은 "하드웨어 첫날 바로 터질 위험" 다섯 가지와 작은 항목을 고쳤다.
**확인한 것은 컴파일(경고 = 자리표시자 `#warning` 하나, `-Wall -Wextra`도 같음)과 호스트 쪽 가짜 MCU·가짜 pyserial 시험까지다.**
새로 생긴 값(듀티·게인·시간·거리)은 전부 `include/config.h`의 `TODO(HW 실측)` 자리표시자다 — 실측값으로 말하지 않는다.

| # | 위험 | 고친 것 |
|---|---|---|
| 1 (높음) | 원점 복귀가 속도 모드(앞섬 60카운트 × Kp 2 ≈ 듀티 120)라 벨트 부하에서 기동 못 하고, 스톨 문턱(200)에 안 걸려 20 s 기한까지 벽을 민다 | 원점은 **개루프 듀티 프로파일**(`HOME_DUTY_FAST/SLOW`, XY 이동량 차 보정 `HOME_SYNC_GAIN`). 듀티를 주는데 `HOME_STALL_MS` 동안 안 움직이면 `stall` 알람. 단계별 예산 = 최대 이동 카운트 / 최저 허용 속도 + 여유(넘으면 `home_not_found`), `HOME_MAX_MS`는 전체 백스톱(`static_assert`로 예산 합 이상). 후퇴·저속 재접근·후퇴 뒤 제동 `HOME_SETTLE_MS` → 0 |
| 2 (높음) | 포트를 열면 FireBeetle이 DTR/RTS로 리셋돼 첫 status가 사라지고, act_main은 실패 로그만 남기고 다시 시도하지 않는다 | 호스트: `serial.Serial()`을 인자 없이 만들고 dsrdtr·rtscts·xonxoff 끔, DTR/RTS를 **열기 전에** False, 열고 입력 버퍼 비움. `connect()`는 부트 잡음(JSON 아님)을 조용히 버리고 `ready` 배너를 기다리거나 status를 backoff(0.2→1 s)로 `connect_timeout_s`(기본 5 s, `SIMPLELAY_MOTION_CONNECT_TIMEOUT_S`)까지 재시도, 연결 확인 중엔 stop을 보내지 않음. 동작 중 `ready` → `MotionReset`(재홈 필요), 조회 중 `ready` → 새 id로 재요청. act_main: 실패 시 배경 스레드가 1→2→4…30 s로 재연결, 그동안 execute는 `{"type":"error","reason":"motion_not_ready","detail":…}`(설정 누락은 재시도 안 함). 펌웨어: setup 끝에 `{"event":"ready","fw","protocol","reset"}` 한 줄(표·fake_mcu·protocol.md 반영) |
| 3 (중간) | MCU 태스크 워치독 없음, 동작 뒤에도 출력이 켜진 채(PID 유지) | `esp_task_wdt`에 loop·제어 태스크 등록(`MCU_TASK_WDT_MS`, 멈추면 패닉·재부팅 → 배너 `reset:"task_wdt"`). 동작 뒤 정책 `IDLE_POLICY`: 기본 **RELEASE**(`IDLE_RELEASE_BRAKE_MS` 제동 → STBY LOW, 엔코더는 계속 셈), 선택 HOLD(PID 유지). 호스트 워치독은 동작 중이 아니어도 출력이 켜져 있으면 적용(유지 중이면 알람 없이 출력만 내림). STBY 외부 풀다운을 배선 TODO로 |
| 4 (중간) | Ki=0 + 최소 듀티 60 강제 + 허용 오차 4 → 한계 순환·미도착, 1 ms 양자화 속도 미분, 가속 없음, A/B 독립 | 제어를 **esp_timer(`CONTROL_HZ`) → 전용 태스크**로 분리(JSON 해석은 loop 태스크, 잠금 밖). A/B가 한 시간 매개변수를 공유하는 **사다리꼴 궤적**(`MOVE_ACCEL_CPS2` 등), 한 축 추종 오차가 `FOLLOW_ERR_HOLD_COUNTS`를 넘으면 시간 정지. PID에 작은 적분 + anti-windup(포화 쪽 적분 중지 + `I_LIMIT`), 속도 피드포워드 `KFF`, 미분은 `VEL_WINDOW_TICKS` 창 + 저역 필터. 허용 오차 안이면 출력 0(킥 없음), `POS_REENGAGE_COUNTS` 히스테리시스. 도착 = 허용 오차 안 `ARRIVE_DWELL_MS` 연속. 명령 기한 = 예상 궤적 시간 + 여유 |
| 5 (중간) | 누름 중 알람이면 Z가 눌린 채 남는다 | Z가 후퇴 위치 아래(`Z_RETRACT_ZONE_COUNTS` 초과)면 XY는 제동, Z만 위로 개루프(`Z_RETRACT_DUTY`) — `Z_RETRACT_MS`·Z 리밋·도달·스톨에서 멈추고 제동 → STBY LOW. 워치독(`host_timeout`) 부류·원점 모름은 즉시 차단. 결과를 alarm 이벤트 `z_retract`로 보고(`not_needed`/`done`/`timeout`/`stalled`/`skipped`/`stopped`), 이벤트·실패 응답은 후퇴 뒤 |

작은 항목: 리밋 Z를 스트래핑 핀 GPIO5 → **GPIO4**(모터 B IN2를 GPIO5로 맞바꿈 — 출력이라 스트랩에 영향 없음, STBY LOW
동안 부팅 흔들림은 모터에 안 닿음), GPIO36/39 ADC errata 3.11 주석(ADC·Hall 켜면 ~80 ns LOW — 지금은 안 씀, 글리치 필터
1000 ns), `SIMPLELAY_MOTION_HEARTBEAT_MS=off`면 act_main 시작 로그 WARNING·조그 CLI 경고("2 s 넘는 동작은 host_timeout").
송신 링 버퍼(`HOST_TX_BUFFER_BYTES`)를 켜 이벤트 쓰기가 제어 태스크를 UART FIFO 대기로 막지 않게 했다.

빌드(기본 env, 이 PC): **성공, RAM 33,944 B(6.4%) / Flash 298,263 B(22.8%)**(직전 29,232 B / 294,651 B). 새 경고 없음.

시험: 새 `rpi/tests/test_motion_connect.py` 8건(가짜 pyserial로 DTR/RTS·흐름 제어가 open 전에 꺼짐 / 부트 잡음 3줄 + 부팅 중
버린 status → 재시도·배너 / 이미 쌓인 배너 → 재요청 / 배너 없는 펌웨어도 backoff로 붙음 / 끝내 무응답이면 기한 안에 포기,
stop 없음, `not_ready_reason` / 동작 중 재부팅 → `MotionReset`·UNHOMED / heartbeat 끔 문구 / 연결 기한 env),
`test_motion_protocol_table.py` +2(가짜 MCU 배너·알람 필드 = 표, 펌웨어 배너 문자열; 표의 이벤트 필드·`z_retract` 값이
펌웨어 소스에 있는지도 대조), `rpi4/tests/test_act_main_motion.py` +4(무응답 MCU → 배경 재연결 → 준비됨 / 설정 누락은 재시도 안 함 /
준비 전 execute → `motion_not_ready`, MCU로 status 말고는 안 나감 / heartbeat 끔 WARNING). 7가지 변형(DTR을 open 뒤에, 재시도
제거, 동작 중 ready 무시, readiness 배선 제거, 배경 재시도 제거, 경고 제거, 가짜 알람 필드 제거)에서 각 시험이 실패하는 것을
확인했다(되돌림).

**실제 모터로 다시 잡아야 하는 것:** `HOME_DUTY_*`(벨트 부하 기동 듀티), `HOME_STALL_MS`·`STALL_*`, `HOME_*_MIN_CPS`·최대 이동
거리, PID `KP/KI/KD/KFF`·`I_LIMIT`, 속도 창·필터, 허용 오차·히스테리시스·머묾, 속도·가속, 추종 대기 오차, `Z_RETRACT_*`,
`IDLE_POLICY`(벨트·Z가 전원 없이 밀리는지), `MCU_TASK_WDT_MS`, `CONTROL_HZ`. 리눅스(RPi4)에서 포트를 열 때 실제로 리셋되는지
(커널 HUPCL)와 부팅 시간(→ `CONNECT_TIMEOUT_S`), STBY 풀다운 유무도 보드로만 확인된다.
