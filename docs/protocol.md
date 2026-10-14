# SimpleLay 통신 프로토콜 명세

## 디바이스 역할

| 디바이스 | 역할 | 통신 |
|----------|------|------|
| Flutter App | Sense — 음성/터치 명령 수집, 루틴 확인 UI | BLE (← ESP32) |
| ESP32 | UI·Sensor 노드 — BLE 브릿지, LED UI, 센서 중계 | BLE ↔ App, UART → RPi5 |
| Raspberry Pi 5 | Interpret — LLM 의도 해석, 시퀀스 생성, 패턴 DB | UART ← ESP32; RPi4로는 가전별 ESP32 노드 경유(HTTP/ESP-NOW)가 기본, UART 직결은 개발·대체 경로(9/29 정리) |
| Raspberry Pi 4 | Act — 액추에이터 제어, 폐루프 검증 | UART ← RPi5, GPIO |

---

## BLE 프로토콜 (App ↔ ESP32)

```
Service UUID    : 0000FFE0-0000-1000-8000-00805F9B34FB
Characteristic  : 0000FFE1-0000-1000-8000-00805F9B34FB
```

### 앱 → ESP32 명령

```json
{ "type": "command", "text": "즉석밥 데우기", "source": "voice" }
{ "type": "confirm", "sequence_id": "seq_001", "approved": true }
{ "type": "emergency_stop" }
```

### ESP32 → 앱 상태

```json
{ "type": "suggestion", "sequence_id": "seq_001", "label": "즉석밥 데우기", "steps": ["BT-08", "BT-05"] }
{ "type": "sensor", "current_ma": 320, "sound_db": 45, "status": "running", "completed_steps": 1 }
{ "type": "result", "sequence_id": "seq_001", "success": true }
```

---

## UART 프로토콜 (ESP32 ↔ RPi5)

- 보드레이트: 115200
- 포맷: JSON newline-delimited (`\n` 구분)

### ESP32 → RPi5

```json
{ "type": "intent", "text": "즉석밥 데우기", "timestamp": 1723700000 }
{ "type": "sensor_log", "current_ma": 320, "sound_db": 45 }
```

### RPi5 → ESP32

```json
{ "type": "sequence", "id": "seq_001", "label": "즉석밥 데우기", "buttons": ["BT-08", "BT-05"] }
{ "type": "abort" }
```

---

## UART 프로토콜 (RPi5 ↔ RPi4)

### 링크 인증 (2026-10-12, 무선 전환 뒤)

링크가 TCP(`socket://<RPi4>:7000`)가 되면서 같은 망의 누구나 RPi4에 `execute`·`dev_motion`을 보낼 수
있었다. 두 보드에 같은 짝 키 `SIMPLELAY_LINK_KEY`(16자 이상, 짧으면 링크를 열지 않는다)를 두면 아래 봉투로만
주고받는다(`rpi/services/link_auth.py`). 정규형은 `mac`을 뺀 문서의
`json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=False)`, MAC은 HMAC-SHA256 hex다.

1. RPi5 `hello`: 새 클라이언트 난수 `cn`(16바이트 hex)을 싣고 K로 서명한다.
2. RPi4: 올바른 hello마다(이미 쓴 `cn`은 버림) 새 서버 난수 `sn`을 고르고
   세션 키 `sk = HMAC-SHA256(K, "simplelay-link-v1|" + cn + "|" + sn)`를 만든다. hello 답의 첫 프레임
   `act_info`에 `cn`·`sn`을 싣고 K로 서명한다(이 hello에 묶인다). 이어지는 `estop_state`부터는 세션 프레임이다.
3. 그 뒤 양방향 모든 프레임: `seq`(방향마다 세션 안에서 1부터 엄격히 증가) + `mac = HMAC(sk, 정규형)`.

```json
{"type":"hello","cn":"1f0c3a9e5b7d24c68a0e9f13b2d4c657","mac":"237dfbae…21efad"}
{"type":"act_info","execute_protocol":2,"motion":"mock",…,"cn":"1f0c3a9e5b7d24c68a0e9f13b2d4c657","sn":"b5289081d3d659397bbc9ad1dce4c57c","mac":"2b1ede4b…ed2e9bbb"}
{"type":"execute","sequence_id":"seq_001","buttons":["BT-08","BT-05"],"appliance_id":"microwave","seq":1,"mac":"1225ae0d…c5f51cc7"}
```

- 받는 쪽은 서명 없음·MAC 틀림·`seq` 되돌림 프레임을 **버리고 답하지 않는다**(경고 로그는 10초에 한 번).
  `abort`·`estop_ack`도 같다 — 위조 정지도 공격 경로라 서명 없는 정지 예외를 두지 않는다.
- RPi5는 서명된 hello 답을 받기 전까지 링크를 내려 둔다(`/health actuator_ready=false`, 실행 412).
  3초 안에 답이 없거나 서명 없는 답이 오면 이유를 "RPi4 인증 실패 — 두 보드의 SIMPLELAY_LINK_KEY가 같은지
  확인"으로 두고(`/dev/state real_motion_reason`에도 보인다) 재연결과 같은 늘어나는 간격으로 hello를 다시 보낸다.
- 재연결은 새 hello = 새 세션이다. RPi4는 세션 전에는 아무것도 보내지 않는다(켜질 때의 자발 알림도).
- 한쪽만 키가 있으면 링크가 열리지 않는다(fail closed). 두 쪽 다 없으면 종전과 줄까지 같고 시작 때 경고 한 번.
- 키는 로그·응답·기록에 남기지 않는다. 기밀성(암호화)은 없다 — 프레임 내용은 망에서 보인다.

### RPi5 → RPi4

```json
{ "type": "execute", "sequence_id": "seq_001", "buttons": ["BT-08", "BT-03", "BT-05"], "appliance_id": "microwave" }
{ "type": "abort" }
{ "type": "inject_failure", "button_index": 0, "attempts": 1 }
{ "type": "clear_failure" }
{ "type": "estop_ack" }
{ "type": "hello" }
{ "type": "rehearsal", "action": "appliance_done", "request_id": "a1b2c3", "appliance_id": "washer", "inputs": ["power", "beep"] }
{ "type": "rehearsal", "action": "outlet_estop", "request_id": "a1b2c4", "hold_button": false }
{ "type": "rehearsal", "action": "outlet_estop_release", "request_id": "a1b2c5" }
```

`hello`(2026-10-06 평가 C1·B3): RPi5 `ActClient.start()`가 한 번 보낸다(RPi5가 다시 켜졌을 때 포함). RPi4는
`act_info`와 `estop_state {…, "announce": true}`로 답하고, RPi4가 켜질 때도 같은 두 줄을 스스로 한 번 보낸다.
RPi5는 답을 받기 전 걸림 상태를 **모름**(`estop_latched=null`)으로 두고 '풀림'으로 보지 않는다 — 내장 가전 실행은 412
"비상정지 상태를 확인하는 중이에요 — RPi4 응답을 기다려요"이고, 상태를 볼 때마다 2초 간격으로 `hello`를 다시 보낸다.
`announce:true`인 `estop_state`는 `estop_ack`의 답으로 치지 않는다.

`clock_probe {probe}`(사건 신선도 기준점 규약 1, 3차 평가 M1 2026-10-14): `act_info`에 `"clock_protocol": 1`(이상)을 알린
RPi4에만, `act_info`를 받을 때마다 한 번 보낸다. RPi4는 곧바로 `clock_ref {probe, clock_id, t_monotonic_ns}`(그 순간
**RPi4 프로세스의** 단조 시각과 그 시계 식별자)로 답한다. RPi5는 탐침을 보내기 직전 자기 단조 시각 `L0`을 적어 두고,
그 RPi4 시계의 시각 `x`를 `L0 + (x - t_monotonic_ns/1e9)`로 옮긴다 — RPi4가 답을 만든 실제 순간은 `L0` 이후이므로 옮긴
시각은 실제보다 이르거나 같고, 사건 나이는 길게(최대 왕복 시간만큼) 잡힌다(보수적). 링크가 끊기면 기준점을 버린다. 옛 RPi4
(`clock_protocol` 없음)에는 보내지 않고, 그 링크의 사건은 신선도 근거가 없어 자동 실행을 보류한다(`rpi/services/event_clock.py`).

```json
{ "type": "clock_probe", "probe": "81c9805dd4184535" }
{ "type": "clock_ref", "probe": "81c9805dd4184535", "clock_id": "f445ea42be9e405f", "t_monotonic_ns": 279831562000000 }
```

`rehearsal`(2026-10-06, UART 리허설): 시연 장면 ④⑤(가전 끝·콘센트 비상 버튼)를 보드 구성에서 연습하는 주입. RPi4는
**모션이 mock이고 콘센트 모듈이 가짜(`SIMPLELAY_OUTLET_PORT=fake`)이거나 없을 때만** 받는다(`act_info.rehearsal=true`).
그 밖이면 `rehearsal_result {ok:false, reason:"rehearsal_refused"}`. `appliance_done`은 같은 융합 규칙으로 `source:"injected"`
프레임을 보내고, `outlet_estop`은 가짜 모듈의 버튼을 눌러 실물과 같은 `estop` 이벤트 경로를 탄다(`hold_button:true`면 눌린 채 —
`estop_ack`가 거절된다). RPi5는 `SIMPLELAY_ACT_MODE=uart`에서 `SIMPLELAY_UART_REHEARSAL=1`일 때만 `POST /demo/appliance-done`·
`POST|DELETE /demo/outlet-estop`을 열고(아니면 404), RPi4가 리허설 가능하다고 알리지 않았으면 409다. 응답의 `injected_in`은
`rpi4_uart`, 비상 버튼 응답 문구에 "(시연 주입: RPi4 가짜 콘센트 모듈 …)"이 붙는다.

`estop_ack`(2026-10-05): 콘센트 모듈 비상정지로 RPi4가 **걸린**(`estop_latched`) 뒤, 사람이 버튼을 풀고 해제를
확인했다는 뜻(RPi5 `POST /stop/ack`). RPi4는 모듈 `status`로 버튼을 확인해 풀렸을 때만 모듈에 `estop_reset`을 보내고
자기 걸림을 푼다. 답은 `estop_state` 하나(아래 "콘센트 모듈 링크" 절).

`execute`의 `appliance_id`는 **필수**다(2026-10-07, 평가 H3 — execute 규약 2, `act_info.execute_protocol: 2`).
RPi4는 이 대상의 CT 채널(`SIMPLELAY_OUTLET_CHANNELS`, 대응이 비면 채널 0은 전자레인지만)로 L3 판정기·잔여 전류
꼬리·정지 대기 전력 확인을 고른다(`rpi4/services/target_binding.py`). 그래서 전자레인지 채널 변화로 세탁기·인터폰
실행이나 정지가 확인되지 않는다. 규칙:
- 대상이 없는 옛 프레임 → 누르지 않고 `{"type":"error","sequence_id":…,"reason":"target_required","detail":…}`.
  RPi5·RPi4는 같은 판으로 배포한다(새 RPi5 → 옛 RPi4는 옛 RPi4가 모르는 키를 무시해 전자레인지 채널로 판정한다 —
  `act_info`에 `execute_protocol`이 없으면 옛 RPi4다).
- `SIMPLELAY_L3_MODE=real`인데 대상 CT 채널이 없음 → 누르기 전 `error`(`target_unbound`). 전력으로 동작을 볼 수
  없는 가전은 `SIMPLELAY_L3_NONE_TARGETS`(예: `intercom`)에 적으면 판정 없이(`operation_confirmed: null`) 실행한다.
- `hold.appliance_id`가 있으면 실행 대상과 같아야 한다(다르면 메시지 전체를 버린다). 없으면 실행 대상으로 채운다.
- `result`에 `appliance_id`가 실린다. RPi5는 보낸 대상과 다르면 그 결과를 쓰지 않는다(`ActLinkError`).
- RPi5는 대상이 없으면 보내지 않는다. `appliance_id` 없는 옛 API 요청은 규칙 해석과 같은 내장 갠트리 가전
  (`microwave`)을 **명시해** 싣는다(`rpi/api/service.py` `BUILTIN_GANTRY_APPLIANCE`).
- L2(수용 판정)는 대상과 무관하게 운영 경로(RPi4 `act_main`)에 판정기가 없다 — 결과에 L2 판정이 없다.

`execute`의 `targets`는 **선택** 필드다(2026-09-28). 보정(`PUT /appliances/{id}/calibration`)으로
갠트리 좌표가 기록된 버튼만 싣는다. 좌표가 하나도 없으면 키 자체를 넣지 않는다 —
종전 `execute` 줄과 바이트까지 같다.

```json
{ "type": "execute", "sequence_id": "seq_002", "buttons": ["즉석밥", "시작"],
  "targets": { "즉석밥": { "x_mm": 42.0, "y_mm": 18.5 },
               "시작":   { "x_mm": 60.0, "y_mm": 120.0, "press_ms": 150 } } }
```

- 키는 `buttons`에 있는 이름이어야 한다. `x_mm`·`y_mm`는 유한한 수, `press_ms`는 선택(1 이상 정수).
- 하나라도 어긋나면(시퀀스에 없는 버튼, 한쪽 좌표만, 문자열·NaN) RPi4는 **메시지 전체를 무시**한다 —
  틀린 좌표 하나가 엉뚱한 버튼을 누르게 하므로 일부만 받아들이지 않는다.
- RPi4가 mock 모션이면 좌표는 기록만 되고 동작은 종전과 같다. 실제 모션 어댑터(`SIMPLELAY_MOTION_MODE=serial`)는
  좌표 없는 버튼이 **하나라도** 있으면 아무것도 누르기 전에 거절하고 `error`(`actuator_fail`)로 답한다.
- 수치 예시는 형식 설명용이며 실물 좌표가 아니다.

**정지 버튼 대기·보관(2026-09-30, 실물 미검증).** `execute`의 `hold`는 **선택** 필드다. 가전에
정지 버튼(mm)과 보관 위치가 등록돼 있을 때만 RPi5가 싣는다.

```json
{ "type": "execute", "sequence_id": "seq_004", "buttons": ["즉석밥", "시작"], "targets": { … },
  "hold": { "appliance_id": "microwave", "stop_button": "취소", "stop_x_mm": 200.0, "stop_y_mm": 150.0,
            "stop_presses": 2, "park_x_mm": 20.0, "park_y_mm": 185.0, "press_ms": 150 } }
{ "type": "abort" }                      // 정지 버튼 위 대기 중이면 = 정지 버튼 누름(가전 정지)
{ "type": "abort", "scope": "drive" }    // 구동부만 멈춘다 — 정지 버튼을 누르지 않는다
{ "type": "verify_pass", "sequence_id": "v_001",
  "targets": [ { "button": "즉석밥", "x_mm": 100.0, "y_mm": 60.0 },
               { "button": "보관 위치", "x_mm": 20.0, "y_mm": 185.0, "kind": "park" } ] }
```

- `hold`: `stop_presses` 1~3, 좌표는 0 이상 유한한 수, 정지 좌표와 보관 좌표가 같으면 안 된다. 하나라도
  어긋나면 `targets`와 같은 규칙으로 **메시지 전체를 무시**한다.
- 시퀀스가 성공하고 가전 동작이 확인되면(L3 `operation_confirmed=true`, 또는 RPi4가 모의) RPi4는 Z를 올린 채
  정지 버튼 위로 가서 기다린다. 확인이 없으면 대기하지 않고 그 사실만 보고한다.
- 대기 중 `abort`(scope 생략 = `appliance`)는 정지 버튼을 `stop_presses`번 누른다. 같은 대기에서 두 번째 요청은
  다시 누르지 않는다. `scope:"drive"`는 모션만 멈추고 대기를 잠근다.
- 대기 중 새 `execute`가 오면 대기를 풀고 실행한다. 누르거나 보관 이동 중이면 `error`(`hold_busy`).
- `verify_pass`: 좌표 위를 차례로 **이동만** 한다(실제 어댑터는 `move_to`만). 실행·대기 중이면 `error`
  (`busy`·`hold_active`), 모션 부품이 없으면 `verify_unavailable`.

`inject_failure`/`clear_failure`는 리허설 장치(POST/DELETE /demo/inject-failure)의
UART 전달판 — 검증이 RPi4에서 일어나는 실기기 구성에서도 "일부러 실패시켜도
스스로 재시도" 장면을 같은 API로 연출한다. abort처럼 응답 없는 단방향.

**개발자 조작 `dev_motion`(2026-10-10, 개발자 조작 규약 1 — 실물 미검증).** 폰 개발자 도구의 홈·조그·누름·정지를
실제 모션 경로(RPi5 `/dev` → RPi4 → 모션 MCU `firmware-motion-corexy`)로 보낸다. **기본은 꺼짐(모의).** RPi5는
`SIMPLELAY_DEV_MODE=1`과 `SIMPLELAY_DEV_REAL_MOTION=1`이 **둘 다** 켜졌을 때만 실물 어댑터를 물고, 그때도 RPi4가
`act_info`에 `"motion": "serial"`과 `"dev_motion_protocol": 1`(이상)을 알렸을 때만 보낸다. RPi4는 실제 모션
어댑터(`SIMPLELAY_MOTION_MODE=serial`)일 때만 `dev_motion_protocol`을 알리고 이 프레임을 받는다.

```json
{ "type": "dev_motion", "request_id": "d3f1a9c0b2e4d5f6", "op": "home" }
{ "type": "dev_motion", "request_id": "d3f1a9c0b2e4d5f7", "op": "jog", "axis": "x", "delta_mm": -1.0 }
{ "type": "dev_motion", "request_id": "d3f1a9c0b2e4d5f8", "op": "press", "label": "BT-05" }
{ "type": "dev_motion", "request_id": "d3f1a9c0b2e4d5f9", "op": "status" }
{ "type": "dev_motion", "request_id": "d3f1a9c0b2e4d5fa", "op": "stop", "reason": "user_stop" }
```

- 요청 하나에 답(`dev_motion_result`) 하나. **재전송·자동 재개는 없다.** RPi5는 기한(홈 90 s, 조그·누름 20 s,
  상태 5 s, 정지 3 s — 호스트 박자, 측정 필요) 안에 답이 없으면 그 조작을 실패로 보고 정지를 보낸다.
  늦게 온 답은 요청마다 새 `request_id`라 다음 조작의 답으로 쓰이지 않는다.
- `jog`: X·Y 상대 이동 한 번(`delta_mm`, 0 아님). RPi4는 MCU가 보고한 A·B 카운트로 현재 위치를 구해 절대 목표
  하나로 `move`를 보낸다(조그 CLI와 같다). 소프트 리밋은 RPi4 `SIMPLELAY_MOTION_*` 설정. |delta| 상한은 RPi5
  `SIMPLELAY_DEV_REAL_MAX_STEP_MM`(기본 1 mm, 설정해도 5 mm까지)과 RPi4 울타리 10 mm. Z는 솔레노이드라
  `z_jog_unsupported`.
- `home`: MCU `home`(스톨 원점). 조그·누름은 원점 전이거나 정지로 끊긴 뒤면 `not_homed`(재개 없음).
- `press`: **지금 위치**에서 솔레노이드 시간 누름 한 번(`SIMPLELAY_MOTION_PRESS_MODE=duration`, 구동+유지 ≤ 800 ms —
  펌웨어 `SOLENOID_ON_MAX_MS`와 같다). `label`은 기록용 버튼 id다 — 버튼 좌표로 이동하지 않는다.
- `status`: MCU 위치·원점 상태(움직이지 않음). 폰의 '센서 읽기'가 실물에서는 위치를 보인다.
- `stop`: 어떤 거절에도 걸리지 않는다. RPi4는 MCU에 `stop`을 쓰고(`ok:true` = **정지 줄을 썼다**), 규약 2부터는 답에
  정지 확인 단계 `stop_level`·`ack_ms`를 싣는다(아래 "정지 확인 단계"). 최종 권한은 물리 E-STOP이다. 진행 중 조작은
  `stopped`로 끝난다. 일반 `abort`도 진행 중인 개발자 조작을 멈춘다. RPi4가 `dev_motion_protocol`을 알리지 않으면
  RPi5는 대신 `abort {scope:"drive"}`를 보낸다.

```json
{ "type": "dev_motion_result", "request_id": "d3f1a9c0b2e4d5f7", "op": "jog", "ok": true, "homed": true, "x_mm": 11.0, "y_mm": 20.0 }
{ "type": "dev_motion_result", "request_id": "d3f1a9c0b2e4d5f7", "op": "jog", "ok": false, "reason": "not_homed", "detail": "…", "moved": false }
{ "type": "dev_motion_result", "request_id": "d3f1a9c0b2e4d5f7", "op": "jog", "ok": false, "reason": "motion_alarm", "detail": "…", "moved": null }
```

- `moved:false` = **움직이기 전** 거절. RPi5는 정지를 따로 보내지 않고 세션을 유지하며 `reason`을 API `detail.code`로
  그대로 낸다. `moved:null` = 움직였을 수 있음(알람·기한 초과·정지·MCU 재시작). RPi5는 정지를 보내고
  `command_error`로 답한다.
- RPi4의 움직이기 전 거절: `dev_unsupported`(실제 모션 어댑터 없음) · `estop_latched` · `outlet_offline` ·
  `motion_not_ready` · `execution_busy`(일반 실행·확인 주행·정지 버튼 대기 중) · `dev_busy`(다른 개발자 조작 중) ·
  `bringup_firmware`(MCU `ready.fw`가 `-bringup`으로 끝남 — 방향 시험 빌드) · `not_homed` · `step_too_large` ·
  `z_jog_unsupported` · `soft_limit` · `press_mode_unsupported` · `press_too_long` · `motion_config` · `bad_args` ·
  MCU 거절(`z_cooldown` 등).
- 개발자 조작이 진행 중이면 RPi4는 `execute`·`verify_pass`를 `error {reason:"dev_busy"}`로 거절한다(RPi5 중재자가 먼저 막는다).

**정지 확인 단계(2026-10-13 — 개발자 조작 규약 2·정지 보고 규약 1, 가짜 MCU로만 시험, 실물 미검증).** 정지가 어디까지
확인됐는지를 셋으로 나눠 올린다([계획](계획-정지-확인-2026-10-12.md)).

| `stop_level` | 근거 | `ack_ms` |
|---|---|---|
| `sent` | RPi4가 모션 MCU에 `stop` 줄을 썼다(모의 모션이면 컨트롤러에 넘겼다). MCU가 받았는지는 모름 | null |
| `mcu_ack` | MCU가 같은 `id`로 `{"ok":true}`를 답했다 | 보낸 뒤 응답까지 ms |
| `verified` | MCU 응답 뒤 `status` 두 번(약 100 ms 간격)의 엔코더 a·b가 같다(모터 축 기준 — 벨트 미끄럼은 안 보인다) | 위와 같다 — 보낸 뒤 **MCU 응답까지**이지 멈춤 확인(status 두 번)까지의 시간이 아니다 |
| null | 멈출 것이 없었다(유휴) 또는 정지 줄을 쓰지 못했다 | null |

- RPi4는 정지 줄을 **먼저** 쓰고(기다리지 않는다), 확인은 따로 기다린다 — MCU 응답 기한 0.3 s, 멈춤 확인 status 두 번
  (호스트 박자, 측정 필요). 진행 중 명령의 읽기 루프가 정지 응답을 버리지 않고 기록한다. 확인을 기다리는 동안에도
  읽기 루프는 다음 프레임을 처리한다. 확인 실패 이유는 `stop_detail`(선택)에 싣는다.
- `dev_motion stop`의 답: `{"type":"dev_motion_result","request_id":…,"op":"stop","ok":true,"stop_level":"mcu_ack","ack_ms":12}`.
- `abort`에 `stop_id`(문자열 1~64자)가 있으면 RPi4는 `stop_report`로 답한다. 없으면(옛 RPi5) 종전처럼 답하지 않는다.
  `target`: `run`(일반 실행 중) · `dev`(개발자 조작 중) · `hold`(정지 버튼 대기 중 — 가전 정지 결과는 `progress phase
  "hold"`가 따로 알린다) · `idle`(멈출 것 없음, `stop_level:null`).
- RPi4는 `act_info`에 `"stop_report_protocol": 1`을 알린다.
- RPi5(`rpi/services/stop_confirm.py`): **확인(`confirmed`)은 `mcu_ack` 이상일 때만**이다. 단계가 없는 답(옛 RPi4 —
  개발자 조작 규약 1)·모르는 값·`abort drive` 대체 경로는 `sent`로 읽는다. `POST /stop`은 `abort`를 먼저 보내고(기다리지
  않음) 보고를 최대 약 1.5 s 기다린다 — RPi4가 `stop_report_protocol`을 알리지 않았으면 기다리지 않고 `sent`. 응답에
  `stop_level`·`stop_ack_ms`·`stop_target`·`stop_confirmed`·`stop_detail`·`stop_job_id`, `GET /status`에 `last_stop_level`·
  `last_stop_ack_ms`·`last_stop_job_id`(새 실행이 시작되면 null). `stop_job_id`·`last_stop_job_id`는 그 정지가 멈춘 실행(요청 때
  실행 중이었을 때만, 아니면 null)이다 — 보고를 기다리는 사이 새 실행이 시작되면 RPi5는 그 보고를 `/status`에 남기지 않고,
  폰·키오스크는 자기 job과 같을 때만 단계를 쓴다(외부 평가 2026-10-13 H1). 두 필드는 새 서버면 **늘 있고**(실행 중이
  아니었으면 명시적 null) — 폰(`/stop`·`/status`)·키오스크(`/status`)는 필드가 있으면 값이 자기 job과 같을 때만 싣고, null·다른
  job은 버린다. 필드 자체가 없는 응답(옛 서버)에만 종전처럼 싣는 호환을 둔다 — 이때는 단계의 출처가 그 job인지 증명하지 못한다
  (2차 평가 M-N1). 키오스크는 `/stop` 응답을 읽지 않는다(`/status`만). `POST /dev/stop`·세션 끝(`/dev/sessions/{id}/end`)은 `stop_level`·
  `stop_ack_ms`를 싣고, 실물이면 `confirmed`를 단계로 정한다(`sent`면 false지만 잠그지 않는다 — 잠금은 RPi4에 닿지
  못했을 때). 모의 개발자 어댑터는 단계 없이 종전처럼 `confirmed:true`.

```json
{ "type": "abort", "stop_id": "s7c1d2e3f4a5" }
{ "type": "stop_report", "stop_id": "s7c1d2e3f4a5", "target": "run", "stop_level": "verified", "ack_ms": 9 }
```

### RPi4 → RPi5

```json
{ "type": "act_info", "done_watch": ["washer", "microwave"], "outlet": "fake", "motion": "mock", "rehearsal": true }
{ "type": "act_info", "done_watch": [], "outlet": "real", "motion": "serial", "rehearsal": false, "execute_protocol": 2, "dev_motion_protocol": 2, "stop_report_protocol": 1, "clock_protocol": 1 }
{ "type": "dev_motion_result", "request_id": "d3f1a9c0b2e4d5f6", "op": "home", "ok": true, "homed": true, "x_mm": 0.0, "y_mm": 0.0 }
{ "type": "rehearsal_result", "request_id": "a1b2c3", "ok": true, "action": "appliance_done", "source": "injected", "frame": { "…": "…" } }
{ "type": "ack", "sequence_id": "seq_001", "step": "BT-08", "status": "done" }
{ "type": "result", "sequence_id": "seq_001", "success": true, "retry": 0, "outcome": "success" }
{ "type": "result", "sequence_id": "seq_002", "success": false, "retry": 0, "outcome": "stopped" }
{ "type": "result", "sequence_id": "seq_003", "success": false, "retry": 2, "outcome": "safety_stop" }
{ "type": "error", "sequence_id": "seq_001", "reason": "actuator_fail" }
{ "type": "error", "sequence_id": "seq_005", "reason": "motion_not_ready", "detail": "모션 MCU 연결 확인 전(…)" }
```

`error`의 `motion_not_ready`(2026-09-29): `SIMPLELAY_MOTION_MODE=serial`에서 모션 MCU 연결 확인(`status` 성공) 전에
`execute`가 오면 RPi4는 누름을 시도하지 않고 바로 이것으로 거절한다. RPi4는 배경에서 1→2→4…30 s 간격으로 다시
연결한다. 옛 RPi5는 `reason`을 문자열로만 기록한다.

`result`의 `outcome`(2026-09-29 추가) — **어떻게 끝났는지**. 예전에는 정지 요청으로 멈춘 것과
검증 실패로 안전 정지한 것이 모두 `success=false` 하나라 RPi5가 둘을 가를 수 없었다.

| outcome | 뜻 | success |
|---|---|---|
| `success` | 시퀀스를 끝까지 성공 | `true` |
| `stopped` | `abort`(긴급 정지)를 받아 버튼·재시도 경계에서 멈춤. 실패가 아니다 | `false` |
| `safety_stop` | 재시도 소진·L2/L3 불확인·센서 불가로 RPi4가 스스로 안전 정지 | `false` |
| `failed` | 그 밖의 실패(이유 불명) | `false` |

- **하위 호환:** `success`는 그대로 보낸다. 옛 RPi5는 `outcome`을 무시한다. `outcome`이 없는 옛 RPi4의
  `success=false`는 RPi5가 `failed`로 적는다 — 정지로 추측하지 않는다.
- 모르는 값이거나 `success`와 모순(`success=true`인데 `stopped` 등)이면 RPi5는 `outcome`을 버리고
  `success`만 믿는다.
- RPi5는 이 값을 `/status`·SSE `status` 이벤트의 `last_outcome`, `/history`·CSV의 `outcome`으로 내보낸다.
  `last_status`(`succeeded`/`safety_stopped`/`failed`)는 옛 클라이언트용으로 종전 값을 유지한다.
- **물리 정지 확인이 아니다.** 실행 루프가 멈춘 이유일 뿐, 모터가 실제로 멈췄다는 보고는 별도다.
- ~~멈춘 버튼·눌림 개수는 여전히 프레임에 없다(`retry`만 집계).~~ 2026-09-29부터 아래 `button_results`로 보낸다.

`result` 확장 필드(2026-09-29 추가, G1·G2) — 옛 RPi5는 모르는 키를 무시한다.

```json
{ "type": "result", "sequence_id": "seq_004", "success": true, "retry": 1, "outcome": "success",
  "button_results": [
    { "button": "즉석밥", "ok": true, "attempts": 2, "layer": null,
      "corrections": [ { "retry_number": 1, "xy_adjustment_required": true, "increase_press_depth": true } ] },
    { "button": "시작", "ok": true, "attempts": 1, "layer": null, "corrections": [] } ],
  "operation_confirmed": true, "operation_detail": "모의 전력 센서 — 시작 확정 …",
  "operation_source": "mock", "execution_mode": "mock" }
```

| 필드 | 값 | 뜻 |
|---|---|---|
| `button_results` | 배열(실제로 돈 버튼만, 요청 시퀀스의 앞부분) | 버튼마다 `ok`·`attempts`(재시도 포함 누름 수, 1 이상)·`layer`(실패 층 `L1`/`L2`/`L3`, 성공이면 null)·`corrections`(재시도 누름마다의 정성 보정) |
| `operation_confirmed` | `true` / `false` / `null` | L3(가전 동작) 판정. **`null` = 판정기 없음(`SIMPLELAY_L3_MODE=off`) 또는 판정 전 정지** — "안 돌았다"(`false`)와 다르다 |
| `operation_detail` | 문자열 / `null` | 판정 사유 한 줄 |
| `operation_source` | `real` / `mock` / `null` | 판정 입력이 실물 전력 센서인가, 합성 파형(모의)인가 |
| `execution_mode` | `real` / `mock` / `unknown` | RPi4 모션 어댑터가 스스로 밝힌 실행 환경 |
| `abort_reason` | `motion_alarm: <코드>` / `motion_reset` / `motion_timeout` / `motion_not_ready` / `motion_position_mismatch` / `motion_link_error` (없으면 필드 없음) | 2026-10-14. 모션 걸림·재시작·기한 초과·준비 안 됨·연결 끊김으로 **재시도 없이** 멈춘 원인. 눌림(L1) 확인 실패와 가른다. RPi5는 `motion_…` 모양만 받아 `/status` `last_abort_reason`·`/history` `abort_reason`으로 올린다 |

- RPi5는 `button_results`를 **엄격하게** 읽는다: 버튼 이름이 요청 순서와 다르거나, 성공이라면서 전 버튼을
  덮지 않거나, 마지막이 아닌 칸이 실패면 **통째로 버리고** 종전처럼 집계 `retry`로 합성한다(성공이면 마지막
  버튼에 싣는다 — 어느 버튼이 재시도했는지는 모름).
- 재시도 수는 `/history`·CSV `retry_count`(버튼별 `attempts - 1`의 합), `/status`·SSE `last_retry_count`로
  나간다. 버튼 결과가 없으면(ThinQ 단계 등) `last_retry_count`는 `null`이다(0으로 지어내지 않음).
- L3는 `/status`·SSE `last_operation_confirmed`·`last_operation_source`·`last_operation_detail`,
  `/history`·CSV `operation_confirmed`로 나간다.
- **확인 수준(`confirmation`)을 `operation_confirmed`로 올리는 것은 `operation_confirmed=true` +
  `operation_source=real`뿐이다.** `mock`의 `true`는 `reported`로 남는다(합성 입력은 가열 근거가 아님).
  `source`가 없으면 `mock`으로 본다.
- RPi5의 UART 컨트롤러는 실행 환경을 모르므로(`unknown`) `execution_mode` 보고를 이번 실행의 모드로 쓴다.
  시뮬레이터처럼 스스로 `mock`이라고 밝힌 컨트롤러는 보고로 `real`이 되지 않는다.
- 시나리오 `cook_then_air`의 **일반(실물) 제안은 `execution_mode=real` + L3 실물 확인일 때만** 생긴다.
  모의 실행은 종전대로 시연 제안(`is_demo`)이다.
- RPi4 `SIMPLELAY_L3_MODE`: `off`(기본, `null`) · `mock`(합성 전력 파형, `SIMPLELAY_L3_MOCK_OUTCOME=
  confirmed|unconfirmed`) · `real`(CT·ADS1115 리더가 아직 없어 **기동 거절**). 시뮬레이터도 같은 변수를 읽는다.

`progress`(2026-09-29 추가, 선택) — RPi4가 **누름 시도의 단계마다** 보내는 진행 보고. **결과가 아니다.**
실모드 디지털 트윈(`GET /twin`)과 세션 기록(`SIMPLELAY_SESSION_LOG_PATH`)이 쓴다.

```json
{ "type": "progress", "sequence_id": "seq_004", "n": 1, "phase": "move", "button": "즉석밥", "step_index": 0,
  "attempt": 1, "target": { "x_mm": 10.0, "y_mm": 20.0 }, "correction": null,
  "execution_mode": "real", "t_monotonic_ns": 1234567890123 }
{ "type": "progress", "sequence_id": "seq_004", "n": 2, "phase": "press", "button": "즉석밥", "step_index": 0,
  "attempt": 1, "ok": true, "position": { "a_counts": 300, "b_counts": -100, "z_counts": 0,
  "x_mm": 10.0, "y_mm": 20.0, "source": "mcu_event", "t_monotonic_ns": 1234567990123 }, ... }
{ "type": "progress", "sequence_id": "seq_004", "n": 3, "phase": "verify", "button": "즉석밥", "attempt": 1, "pressed": false, ... }
{ "type": "progress", "sequence_id": "seq_004", "n": 4, "phase": "retry", "button": "즉석밥", "attempt": 2,
  "correction": { "retry_number": 1, "xy_adjustment_required": true, "increase_press_depth": true }, ... }
```

| phase | 언제 | 추가 필드 |
|---|---|---|
| `retry` | 재시도 누름 직전(보정 요청) | `correction`(정성 값, 거리 없음) |
| `move` | 누름 명령을 모션 어댑터에 넘기기 직전 | `target`(명령 좌표 mm, 없으면 null), `correction` |
| `press` | 어댑터가 반환(이동·Z 누름·복귀 끝) 또는 예외 | `ok`, `error`(실패 시), `position`(MCU 위치 보고가 있을 때만) |
| `verify` | L1 누름 검증 직후 | `pressed` |
| `accept` | L2 수용 확인 직후(검증기가 있을 때만) | `passed` |

- 공통: `n`(이 실행 안 순번 1..), `step_index`(시퀀스 칸), `attempt`(그 버튼의 누름 횟수), `execution_mode`
  (RPi4 어댑터 선언), `t_monotonic_ns`(**RPi4의** `time.monotonic_ns()` — 원시 기록기 `t_monotonic_ns`·모션 줄
  기록 `mono_ns=`와 같은 시각축).
- `position`은 모션 MCU가 엔코더 카운트를 보고했을 때만 있다(아래 MCU `position` 이벤트·`status` 응답).
  `x_mm`·`y_mm`는 RPi4에 기구 값이 있을 때만 계산하고, 없으면 null(카운트만). **지어내지 않는다.**
- 순서: 같은 실행의 `progress`는 모두 `result`보다 **먼저** 도착한다(RPi4가 결과 전에 쓴다).
- **하위 호환:** 옛 RPi5 `ActClient`는 `result`/`error`/`alert`/`alert_cleared` 밖의 `type`을 무시하고, ESP32
  노드 펌웨어(`firmware-node`)도 모르는 `type`을 무시한다(둘 다 코드 확인). 그래서 **기본 켜짐**이며
  RPi4 `SIMPLELAY_ACT_PROGRESS=0`으로 끈다. 새 RPi5도 `progress`로 실행을 끝내지 않는다 — 결과는 `result`뿐.
- 트래픽: 버튼 하나(재시도 없음)에 3줄, 한 줄 약 250~400바이트. 115200bps에서 누름당 수십 ms 미만.

RPi5 세션 기록(2026-09-29): RPi5 `ActClient`는 보내고 받은 **모든 줄**을 프레임 탭(`rpi/services/link_tap.py`)에
남긴다 — 링 버퍼(최근 2000개) + `SIMPLELAY_SESSION_LOG_PATH`가 있으면 JSONL 이어 쓰기(`{date}` 치환으로 하루 한
파일, `SIMPLELAY_SESSION_LOG_MAX_BYTES`·`_BACKUPS` 크기 회전). 한 줄 = `{"kind":"frame","n","t_wall",
"t_monotonic_ns"(RPi5 시각),"direction":"hub_to_act"|"act_to_hub","type","sequence_id","message"}`. 키 이름에
key·token·secret·password·authorization·cookie가 들어간 값과 설정된 API 키·개발자 토큰 문자열은 `[redacted]`.

정지 대기·확인 주행 보고(2026-09-30): 둘 다 `progress` 프레임이라 옛 RPi5는 무시한다. 결과가 아니다.

```json
{ "type": "progress", "sequence_id": "seq_004", "n": 3, "phase": "hold", "hold_state": "hovering_stop",
  "stop_outcome": null, "detail": "'취소' 위에서 Z를 올린 채 기다리는 중이에요", "stop_button": "취소",
  "stop_presses": 2, "presses_done": 0, "stop": {"x_mm": 200.0, "y_mm": 150.0},
  "park": {"x_mm": 20.0, "y_mm": 185.0}, "target": {…}, "park_reason": null, "appliance_id": "microwave",
  "probe_source": "mock", "sim_phase": "waiting_above_stop", "execution_mode": "mock", "t_monotonic_ns": 0 }
{ "type": "progress", "sequence_id": "v_001", "n": 2, "phase": "verify", "index": 0, "button": "즉석밥",
  "kind": "button", "status": "reached", "target": {"x_mm": 100.0, "y_mm": 60.0}, "detail": "…" }
{ "type": "verify_result", "sequence_id": "v_001", "ok": true,
  "targets": [ { "index": 0, "button": "즉석밥", "status": "reached", … } ], "execution_mode": "mock" }
```

- `hold_state`: `hovering_stop` | `stopping` | `parking` | `parked` | `fault` | `released` | null(대기 안 함).
- `stop_outcome`: `stopped`(누른 뒤 전력 하강 확인 — 모의에서는 모의 가전이 꺼짐) | `requested_unconfirmed`
  (확인 시간 안에 하강 없음, 전력 리더가 없으면 늘 이것) | `drive_fault`(구동부 이상으로 누르지 못함) | null.
- `verify` 단계 `status`: `moving` | `reached`(모션이 도착을 응답 — 버튼 위인지는 사람이 확인) | `failed` | `skipped`.

`result`/`error`/`ack`는 모두 RPi5가 보낸 `execute`에 대한 응답이다. 아래 두 개는
유일하게 RPi5가 요청하지 않아도 RPi4가 스스로 보내는 메시지 — 마이크가 물려 있는
RPi4 쪽에서 화재/가스 경보음을 감지했을 때 즉시 푸시된다(승인 절차 없음, 기존
"제안"과는 다른 클래스). `DangerSoundMonitor` → `ActExecutor.report_danger_sound()`가
엣지 트리거로 보낸다 — 같은 상태가 계속되는 동안은 재전송하지 않는다.

```json
{ "type": "alert", "kind": "danger_sound", "band_energy_ratio": 0.77, "mean_period_seconds": 0.42 }
{ "type": "alert_cleared", "kind": "danger_sound" }
```

---

## 모션 MCU 링크 (RPi4 ↔ 모션 MCU) — 뼈대, **실물 미검증**

2026-09-28 추가. 제어 MCU·펌웨어·통신 방식(UART/USB)이 아직 미정이라, RPi4 쪽 어댑터
(`rpi/controller/serial_motion.py`)가 기대하는 **제안 계약**이다. MCU 펌웨어가 정해지면 이 절과
어댑터를 함께 고친다. 메모리 파이프와 가짜 MCU로만 시험했다.

- 포맷: 줄 단위 JSON(`
`). 보드레이트는 펌웨어가 정한다(기본값 없음, `SIMPLELAY_MOTION_BAUD`).
- G-code 대신 JSON: 다른 링크와 같은 도구를 쓰고, 엔코더 DC 모터용 필드(모터별 카운트·누름 방식·오류 코드)를
  비표준 G-code 확장 없이 싣는다. 요청 `id`로 응답을 짝지어 시간 초과로 버린 요청의 늦은 응답을 걸러낸다.
- 좌표 변환은 RPi4가 한다: XY mm → CoreXY 벨트 ΔA·ΔB → 엔코더 카운트(`rpi/controller/kinematics.py`).
  MCU는 모터별 목표 카운트를 받는다. `x_mm`·`y_mm`는 MCU 측 리밋 검사·로그용으로 함께 보낸다.
- Z는 변환 기구가 미정이라 mm를 쓰지 않는다 — Z 엔코더 카운트(`depth`) 또는 구동 시간(`duration`).

### RPi4 → MCU

```json
{ "id": 1, "cmd": "status" }
{ "id": 2, "cmd": "home" }
{ "id": 3, "cmd": "move", "a": 500, "b": 167, "x_mm": 10.0, "y_mm": 5.0 }
{ "id": 4, "cmd": "press", "mode": "depth", "z_counts": 40, "dwell_ms": 100 }
{ "id": 5, "cmd": "press", "mode": "duration", "drive_ms": 120, "dwell_ms": 100 }
{ "id": 6, "cmd": "stop" }
{ "id": 7, "cmd": "ping" }
{ "id": 8, "cmd": "limits" }
```

### MCU → RPi4

```json
{ "id": 1, "ok": true, "state": "idle", "homed": false, "a": 0, "b": 0, "z": 0, "alarm": null, "z_mode": "motor", "z_on_max_ms": null }
{ "id": 3, "ok": true }
{ "id": 3, "ok": false, "error": "stall" }
{ "event": "ready", "fw": "firmware-motion", "protocol": "line-json/v0", "reset": "poweron", "z_mode": "motor", "z_on_max_ms": null }
{ "event": "alarm", "reason": "limit", "z_retract": "not_needed" }
{ "event": "press_start" }
{ "event": "press_end" }
{ "id": 7, "ok": true }
{ "id": 8, "ok": true, "raw": { "x": false, "y": true, "z": false }, "debounced": { "x": false, "y": false, "z": false } }
```

- `ping`(heartbeat, 2026-09-29 추가): RPi4는 `home`·`move`·`press` 응답을 기다리는 동안
  `SIMPLELAY_MOTION_HEARTBEAT_MS`(기본 500ms, `0`/`off`면 끔)마다 자기 `id`를 단 `ping`을 보낸다. MCU는
  진행 중 동작을 건드리지 않고 바로 `ok`로 답한다. **받은 줄이면 무엇이든** MCU 워치독을 갱신하므로
  `firmware-motion`의 `HOST_WATCHDOG_MS`를 명령 기한(원점 복귀 최장 20 s 자리표시자)과 무관하게 2 s로 줄였다
  (`HOST_HEARTBEAT_MS`의 3배 미만이면 빌드 오류, 값은 `TODO(HW 실측)`). `ping` 응답은 `id`가 달라 진행 중
  명령의 응답으로 오인되지 않는다. 조회(`status`·`limits`)에는 `ping`을 섞지 않는다(워치독은 동작 중에만 돈다).
- `limits`(2026-09-29 추가): X·Y·Z 원점/리밋 입력의 즉시 판독(`raw`)과 디바운스 값(`debounced`). `true` = 활성
  (눌림·단선, `LIMIT_ACTIVE_LEVEL` 기준). 움직이지 않고 동작 중에도 바로 답한다. 첫날 배선 확인은 조그 CLI
  `limits` 명령으로 스위치를 하나씩 눌러 해당 축만 바뀌는지 본다.

- `position` 이벤트(2026-09-29 추가, 선택): `{ "event": "position", "a": 300, "b": -100, "z": 0 }` — 엔코더 카운트.
  `firmware-motion`은 이동·누름 중 `POSITION_EVENT_MS`(100ms)마다, 끝날 때 `ok` 응답 직전에 한 번 보낸다.
  RPi4 `SerialMotionClient.last_position`이 이것(또는 `status` 응답·`ok` 응답에 실린 정수 `a`·`b`)을 쥐고,
  기구 값이 있으면 mm로 바꿔 progress 프레임 `position`으로 RPi5에 넘긴다. 보내지 않는 MCU면 RPi5 트윈은
  "명령 기준 추정"으로 그린다.

- `ready` 이벤트(2026-09-29 추가): 펌웨어가 부팅을 마치면 한 줄 보낸다. `reset` = 직전 리셋 이유(`poweron`·`sw`·`panic`·
  `task_wdt`·`int_wdt`·`wdt`·`brownout`·`ext`·`other`). FireBeetle ESP32는 USB 시리얼 DTR/RTS로 자동 리셋되므로 RPi4는
  DTR/RTS를 내린 채(dsrdtr·rtscts 끔) 포트를 열고, `connect()`에서 부트 로그(JSON 아닌 줄)를 버리며 이 줄을 기다리거나
  `status`를 backoff(0.2 s→1 s)로 `SIMPLELAY_MOTION_CONNECT_TIMEOUT_S`(기본 5 s)까지 재시도한다. 동작 중에 `ready`가
  오면 MCU가 재시작한 것 — 진행 중 명령은 실패, 재홈 전까지 이동·누름 거절. 조회 중이면 같은 요청을 새 `id`로 다시 보낸다.
- `alarm`의 `z_retract`(2026-09-29 추가): 알람 때 Z가 눌린 쪽이면 MCU가 XY는 제동하고 Z만 위로 한도(`Z_RETRACT_MS`)
  안에서 올린 뒤 끊는다. 값 `not_needed`·`done`·`timeout`·`stalled`·`skipped`(워치독 `host_timeout` 부류·원점 모름 —
  즉시 차단)·`stopped`(후퇴 중 `stop`). 후퇴가 필요한 알람은 이벤트와 `ok:false`가 후퇴 뒤에 온다.
- `z_mode`(2026-10-05 추가): `ready`·`status`에 Z 누름 방식 `motor`|`solenoid`(펌웨어 빌드 플래그 `Z_MODE`). 솔레노이드는
  `duration` 누름만 받는다 — 켜짐 = `drive_ms + dwell_ms`, 상한(`SOLENOID_ON_MAX_MS`)을 넘으면 `soft_limit`, 직전 꺼짐 뒤
  냉각 시간 안이면 `z_cooldown`, `depth`는 `z_unsupported`. 솔레노이드의 `status`·`position` `z`는 켜짐 1/꺼짐 0, `limits` `z`는
  항상 `false`, 알람 때는 즉시 끈다(`z_retract` `done`|`not_needed`). RPi4는 `z_mode`가 `solenoid`면 `depth` 누름을 보내기 전에
  거절하고, `z_unsupported`·`z_cooldown`은 위치를 잃지 않은 거절로 다뤄 재홈을 요구하지 않는다. `z_mode`가 없는 MCU면 제한하지 않는다.
- 2026-10-05 리뷰 L6: `ready`·`status`의 `z_on_max_ms`는 솔레노이드 한 번 켜짐 상한(`SOLENOID_ON_MAX_MS`, 모터면 `null`) —
  RPi4는 `drive_ms + dwell_ms`가 이것을 넘는 누름을 보내기 전에 거절한다. `z_cooldown` 거절은
  `{"id":…,"ok":false,"error":"z_cooldown","retry_ms":N}`(남은 냉각 시간). RPi4는 그만큼(+50 ms, 상한 2 s — 넘으면 바로 거절)
  기다렸다가 누름을 **한 번** 다시 보낸다(`retry_ms`가 없으면 `SIMPLELAY_MOTION_Z_COOLDOWN_BACKOFF_MS`, 기본 500).
  알람 이벤트 없이 온 `soft_limit` 거절 응답은 움직이기 전 범위 검사라 알람·재홈으로 다루지 않는다(움직이다 넘으면 `alarm`
  이벤트가 먼저 온다).
- 위치 일치 검사(2026-10-05, RPi4 선택): `SIMPLELAY_MOTION_POSITION_TOLERANCE_COUNTS`(기본 꺼짐, 측정 필요)를 주면 `move`의
  `ok` 뒤 그 요청 동안 받은 `position`(`a`·`b`)이 명령과 허용 오차 넘게 다르거나 보고가 없을 때 이동을 실패로 끝내고 재홈 전까지
  거절한다. 엔코더가 모터 축에 있어 풀리–벨트 미끄럼은 이것으로 보이지 않는다 — MCU가 목표에 못 닿고 `ok`를 보낸 경우를 잡는다.
- 응답은 동작이 **끝난 뒤** 보낸다(홈 완료·도착·Z 복귀). `id` 없는 줄은 자발 이벤트다.
- `alarm` 이벤트나 `ok:false`를 받으면 RPi4는 해당 동작을 실패로 끝내고 알람 상태로 둔다.
- 기한 초과 시 RPi4는 `stop`을 보내고 위치를 믿지 않는다(재홈 전까지 이동·누름 거절).
- `stop`은 다른 스레드에서 즉시 보낸다. 보낸 것은 '명령 전송'까지이며, MCU 정지 보고·물리 정지 확인은
  별도 단계로 실물에서 재야 한다. MCU는 호스트 줄이 `HOST_WATCHDOG_MS`(2 s 자리표시자) 동안 없으면 스스로 멈추고
  `alarm`(`host_timeout`) 이벤트 뒤 대기 명령에 `ok:false`를 보낸다(실측 전).
- 수치 예시는 형식 설명용이다. 카운트 값은 시험용 임의 기구 값으로 계산한 것이며 실물 값이 아니다.
- 2026-10-10: 팀원 코드에서 옮긴 [`firmware-motion-corexy/`](../firmware-motion-corexy/)도 이 규약(같은 명령 표)을 따른다.
  `ready`의 `fw`는 `firmware-motion-corexy`(사람용 시험 빌드는 `firmware-motion-corexy-bringup` — RPi4에 연결하지 않는다),
  `z_mode`는 항상 `solenoid`. 이 펌웨어는 `move`의 `a`·`b`를 자기 기구 값으로 mm로 되돌려 함께 온 `x_mm`·`y_mm`과
  0.5 mm 넘게 다르면 `bad_args`로 거절한다(RPi4 `SIMPLELAY_MOTION_*` 기구 값과 펌웨어 `config.h`가 같아야 한다).
  누름은 마지막으로 끝난 이동(또는 원점) 위치에서 0.7 mm 넘게 밀렸으면 `not_homed`로 거절하고 원점 기준을 버린다.
  리밋 스위치를 쓰지 않는 기본 빌드에서 `limits`는 x·y·z 모두 `false`다(원점은 스톨 감지). 실물 미검증.

---

## 콘센트 모듈 링크 (RPi4 ↔ ESP32 콘센트 모듈) — **컴파일·가짜 출력 수준, 실물 미검증**

2026-10-05 추가. 9/30 하드웨어 방향 확정(ESP32 = 콘센트 모듈, CT 전력 → RPi4 직접, 물리 비상정지는 모듈의
버튼과 가전 전원 릴레이)에 맞춘 규약이다. 펌웨어 `firmware-outlet/`, 호스트 `rpi/verifier/outlet.py`, 실행 가능한
기준 `rpi/tools/fake_outlet.py`, 명령 표 `firmware-outlet/protocol_table.json`(`rpi/tests/test_outlet_protocol.py`가
셋을 대조). CT·릴레이·버튼을 붙여 돌려 본 적이 없다.

- 포맷: 줄 단위 JSON(`\n`), USB 시리얼 **115200 고정**(`SIMPLELAY_OUTLET_BAUD`를 같은 값으로). 모션 MCU 링크와 같은 전송 계층.
- 프로토콜 이름 `line-json/outlet-v0`. 요청 `id`로 응답을 짝짓는다. `id` 없는 줄은 자발 이벤트.

### RPi4 → 모듈

```json
{ "id": 1, "cmd": "status" }
{ "id": 2, "cmd": "ping" }
{ "id": 3, "cmd": "relay_on" }
{ "id": 4, "cmd": "relay_off" }
{ "id": 5, "cmd": "estop_reset" }
{ "id": 6, "cmd": "rate", "hz": 10 }
```

### 모듈 → RPi4

```json
{ "id": 1, "ok": true, "relay": "off", "estop": false, "button": false, "rate_hz": 10, "ct": "ads1115", "cal": "placeholder", "uptime_ms": 5230, "channels": 2, "relay_ch": 0 }
{ "id": 3, "ok": false, "error": "estop_latched" }
{ "event": "ready", "fw": "firmware-outlet", "protocol": "line-json/outlet-v0", "reset": "poweron", "relay": "off", "ct": "ads1115", "ct_ok": true, "estop": false, "channels": 2, "relay_ch": 0 }
{ "event": "power", "ch": 0, "t_ms": 5300, "seq": 52, "watts": 3.1, "irms_a": 0.014, "vrms_est": 220.0, "ct_mv": 0.47, "n": 25, "err": 0, "relay": "on" }
{ "event": "power", "ch": 1, "t_ms": 5300, "seq": 52, "watts": 412.0, "irms_a": 1.873, "vrms_est": 220.0, "ct_mv": 62.4, "n": 25, "err": 0, "relay": "on" }
{ "event": "estop", "source": "button", "t_ms": 9120, "relay": "off" }
{ "event": "fault", "reason": "ct_init" }
```

- **CT 채널(2026-10-06, 사용자 결정: 두 번째 CT로 전자레인지·세탁기를 동시에 잰다).** `power` 줄마다 `ch`(0~3)가 붙는다.
  `ch`가 없는 줄(옛 펌웨어)은 채널 0이다. 펌웨어 `OUTLET_CT_CHANNELS`(기본 2; ADS1115 최대 4, 내장 ADC 최대 2), 기본 배선
  ch0 = 전자레인지(AIN0-AIN1), ch1 = 세탁기(AIN2-AIN3). ADS1115는 단발 변환으로 채널을 돌려 읽는다(500 Hz → 2채널이면 채널당
  250 Hz, 10 Hz 창에 25점). 보정은 채널마다(`CT_*_CH`, 전부 측정 필요). `ready`·`status`의 `channels`는 빌드 채널 수,
  `relay_ch`는 릴레이가 끊는 채널. **릴레이는 하나이고 `relay_ch`(전자레인지) 가전 전원만 끊는다 — 세탁기 채널은 릴레이를
  거치지 않게 배선한다**(모터 기동 전류, CT 계측만). 비상정지 버튼도 그 릴레이만 연다. `power`의 `relay`는 릴레이 상태다.
  RPi4는 링 버퍼·시각 맞춤·`seq`·신선도를 **채널마다 따로** 둔다(한 채널의 줄이 다른 채널을 순서 뒤바뀜으로 버리지 않는다).
  채널 → 가전은 `SIMPLELAY_OUTLET_CHANNELS=microwave:0,washer:1`(비우면 모두 채널 0). L3·잔여 전류 꼬리·정지 확인·기록기는
  `microwave` 채널, `SIMPLELAY_DONE_WATCH`의 가전은 각자 채널을 읽는다. 대응에 가전이 빠졌거나 한 채널에 두 가전이면 기동 거절.
  `rate`는 채널당 창 샘플이 20 미만이 되는 주기를 `bad_args`로 거절한다(2채널 ADS1115는 10 Hz까지 — 25점이라 하한 근처).
- ADS1115 돌려 읽기(2026-10-06 평가 A3): 단발 변환이 끝나기 전(OS=0)에는 다음 채널 변환을 시작하지 않고 그 틱을 건너뛰며,
  읽은 값은 설정 레지스터의 MUX로 실제로 변환한 채널 창에 넣는다(시작할 때 기록과 다르면 버리고 판독 실패로 센다).
- `power`: 기본 10 Hz, **ADS1115 CT가 둘 이상이면 5 Hz**(채널당 창 50점 — 호스트 하한 20의 2.5배. 펌웨어가 컴파일 때 2배를
  강제한다)(`rate`, 1~20). `watts`는 **추정값** = CT 실효 전류(보정 배율·잡음 바닥 적용) × `vrms_est`
  (설정 상수, 측정 아님) × 설정 역률. 보정 값은 전부 자리표시자(`status.cal = "placeholder"`) — 절대값은 근거가 아니다.
  L3는 기준선 대비 변화로 판정한다. CT 초기화가 실패하면 `fault`(`ct_init`)만 보내고 `power`를 내지 않는다(0 W를 지어내지 않는다).
- 시각: RPi4는 모듈 `t_ms`를 호스트 단조 시각에 맞춰(`anchor = 수신 시각 − t_ms/1000`) 샘플 시각으로 쓴다. 다시 맞추는 것은
  첫 샘플, `ready` 배너 뒤 첫 샘플, `seq`가 작은 값(≤5)으로 되돌아간 샘플뿐이다. 그 밖에 `t_ms`·`seq`가 늘지 않은 줄(중복·
  순서 뒤바뀜)은 버리고 신선도도 갱신하지 않는다(2026-10-05 리뷰 L1).
- 창 품질(2026-10-05 리뷰 M1): 모듈은 창 샘플이 기대치의 `CT_MIN_WINDOW_PCT`(50 %) 미만인 창을 보고하지 않고 `seq`만 늘린다.
  RPi4는 `n` < `SIMPLELAY_OUTLET_MIN_SAMPLES`(기본 20) 또는 `err/n` > `SIMPLELAY_OUTLET_MAX_ERR_RATIO`(기본 0.1)인 줄, `n`이
  없는 줄을 버린다(신선한 샘플로 세지 않는다). 기준값은 측정 필요.
- 끊김(채널마다): 그 채널의 마지막 `power` 수신 뒤 `SIMPLELAY_OUTLET_STALE_MS`(기본 1000)가 지나면 RPi4 센서는 `PowerSensorStale`을 던진다 →
  L3는 'L3 판정 불가 — 전력 센서를 읽지 못함'으로 안전 정지(자동 재입력 없음).
- 생존(2026-10-05 리뷰 M2): RPi4는 어떤 줄이든(ping·status 응답 포함) 받은 시각을 남기고, `SIMPLELAY_OUTLET_OFFLINE_MS`
  (기본 3000) 넘게 아무것도 받지 못하면 모듈 무응답으로 본다 — 그동안 `execute`·`verify_pass`는 `error`(`outlet_offline`)로
  거절한다(물리 비상정지 이벤트를 볼 수 없으므로). 읽기에서 포트 오류(USB 빠짐)가 나면 0.5→1→2→4→5 s 간격으로 다시 연다.
  `SIMPLELAY_OUTLET_STATUS_POLL_MS`(기본 2000)마다 `status`를 물어 `estop` 표시를 반영한다(이벤트 줄을 잃어도 걸림을 놓치지 않게).
- **릴레이 기본 = 꺼짐(fail-safe).** 부팅·재부팅 뒤 가전 전원은 끊긴 채이고 `relay_on`이 있어야 켠다
  (`SIMPLELAY_OUTLET_RELAY_ON_START=1`이면 RPi4가 시작 때 보낸다. 기본은 보내지 않는다).
- **모듈 재부팅으로 꺼진 릴레이**(2026-10-06 평가 A4): RPi4가 켜 둔 뒤 모듈이 다시 켜지면(`ready` 배너, 또는 `status`가
  걸림 없이 `relay:"off"`) RPi4는 **다시 켜지 않는다**. 대신 걸린다(`estop_state {latched:true, source:"outlet_reboot",
  detail:"콘센트 모듈이 다시 켜져 전원이 꺼져 있어요 — 확인 후 켜 주세요"}`) — 실행은 그 문장으로 거절되고, 사람이
  `POST /stop/ack`(`estop_ack`)를 누르면 버튼을 확인한 뒤 `relay_on`을 보내고 풀린다. 비상정지로 꺼진 릴레이는 종전처럼 켜지 않는다.
- **채널 대응 확인**(2026-10-06 평가 A1·A2): 콘센트 전력을 읽는 가전(L3·기록기·실물 모션의 정지 확인 = 전자레인지,
  `SIMPLELAY_DONE_WATCH`의 outlet 가전)이 둘 이상인데 `SIMPLELAY_OUTLET_CHANNELS`가 비면 RPi4는 시작을 거절한다(모두 채널 0을
  읽어 전자레인지 끝이 세탁 끝으로 잡힌다). `ready`·`status`의 `relay_ch`가 전자레인지 채널과 다르거나 대응한 채널이 `channels`
  밖이면 시작을 거절하고, 실행 중 모듈이 그렇게 알리면 `execute`를 `outlet_offline`으로 거절한다. 가짜 모듈의 릴레이 채널은
  대응에서 베끼지 않는다(`SIMPLELAY_FAKE_OUTLET_RELAY_CH`, 기본 0).
- **물리 비상정지**: 버튼(NC, 눌림·단선 = 활성)이 연속 `ESTOP_TRIP_SAMPLES` 활성이면 모듈이 **그 자리에서** 릴레이를 연다
  (호스트·시리얼과 무관). 그 뒤 `estop` 이벤트를 한 번 보낸다. 걸린 동안 `relay_on`은 `estop_latched`, 버튼이 눌린 채면
  `estop_reset`은 `estop_active`. 해제해도 릴레이는 꺼진 채 — 다시 켜려면 `relay_on`.
- **걸림 보존**(2026-10-05 리뷰 H2): 모듈은 걸림을 RTC 메모리(리셋·워치독·패닉을 넘어 남음)와 NVS(전원이 꺼져도 남음)에
  적어 두고, 재부팅 뒤에도 걸린 채로 시작한다(릴레이 꺼짐, `relay_on` 거절). `ready`와 `status`의 `estop`이 true다.
  RPi4는 이것을 받으면 자기도 걸린다. `SIMPLELAY_OUTLET_RELAY_ON_START=1`이어도 걸려 있거나 확인하지 못하면 `relay_on`을 보내지 않는다.
- RPi4는 `estop`을 받으면(또는 `ready`·`status`가 걸림을 보고하면) **걸린다**(`estop_latched`): 실행 중 시퀀스를 `abort`와
  같은 정지 경로로 멈추고(모션 MCU `stop`도 즉시), 정지 버튼 대기 중이면 구동부만 멈춘다(전원이 이미 끊겨 정지 버튼을 누르지
  않는다). 걸린 동안 `execute`·`verify_pass`는 `{"type":"error","reason":"estop_latched","detail":…}`로 거절한다 — 쉬는 중에
  걸렸어도, 정지 대기 해제를 기다리는 사이에 걸렸어도 같다. RPi5에는 `{"type":"alert","kind":"outlet_estop","source":…}`와
  `{"type":"estop_state","latched":true,"source":…,"reason":null,"detail":…}`.
- 해제: RPi5 `POST /stop/ack` → `{"type":"estop_ack"}` → RPi4가 모듈 `status`로 버튼을 확인한다(2026-10-06 평가 C2:
  확인은 읽기 루프와 따로 돌아, 모듈 응답을 기다리는 동안에도 `abort`를 처리한다). 버튼이 눌린 채면
  `estop_reset`을 보내지 않고 `estop_state {latched:true, reason:"estop_button_pressed"}`, 모듈이 답하지 않으면
  `reason:"outlet_unreachable"`, 확인 중 다시 걸리면 `estop_retriggered`. 풀리면 `estop_state {latched:false}` — 가전 릴레이는
  꺼진 채다(켜기는 별도).
- RPi5: `GET /status`의 `estop_latched`·`estop_detail`, 내장 가전 준비 상태(`GET /appliances`)의 `can_execute=false`와 사유
  "비상정지가 걸려 있어요 — …", 실행 요청은 412(준비 안 됨). `POST /stop/ack`는 다른 제어 API와 같은 인증을 탄다
  (응답 `{ok, latched, reason, detail}`; 걸림을 보고하지 않는 실행기면 409, RPi4 무응답이면 504).
- 호스트 침묵: 모듈은 기본적으로 호스트가 조용해도 릴레이를 두고(`HOST_SILENCE_RELAY_OFF 0`), 1로 빌드하면 `HOST_SILENCE_MS`
  뒤 릴레이를 열고 `host_timeout`을 보낸다. RPi4는 `ping`을 `SIMPLELAY_OUTLET_HEARTBEAT_MS`(기본 1000)마다 보낸다.

### RPi4 → RPi5 추가 프레임

- `progress {phase:"power_tail", power_tail:{status, tail_s, tail_mean_w, tail_max_w, pre_baseline_w, post_baseline_w,
  finished_at_s, returned_at_s, band_w, samples, source, detail}, operation_source}` — L3가 동작 시작을 확인한 실행 뒤,
  완료 판정(전력 ≤ `off_max_w`가 `off_confirm_s` 유지) → 대기 전력 띠로 복귀하기까지의 잔여 전류 꼬리(피드백 ③). 기록용이며
  판정이 아니다. 정의·기준값은 `rpi/verifier/power_tail.py`(`SIMPLELAY_TAIL_*`, 전부 측정 필요). RPi5 `ActClient.last_power_tail`.
  원시 기록기(`SIMPLELAY_RECORDER_PATH`)에는 `event=power_tail` 행과 `tail_*`·`pre/post_baseline_w` 열로 남는다.
- `appliance_done`(2026-10-06, **가짜 콘센트 모듈·합성 음으로만 시험, 실물 미검증**) — RPi4가 스스로 보내는 가전 끝 알림.
  `alert`처럼 RPi5가 묻지 않아도 오며 `execute`의 결과가 아니다(실행 중에도 올 수 있다). RPi4 `SIMPLELAY_DONE_WATCH=<가전>:outlet[,mic][;…]`
  (예: `washer:outlet,mic;microwave:outlet`, 2026-10-06 CT 두 채널 — 가전마다 자기 CT 채널, `mic`은 한 가전만)일
  때 콘센트 모듈 CT 전력의 사이클 끝(`rpi/verifier/cycle_end.py`: 운전 ≥ `run_min_w`를 `min_run_s` 지난 뒤 대기 ≤ `standby_max_w`에
  `settle_s` 머묾 — 그보다 짧은 하강은 끝이 아니다)과 마이크 종료음(`rpi/verifier/end_beep.py`: 위험 소리와 같은 대역 에너지·간격
  DSP, 몇 번 울리고 멈추는 묶음)을 `rpi/verifier/done_fusion.py`가 융합한다. 기준값은 `SIMPLELAY_CYCLE_*`·`SIMPLELAY_BEEP_*`·
  `SIMPLELAY_DONE_FUSION_*`, **전부 측정 필요**. 관찰은 릴레이 명령을 보내지 않는다(세탁기는 CT 계측만).

```json
{ "type": "appliance_done", "appliance_id": "washer", "event": "wash_complete", "state": "done_confirmed",
  "confidence": "confirmed", "inputs": ["beep", "power"], "expected_inputs": ["power", "beep"], "source": "real",
  "at_s": 1234.5, "gap_s": 3.8, "fusion_window_s": 120.0,
  "evidence": { "power": { "run_s": 3120.0, "peak_w": 1850.0, "mean_run_w": 310.0, "standby_w": 2.1, "dips": 14, "…": "…" },
                "beep": { "beeps": 3, "mean_period_s": 0.6, "…": "…" } },
  "t_monotonic_ns": 0, "clock_id": "f445ea42be9e405f" }
```

  - `at_s`·`t_monotonic_ns`는 **RPi4 프로세스의** 단조 시각이고 `clock_id`가 그 시계를 가리킨다(3차 평가 M1, 2026-10-14).
    RPi5는 받는 순간 `clock_ref` 기준점(위 `clock_probe`)으로 `at_s`를 자기 단조 시계로 옮겨 `event_end_mono_s`로 둔다 — 같은
    `clock_id`의 기준점이 없으면(옛 RPi4·RPi4 재시작·링크 끊김) None이고 자동 실행 허용 규칙은 **보류**한다. 다른 장치의 단조 값을
    그대로 빼지 않는다. RPi5 모의 주입은 RPi5 자기 시계 식별자를 싣는다(같은 시계). 사건 나이(지금 − 옮긴 끝 시각)는 판단 때와
    ThinQ 전송 직전에 다시 본다(`SIMPLELAY_AUTO_RULE_MAX_EVENT_AGE_S`, 기본 120초, 측정 필요).
  - `state`: `done_confirmed`(두 입력이 `fusion_window_s` 안) | `done_power_only` | `done_beep_only`(하나만 — 먼저 온 입력이
    `SIMPLELAY_DONE_FUSION_WAIT_S` 동안 짝을 기다린 뒤). `inputs`와 `state`가 어긋나면 RPi5가 버린다.
  - `source`: `real` | `mock`(가짜 콘센트 모듈 등 합성 입력) | `injected`(리허설 주입 — 시뮬레이터 실행기만 보낸다).
  - RPi5: `ActClient.on_appliance_done` → `deps.receive_appliance_done` → 루틴 엔진 `on_appliance_done`(같은 가전의 `after_done`,
    같은 이름의 `event` 트리거). `done_confirmed`만 "세탁이 끝났어요", 나머지는 "끝난 것 같아요 — 확인해 주세요"이고 루틴의
    안내 문장을 읽지 않는다. 주입은 "(시연 주입)", 모의는 "(모의 입력)". 리허설은 `POST /demo/appliance-done`(모의·시뮬레이터,
    그리고 UART 리허설 스위치 + 가짜 RPi4 — 그 밖 404).
  - 한 사이클에 한 번(2026-10-06 평가 B3): 같은 가전의 `after_done`이 실행 끝에서 이미 깼으면 그 사이클의 이 프레임은 다시 깨우지
    않고, 그 가전을 돌린 루틴 자신도 깨우지 않는다. 루틴 처리가 실패하면 기록은 남기고 알림함에
    "세탁 끝 알림을 보내지 못했어요"(종류 `appliance_done_undelivered`)를 남긴다(Copilot#3).
  - 쿨다운은 가전마다(평가 B2): `SIMPLELAY_DONE_<가전>_COOLDOWN_S` → `SIMPLELAY_DONE_COOLDOWN_S` → 가전별 기본(전자레인지 60 s,
    그 밖 900 s, 측정 필요) — 전자레인지 두 번째 가열의 끝을 버리지 않는다.
  - `event`는 가전마다 다르다(`rpi/verifier/done_fusion.py` `done_event_for`): 세탁기 `wash_complete`, 전자레인지 `heat_complete`,
    그 밖 `<가전>_done`. 전자레인지 끝이 '세탁 끝 알림' 루틴을 깨우지 않게 나눴다. 사이클 기준은 가전별로
    `SIMPLELAY_CYCLE_<가전>_<항목>`(예: `SIMPLELAY_CYCLE_MICROWAVE_SETTLE_S`) → `SIMPLELAY_CYCLE_<항목>` → 가전별 설계 초기값 순.
  - 루틴 `wait_until_done`(갭 M2, 2026-10-06 평가 B1·B4·B5·Copilot#5): 끝 센서가 있는 가전(RPi4 `act_info.done_watch`, 받기 전에는
    RPi5 `SIMPLELAY_ROUTINE_DONE_SENSORS`)이면 실행이 성공하기만 하면(L3 시작 확인을 요구하지 않는다 — L3는 전자레인지 채널만 읽는다)
    이 프레임을 가전별 상한(`SIMPLELAY_ROUTINE_DONE_TIMEOUT_<가전>_S` → `SIMPLELAY_ROUTINE_DONE_TIMEOUT_S` → 전자레인지 900 s·세탁기
    3 h → 1200 s, 측정 필요)까지 기다린다. **`done_confirmed`만 끝남 확인**이고, 입력 하나뿐이면 "끝난 것 같아요 — 확인해 주세요"를 남기고
    뒤 단계를 보내지 않은 채 멈춘다. `POST /stop`·비상정지(해제 확인 뒤에도)는 기다리는 루틴을 멈춘다. 기다리는 동안 새 명령은 막히지 않는다.
    그 가전의 `after_done` 트리거도 L3가 아니라 이 프레임에서 깬다.
  - 가전 ID(평가 B3): `SIMPLELAY_DONE_WATCH`의 이름은 RPi5 가전 목록의 `appliance_id`(내장 전자레인지 = `microwave`, 사용자가 추가한
    가전은 그 ID)여야 한다 — 프레임의 `appliance_id`를 루틴의 가전과 그대로 대조한다. RPi5는 `act_info.done_watch`를
    `SIMPLELAY_ROUTINE_DONE_SENSORS`·가전 목록과 대조해 어긋나면 로그(error)로 알리고 RPi4 목록을 따른다.
  - 하위 호환: 옛 RPi5는 모르는 `type`을 무시한다(위 progress와 같다).

---

## RPi5 HTTP `GET /status`의 '마지막 한 칸' 필드 — `last_job_id`·`last_auto_run` (2026-10-14, 3차 평가 L3)

둘 다 **결과 이력 전달 API가 아니라 마지막 1건**이다. 놓친 결과를 모두 받으려면 `/history`(실행)·`/routines/auto-rules/runs`(자동 실행 판단)를 읽는다.

- `last_job_id`: 마지막으로 시작한(끝났거나 진행 중인) job 하나. 폴링 사이에 job 두 개가 끝나면 **앞 job의 결과는 `/status`로 복원할 수 없다.**
  키오스크는 켠 뒤 첫 조회 값을 기준으로만 잡고(켜기 전 결과는 띄우지 않음), 그 뒤 값이 바뀌면 그 job의 결과를 완료 화면으로 띄운다 —
  `running`을 한 번도 보지 못한 짧은 실행·정지도 여기서 잡는다(10/14 C). 자동 실행 job은 완료 화면 대신 아래 한 줄로만 알린다.
- `last_auto_run`: **결과가 나온 마지막 자동 실행 1건**(job이 있는 것만 — 보내기 전에 막힌 판단은 job이 없어 여기에 없다). 없으면 null.
  - 필드: `job_id`·`at`·`outcome`(`sent`·`blocked`)·`status`·`receipt`·`confirmation`·`dispatch`·`execution_mode`·`target_name`·`setting_label`·`value_label`·`value_phrase`.
    `dispatch`·`value_phrase`는 2026-10-14(아래 'ThinQ 결과의 네 경우') — 옛 RPi5에는 없다.
    대상·설정·값 이름은 **그 job을 만들 때의 사본**이다(3차 평가 M2 — 보낸 뒤 규칙 편집·삭제·대상 이름 변경에도 바뀌지 않는다).
  - **비영속:** 서버 메모리의 기록이라 RPi5 백엔드를 다시 켜면 null로 돌아간다.
  - **첫 조회 제외:** 키오스크는 켠 뒤 첫 조회에 이미 있던 값은 알리지 않는다(지난 결과를 다시 읽지 않음). 그 뒤 `job_id`가 바뀔 때 한 번 알린다.
  - 폴링 사이에 자동 실행 두 건이 끝나면 앞의 것은 키오스크가 알리지 않는다(마지막 1건만).
- 옛 RPi5는 `last_auto_run`이 없다 — 키오스크는 필드 없음·null이면 알림을 만들지 않는다.

## ThinQ 결과의 네 경우 — `confirmation`·`dispatch` (2026-10-14, 보드 날 발견 3)

ThinQ 실행기(`rpi/services/thinq/controller.py`)는 보내기 전 상태 조회 값과 보낸 뒤 재조회 값으로 **확인한 사실만큼** 결과를 낸다.
문장은 `rpi/services/thinq/wording.py`, 설정 이름은 `ThinqCapability.setting_phrase`(풍량은 "강풍"·"약풍", 그 밖은 "풍량 중"·"운전 모드 청정"처럼 속성 이름을 붙인다).

| 경우 | status / receipt / confirmation | 제어 요청 | 문장(`last_detail`·`/history` `detail`) |
|---|---|---|---|
| 보내기 전부터 목표값 | `succeeded / not_dispatched / already_at_target` | 0회 | 이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요. |
| 보내기 전 다른 값 → 보낸 뒤 목표값 | `succeeded / accepted / state_confirmed` | 1회 | 강풍으로 바꿨어요. |
| 보내기 전 값 모름(조회 실패·값 없음) → 보낸 뒤 목표값 | `succeeded / accepted / state_confirmed_unknown_before` | 최대 1회 | 강풍으로 설정된 것을 확인했어요.('바꿨어요' 금지 — 원래 그 값이었을 수 있다) |
| 보낸 뒤 상태 확인 실패 | `unconfirmed / accepted / none` | 1회, 추가 전송 0회 | 명령을 보냈어요 — 설정이 바뀌었는지 확인하지 못했어요. 자동으로 다시 보내지 않아요 |

- `already_at_target`은 `succeeded`+`not_dispatched`와만 짝짓고(값 객체가 강제), 물리 경로는 쓸 수 없다. `state_confirmed_unknown_before`는 `succeeded`+`accepted`만.
- **먼저 지나야 하는 검사:** '이미 목표값'도 정지(미전송 취소)·전송 직전 재판정(자동 실행 규칙 켜짐·지문·대상·사건 나이·비상정지 세대)·전송권 확인을 모두 지난 뒤에만 나온다. 걸리면 `failed / not_dispatched / none`(자동 실행은 `outcome: blocked`)이고 성공으로 기록하지 않는다. 보내지 않으므로 전송권은 '전송 개시'로 표시하지 않는다(철회가 '이미 보내는 중'으로 알리지 않는다).
- 보내기 전 조회가 실패해도 원격 제어 허용을 먼저 봐야 하는 동작(세탁기 시작·일시정지)은 보내지 않는다(종전대로). 가전·클라우드 오프라인도 보내지 않는다.
- 같은 사건 1회: 이미 목표값이라 보내지 않은 자동 실행도 그 사건을 처리한 것으로 남는다(다시 받으면 `duplicate`).
- `dispatch`(기록 구분, `/history`·`/routines/auto-rules/runs`·`last_auto_run`): `sent`(명령을 보낸 실행, receipt `accepted`) · `state_only`(상태만 확인, `already_at_target`) · `not_sent`(보내지 않음) · `unknown`(보냈는지 모름·옛 기록). receipt·confirmation에서 유도한다.
- 사용 기록(제안 집계)은 세 성공(`state_confirmed`·`state_confirmed_unknown_before`·`already_at_target`)을 성공으로 센다. 루틴 다음 단계의 '시작 확인'·`after_done` 깨우기는 종전대로 `state_confirmed`(실제 변경)만.
- 옛 폰·키오스크는 모르는 `confirmation`을 확인 칩 없이 성공으로만 보인다(결과 문장은 서버 `last_detail`이 말한다).

## 사용 기록 → 루틴 초안 — `/routines/candidates` (2026-10-14, 4번)

가전 사용 기록 분석이 찾은 반복 순서를 **가전·버튼 순서가 채워진 루틴 초안**으로 준다. 이 묶음에는 실행 진입점이 없다 — 저장만 한다(카드·자동 실행 허용도 만들지 않는다). 기록: [devlog](devlog/devlog_2026-10-14-habit-routine.md).

| 요청 | 응답 |
|---|---|
| `GET /routines/candidates` | 초안 목록(근거가 강한 순). 제안을 쉬는 동안(방해 금지)은 `[]` |
| `POST /routines/candidates/{key}/save` `{"name": "...", "run": "manual" \| "ask_at_time"}` | 201 `{"routine": <루틴>, "executed": false, "notice": "저장만으로는 실행하지 않아요. …"}` · 422(이름·`run` 없음·잘못됨) · 404(없는 초안) · 409(이미 저장한 초안, 같은 가전·버튼 순서의 루틴이 이미 있음 — detail에 그 루틴 이름) |
| `POST /routines/candidates/{key}/decline` | `{"ok": true, "quiet_until": ISO}` — 14일 동안 그 초안을 보이지 않는다. 404(없는 초안) |

초안 필드: `key`(`hc-` + 가전·버튼 순서 해시 16자) · `appliance_id` · `appliance_name` · `buttons`(조작부 이름) · `steps`(`press_sequence` 한 단계) · `suggested_name` · `evidence`("최근 28일 중 아침에 4일 사용했어요" — 가전 사용 기록 문장, 사람을 단정하지 않는다) · `evidence_detail`(`window_days`·`distinct_days`·`occurrences`·`time_band`) · `ask_time`("HH:MM", 기록 시각 중앙값을 5분 단위로 내림) · `run_choices`(`manual` "직접 실행할 때만" · `ask_at_time` "매일 HH:MM에 물어보기") · `notice`.

- 저장한 루틴은 `mode=approve`. `manual`은 `trigger.kind=manual`, `ask_at_time`은 매일 `ask_time`의 시각 트리거 — 그때 **카드만** 만든다(종전 루틴 규칙). 물리 버튼 단계라 자동 실행 규칙(`auto_rule_offer`)은 붙지 않는다.
- 근거는 패턴 감지기와 같다: 성공·실제 실행(`real`)·직접 사용(`direct`) 기록만. 모의·시연·제안 승인으로 실행한 기록은 세지 않는다. 버튼 순서를 결정적으로 모르는 목적(등록 기능·내장 규칙에 없는 것)과 ThinQ 가전은 초안을 만들지 않는다.
- 보이지 않는 경우: 저장한 초안(루틴을 지워도), 거절 뒤 14일, 같은 가전·같은 버튼 순서의 루틴이 이미 있음(장치 명령 열로 비교 — 버튼 ID로 적었어도 같다), '다시 받지 않기'로 내린 목적, 제안을 쉬는 동안. 판단(저장·거절)은 DB가 있으면 설정 `routine_candidate_decisions`에 남아 재시작 뒤에도 유지된다.

## 버튼 맵 JSON 포맷

`docs/button-maps/<appliance>.json` 에 가전별 저장.

```json
{
  "appliance": "microwave",
  "model": "generic",
  "grid": { "rows": 4, "cols": 3 },
  "buttons": [
    { "id": "BT-01", "label": "10초", "x": 0, "y": 0 },
    { "id": "BT-02", "label": "30초", "x": 1, "y": 0 },
    { "id": "BT-05", "label": "시작",  "x": 2, "y": 3 },
    { "id": "BT-06", "label": "취소",  "x": 1, "y": 3 }
  ]
}
```
