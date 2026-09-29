# 2026-09-29 — 실모드 디지털 트윈 · 통신 세션 기록 · progress 프레임 · 기록 재생

> **실물로 확인한 것은 없다.** 실기기(RPi5 → UART → RPi4 → USB 시리얼 → ESP32 모션 MCU)는 아직 없다.
> 전부 메모리 파이프·가짜 MCU·시뮬레이터 서버로만 확인했다. 결과는 여전히 RPi4의 `result` 프레임에서만 온다.

본선 리허설에서 실제 하드웨어를 돌리면서 **같은 시각에** 브라우저 트윈이 실행을 따라가고, 모든 통신을 나중에
근거로 쓸 수 있게 남기는 것이 목표다. 지금까지 트윈(`/simulator/twin`)은 `SimulatorController`의 메모리 trace를
읽어서 UART 모드(실기기)에서는 404였다.

## 1. RPi5 통신 프레임 탭 (`rpi/services/link_tap.py`)

- `ActClient`가 보내고 받는 **모든 줄**(execute·abort·inject_failure·result·error·progress·alert, 해석 불가 줄까지)을
  방향·RPi5 시각(`t_wall`, `t_monotonic_ns`)·`type`·`sequence_id`와 함께 남긴다. UART 모드(`open_uart_act_controller`)와
  시뮬레이터(`SimulatorController`)가 같은 `ActClient`를 쓰므로 **한 곳**에서 두 모드가 기록된다.
- 링 버퍼(최근 2000개) + 마지막 execute 프레임 고정(링에서 밀려나도 트윈이 잃지 않게).
- `SIMPLELAY_SESSION_LOG_PATH`(기본 꺼짐)면 JSONL로 이어 쓴다. 경로에 `{date}`가 있으면 하루 한 파일,
  `SIMPLELAY_SESSION_LOG_MAX_BYTES`(기본 20 MiB)를 넘으면 `.1` `.2` …로 회전(`SIMPLELAY_SESSION_LOG_BACKUPS`, 기본 5).
  파일을 열 때마다 `session_start` 머리 줄. 기동 시 켜짐/꺼짐과 경로를 WARNING 한 줄로 남긴다
  (앱 INFO 로그는 uvicorn 기본 설정에서 안 보이기 때문 — 시뮬레이터 서버에서 확인).
- 비밀값: 키 이름에 key·token·secret·password·authorization·cookie가 들어가면 값을 `[redacted]`, 설정된
  `SIMPLELAY_API_KEY`·`SIMPLELAY_DEV_TOKEN` 문자열이 값 안에 있으면 그 부분도 가린다. 프로토콜 프레임에는 원래 키가 없다.
- 탭 고장(디스크 가득 등)은 로그만 남기고 통신을 막지 않는다.

## 2. RPi4 progress 프레임 (선택, 기본 켜짐)

- `ClosedLoopController.set_press_observer()`: 누름 시도마다 `retry`(보정 요청) → `move`(명령 좌표) → `press`(어댑터 반환,
  `ok`·`error`·MCU `position`) → `verify`(`pressed`) → `accept`(L2가 있을 때). 관찰은 결과를 바꾸지 않는다.
- `ActExecutor`가 이것을 `{"type":"progress","sequence_id","n",...,"execution_mode","t_monotonic_ns"}`로 RPi5에 보낸다.
  실행 스레드에서 이벤트 루프로 `call_soon_threadsafe` → 동기 `write` 한 줄이라 **같은 실행의 progress는 모두 result보다
  먼저** 써진다(시험으로 확인).
- **옛 RPi5 호환:** 지금까지의 `ActClient._handle_line`은 `result`/`error`/`alert*` 밖의 `type`을 무시했고(“ack·unknown:
  not yet consumed”), ESP32 노드 펌웨어(`firmware-node` `onActMessage`)도 모르는 `type`을 무시한다. 그래서 기본 켜짐,
  `SIMPLELAY_ACT_PROGRESS=0`으로 끈다. 새 RPi5도 progress로 실행을 끝내지 않는다.
- MCU 위치: `SerialMotionClient.last_position` — MCU 응답(`ok:true`)·이벤트·`status`에 정수 `a`·`b`(+`z`)가 있으면 쥐고,
  기구 값이 있으면 `motor_counts_to_xy`로 mm도 계산한다(없으면 카운트만, mm는 null). `RecordingGrblClient`도 그대로 드러낸다.
- **펌웨어도 보낸다:** 조정 에이전트 요청으로 `firmware-motion`에 `{"event":"position","a","b","z"}`를 더했다 — 이동·누름 중
  `POSITION_EVENT_MS`(100ms)마다, 끝날 때 `ok` 직전 한 번. `protocol_table.json`·`rpi/tools/fake_mcu.py`(move·press가 ok 전에
  position)·README 표를 함께 고쳤고 `test_motion_protocol_table.py`가 셋을 계속 대조한다. PowerShell 빌드 성공
  (RAM 29,232 B 5.5%, Flash 294,255 B 22.4%, 경고는 기존 자리표시자 `#warning` 하나). **플래시·실물 미확인.**
- `docs/protocol.md`에 progress 절·세션 기록 형식·MCU `position` 이벤트를 적었다.

## 3. 실모드 트윈 (`GET /twin`)

`rpi/api/twin_router.py`. `/simulator/twin`은 그대로 둔다.

| 경로 | 인증 | 내용 |
|---|---|---|
| `GET /twin` · `GET /twin-motion.js` | 없음(`/ui`처럼 — 브라우저 주소창은 키 헤더를 못 보낸다. 데이터 없음) | 같은 `twin.html`. 경로로 모드를 고른다(`simulator` / `real` / `replay`) |
| `GET /twin/state` | `require_api_key` | 탭 프레임 + progress + `/status.running`으로 만든 상태 |
| `GET /twin/hardware` · `GET /twin/replays` | `require_api_key` | 하드웨어 요약 · 재생 파일 목록 |

- 상태(`build_link_twin_state`): 마지막 execute 프레임 기준. 누름 기록 = 같은 `sequence_id`의 `progress` `move`
  (재시도 대응은 기존 `attribute_presses`). **결과는 같은 `sequence_id`의 `result` 프레임만**, `error` 프레임은
  `link_error`(결과 없음). progress가 없는 옛 RPi4면 누름 그림 없이 결과만 적는다(`press_source: none`).
- 실행 환경 REAL/MOCK: 화면은 `/status`(실행 중 `execution_mode`, 끝나면 `last_execution_mode`)를 먼저 보고, UART 링크라
  `unknown`이면 트윈 상태의 RPi4 보고(result → progress 순)를 쓴다. 서비스 `_run_mode`와 같이, 스스로 mock이라 밝힌
  컨트롤러(시뮬레이터)는 보고로 real이 되지 않는다. 배지: `실기기 따라가기 · REAL|MOCK|UNKNOWN`.
- 캐리지(`job.carriage` → JS `carriageView`): MCU 위치 보고가 mm로 환산돼 오고 버튼맵이 mm 배치일 때만 그 자리에 그리고
  **"엔코더 보고 위치"**. 그 밖은 모두 **"명령 기준 추정"**(명령 좌표 기준 개념 모션). 카운트만 왔거나 격자 배치면 추정으로
  그리고 카운트·사유를 옆에 적는다. 시뮬레이터 화면은 종전대로 "개념 모션".
- 실모드 화면은 읽기 전용: "이 시퀀스로 모의 실행" 버튼을 숨긴다. 정지 버튼은 그대로 `POST /stop`.
- 성공 문구 꼬리: `실기기(REAL) 보고` / `모의 실행` / `실행 환경 미확인`. `error` 프레임이면 "RPi4 오류 보고(error: busy) · 결과 프레임 없음".

## 4. RPi4 쪽 기록 (`rpi4/act_main.py`)

- `SIMPLELAY_MOTION_LOG_PATH`: MCU와 주고받은 원시 줄을 `rpi.tools.jog`의 `LineLog`·`LoggingTransport`로 이어 쓴다.
  `LineLog(monotonic=True)`만 새로 받는다 — 두 번째 칸이 `+상대초` 대신 `mono_ns=<time.monotonic_ns()>`(칸 수 같음,
  jog CLI 기본 형식은 그대로). mock 모션이면 MCU 줄 없이 job 표시만 남는다고 경고한다.
- 이음 규칙: `ActExecutor(job_observer=...)`가 실행 시작·끝에 `## job_start {"sequence_id":…}` / `## job_end {…outcome}`을
  모션 줄 기록에 쓰고, 원시 기록기(`SIMPLELAY_RECORDER_PATH`)에도 `job_start`/`job_end` 이벤트(note `sequence_id=…`)를 찍는다.
  세 기록(모션 줄 `mono_ns`, 기록기 `t_monotonic_ns`, progress 프레임 `t_monotonic_ns`)이 **RPi4의 같은 monotonic 시각축**이다.
  RPi5 세션 기록과는 `sequence_id`로 잇는다(RPi5·RPi4 시계는 다르다 — 벽시계 `t_wall`은 참고만).
- 기동 로그: `motion line log ON -> …`/`off`, `progress frames ON/off`.

## 5. 기록 재생 — `GET /twin?replay=<파일 이름>` (CLI 대신)

- 서버가 세션 JSONL을 읽어 재생 시각 `t`까지의 프레임으로 같은 상태를 만든다(`GET /twin/state?replay=…&t=…`).
  화면은 `t`만 늘려 가며 폴링하고 "기록 재생 · 지난 세션 파일 · 지금 서버 실행 아님"으로 표시, 정지 버튼은 숨긴다.
  결과는 기록 속 `result` 프레임뿐. 긴 대기(3초 초과)는 3초로 줄이고, 재시작으로 시각이 뒤로 가면 0초로 본다. 깨진 줄은 센다.
- 파일은 `SIMPLELAY_TWIN_REPLAY_DIR`, 없으면 세션 기록 폴더에서만 찾는다. 이름은 `[A-Za-z0-9._-]`만(경로 거절 422, 없으면 404).
- **CLI를 고르지 않은 이유:** CLI(`python -m rpi.tools.twin_replay`)도 결국 twin.html·스크립트·버튼맵(`/appliances`)을
  줄 서버가 필요하다. 같은 서버 라우트면 상태 조립 코드(`build_link_twin_state`)·인증·화면을 그대로 쓰고, 리허설 당일
  RPi5에서 바로, 나중에는 노트북에서 시뮬레이터 서버(`SIMPLELAY_TWIN_REPLAY_DIR`만 지정)로 같은 URL을 연다.

## 6. 리허설 당일 설정

```bash
# ── RPi5 (일반 서버, python -m rpi.main → :8000) ─────────────────────────────
export SIMPLELAY_ACT_MODE=uart
export SIMPLELAY_UART_PORT=/dev/ttyAMA0        # RPi4와 잇는 UART(배선에 맞게)
export SIMPLELAY_UART_BAUD=115200
export SIMPLELAY_SESSION_LOG_PATH=/home/pi/simplelay-logs/session-{date}.jsonl
export SIMPLELAY_API_KEY=<폰·키오스크와 같은 키>   # 로그·문서·채팅에 적지 않는다
# (선택) SIMPLELAY_SESSION_LOG_MAX_BYTES=20971520 SIMPLELAY_SESSION_LOG_BACKUPS=5

# ── RPi4 (python -m rpi4.act_main) ─────────────────────────────────────────
export SIMPLELAY_UART_PORT=/dev/ttyAMA0        # RPi5 쪽 링크
export SIMPLELAY_UART_BAUD=115200
export SIMPLELAY_MOTION_MODE=serial
export SIMPLELAY_MOTION_PORT=/dev/ttyUSB0      # ESP32 모션 MCU(USB 시리얼, ttyACM0일 수도 — ls /dev/serial/by-id)
export SIMPLELAY_MOTION_BAUD=115200            # firmware-motion HOST_SERIAL_BAUD와 같게
export SIMPLELAY_MOTION_LOG_PATH=/home/pi/simplelay-logs/motion-$(date +%Y%m%d).log
export SIMPLELAY_RECORDER_PATH=/home/pi/simplelay-logs/press-$(date +%Y%m%d).jsonl
export SIMPLELAY_L3_MODE=off                   # 전력 센서 드라이버 전까지 off(또는 리허설용 mock — 결과에 mock으로 남는다)
# SIMPLELAY_ACT_PROGRESS는 두면 켜짐. 문제 시 0.  SIMPLELAY_MOTION_*(기구·누름·기한) 값은 실측 후 채운다.
```

| 무엇 | 주소 |
|---|---|
| 실모드 트윈(노트북 브라우저) | `http://<RPi5>:8000/twin` → 화면의 "API 키 설정"에 키 입력 |
| 키오스크 | `http://<RPi5>:8000/kiosk` (빌드 없으면 `/ui`) |
| 폰 앱 | 서버 주소 `http://<RPi5>:8000` + 같은 API 키 |
| 재생 목록 / 재생 | `GET /twin/replays` → `http://<RPi5>:8000/twin?replay=session-20261001.jsonl` |

| 기록 | 어디에 | 시각축 · 잇는 키 |
|---|---|---|
| RPi5↔RPi4 모든 프레임(progress 포함) | RPi5 `SIMPLELAY_SESSION_LOG_PATH` | RPi5 `t_monotonic_ns`·`t_wall`, `sequence_id` |
| MCU 원시 줄(`>>` `<<`, `## job_*`) | RPi4 `SIMPLELAY_MOTION_LOG_PATH` | RPi4 `mono_ns`, job 줄의 `sequence_id` |
| 누름 주변 원시 샘플·MCU 이벤트·job 표시 | RPi4 `SIMPLELAY_RECORDER_PATH` | RPi4 `t_monotonic_ns`, note `sequence_id=` |
| 실행 이력 | RPi5 `/history`·CSV(기존) | `job_id`(이력) ↔ `sequence_id`(통신)는 서비스 로그로 |

- 끝나면 세 파일을 노트북으로 복사해 둔다. 재생은 노트북에서
  `SIMPLELAY_TWIN_REPLAY_DIR=<복사한 폴더> python -m rpi.simulator_main --port 8765` → `http://127.0.0.1:8765/twin?replay=<파일>`.

## 7. 검증

- 새 시험: `rpi/tests/test_link_tap.py` 8(링·파일·회전·날짜 분할·비밀값·쓰기 실패·기동 로그·ActClient 양방향),
  `rpi4/tests/test_act_progress.py` 7(메모리 파이프 ActClient↔ActExecutor + 엔코더 보고 가짜 어댑터: 단계 순서·result보다 먼저·
  재시도 보정·REAL·엔코더 위치 / 카운트만이면 추정 / `SIMPLELAY_ACT_PROGRESS=0` / 옛 RPi5 모양 클라이언트가 progress 섞여도
  result·error 정상 / job_observer / FakeMcu position 이벤트로 `last_position` mm / act_main 모션 줄 기록과 기록기의
  sequence_id·시각축), `rpi/tests/test_twin_real_mode.py` 9(상태 규칙·error≠결과·mock 선언 우선·엔코더 우선·재생 파싱·
  공백 압축·실제 SimulatorController로 `/twin` 라우트와 세션 파일·재생·경로 거절·인증), JS `rpi/tests/twin_real_mode.test.cjs` 5.
  `rpi4/tests/test_act_executor.py`의 가짜 writer는 기존 시험이 결과 줄만 보도록 progress를 거른다.
- JS: `node --test rpi/tests/*.test.cjs` **27 통과**(기존 22 + 5).
- 시뮬레이터 서버(`SIMPLELAY_SESSION_LOG_PATH=…/session-{date}.jsonl`, `--port 8791`): 기동 로그에 `session log ON -> …`,
  `/simulator/twin`·`/twin`·두 스크립트 200, 실패 주입 뒤 "즉석밥 데워줘" 시퀀스 → `/twin/state` `mock`·누름 기록
  즉석밥×3·시작·result 성공 재시도 2·progress 14개, `/simulator/twin/state`도 같은 누름 기록, 세션 파일 기록 확인.
  내장 브라우저로 `/twin`(배지 `실기기 따라가기 · MOCK`, 세션 기록 경로, 정지 버튼만, 캐리지 근거 "명령 기준 추정")과
  `/twin?replay=session-…jsonl`("기록 재생 · MOCK", 재생 끝, 정지 버튼 숨김) 확인, 콘솔 오류 없음. 확인 후 서버 종료.
  첫 페이지 로드에서 `/appliances`가 6초 제한에 걸린 적이 한 번 있었다(다시 열면 정상, curl 5ms) — 내장 브라우저 첫 연결 문제로 보고 따로 고치지 않았다.
- 백엔드 전체 pytest(1회): **1,867 통과, 5 실패**. 실패 1은 기존 `test_dbus_native.py`(이 PC에 `dbus_fast` 없음).
  나머지 4는 이번 변경이 기존 시험의 기대를 바꾼 것: 가짜 MCU의 새 `position` 이벤트가 이벤트 순서 기대 2건
  (`test_serial_motion`·`test_act_main_recorder`)에 섞였고, act_main이 `_build_motion`에 `line_log=None`을 넘겨 호출 모양
  기대 2건이 깨졌다. 앞은 position을 따로 세도록, 뒤는 줄 기록이 없으면 종전 호출 모양 그대로 부르도록 고쳤고
  관련 파일 재실행 **190 통과**(`test_serial_motion`·`rpi4/tests` 전체·`test_jog_cli`·`test_motion_protocol_table`·`test_repo_guard`).
  전체를 다시 돌리지는 않았다.

## 8. 여전히 모르는 것

- 실물 UART·USB 시리얼에서 progress 줄이 결과 대기 시간·MCU 응답에 주는 영향(115200bps에서 줄당 수 ms로 추정).
- MCU `position` 이벤트는 컴파일만 했다. 엔코더 방향·배율(x4)·기구 값이 없으면 mm가 없어 트윈은 계속 "명령 기준 추정"이다.
- RPi5·RPi4 시계 차이: 세션 기록(RPi5)과 RPi4 기록은 `sequence_id`로만 정확히 잇는다.
- ESP32 노드 경유(HTTP) 구성에서는 progress가 노드에서 끊겨 트윈이 결과만 보인다(본선 시연은 직결이라 해당 없음).

## 9. 후속 — `test_rehearsal_contract[lost_response]` 간헐 실패 수리

- 증상: 전체 실행 중 한 번, 단독 실행 중 한 번 실패, 재실행하면 통과. 부하(CPU 스레드 3개)를 걸고 40회 돌리면
  **15회 실패** — 전부 `local_status`·`press_count`(로컬 `safety_stopped`, 누름 1회).
- 원인: `lost_response`는 "RPi4는 끝까지 실행했고 결과 줄만 선에서 사라졌다"는 장면인데, 허브 기한(0.1 s)이 모의 실행과
  경주한다. progress 프레임(3508ff4)이 스레드를 건너 쓰이면서 두 버튼 모의 실행이 부하에서 0.1 s를 넘기고, 그러면 허브의
  `abort`가 실행 도중 도착해 협조 정지 → 장면이 `stop`으로 바뀌었다.
- 수리(`rpi4/simulator.py`): 이 장면에서만 허브→RPi4 선이 `abort`를 **결과 줄이 버려질 때까지** 붙들었다가 넘긴다
  (5 s 시험 한도). 허브는 여전히 기한을 넘겨 `timeout_result_unknown`을 내고, `execute` 1회·`abort` 1회를 보내며,
  로컬은 두 번 누르고 성공 — 시험의 확인 항목은 그대로다. 제품 코드(ActClient·ActExecutor)는 바꾸지 않았다.
- 확인: 같은 부하 40회 **0 실패**, 해당 시험 단독 **30회 연속 통과**, `rpi4/tests/test_simulator.py` 전체 **5회 연속 통과**(각 11).
