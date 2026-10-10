# 2026-10-10 개발자 모드 실물 경로 — 폰 개발자 도구 → RPi5 `/dev` → RPi4 → ESP32 모션 MCU

> **실물 검증 0건.** 가짜 링크·가짜 모션 MCU(`rpi/tools/fake_mcu.py`, 솔레노이드 방식)와 메모리 파이프로만 시험했다.
> 보드·모터·솔레노이드로 한 번도 돌리지 않았다. **기본은 꺼짐(모의)** 이고 env 두 개를 켜야 열린다.

## 1. 무엇을 했나

폰 개발자 도구(홈·1 mm 조그·누름·정지)가 모의 어댑터뿐 아니라 실제 모션 경로(RPi5 `/dev` → RPi4 `dev_motion` 프레임 →
`SerialMotionClient` → `firmware-motion-corexy`)로도 가게 했다. 일반 실행과 같은 `SerialMotionClient`를 쓰므로 MCU의
거절(`busy`·`not_homed`·`soft_limit`·`z_cooldown` …)과 알람이 그대로 올라온다.

| 층 | 파일 | 내용 |
|---|---|---|
| RPi5 어댑터 | `rpi/services/dev_real_motion.py`(새) | `ActDevMotionAdapter` — 매니저의 `MotionAdapter` 실물판. 보내기 전 거절(링크 없음·끊김, RPi4 모의 모션, 옛 RPi4, 비상정지 걸림·모름, 조그 상한), 정지 전달(옛 RPi4면 `abort drive`) |
| RPi5 매니저 | `rpi/services/developer_session.py` | `DevAdapterRefused`(움직이기 전 거절 → 정지 없이 그 코드로 거절, 세션 유지), `max_jog_mm`(어댑터 상한), `adapter_status()`, 움직인 뒤 실패 원인을 `command_error` 문장에 덧붙임. 반납은 여전히 `_maybe_release_locked` 하나 |
| RPi5 배선 | `rpi/api/deps.py`, `rpi/api/service.py` | `dev_real_motion_enabled()` = `SIMPLELAY_DEV_MODE` **그리고** `SIMPLELAY_DEV_REAL_MOTION`. 켜지면 `allow_real_adapter=True`로 실물 어댑터(링크는 `service.local_controller`) |
| RPi5 API | `rpi/api/dev_router.py` | 머리말 계약 7항, 모의 아닌 매니저는 env 두 개일 때만 열림(아니면 503 `real_adapter_not_allowed`), 상태에 `motion_target`·`real_motion_ready`·`real_motion_reason`, 새 거절 코드 → HTTP |
| RPi5 링크 | `rpi/services/act_client.py`, `act_client_controller.py` | `dev_motion()`(요청 id 대조, 재전송 없음, 끊기면 실패), `dev_motion_link()`(읽기만) |
| RPi4 규약 | `rpi4/models/act_messages.py` | `DevMotionMsg`·`DevMotionRefusedMsg`(id 있는 잘못된 프레임은 `bad_args`로 답) |
| RPi4 서비스 | `rpi4/services/dev_motion.py`(새) | `DevMotionService` — 조그 10 mm 울타리, Z 조그 거절, 원점 전 거절, 시간 누름 800 ms 상한·duration만, bring-up 펌웨어 거절, 예외 → `reason`·`moved` |
| RPi4 실행기 | `rpi4/services/act_executor.py` | `dev_motion` 처리(한 번에 하나, 읽기 루프를 막지 않게 작업 스레드), 거절 순서(미지원 → 비상정지·콘센트·모션 준비 → 일반 실행·정지 대기 → 다른 조작), `stop`은 언제나, `abort`·콘센트 비상정지·종료도 개발자 조작을 멈춤, 진행 중 `execute`·`verify_pass`는 `dev_busy`, `act_info.dev_motion_protocol: 1`(서비스가 있을 때만) |
| RPi4 배선 | `rpi4/act_main.py` | `SIMPLELAY_MOTION_MODE=serial`일 때만 `DevMotionService`를 꽂는다(mock이면 광고하지 않음) |
| 모션 어댑터 | `rpi/controller/serial_motion.py` | `request_stop()`이 정지 줄을 썼는지 돌려준다(종전 호출자는 무시) |
| 폰 | `app/lib/services/dev_api_service.dart`, `app/lib/screens/developer_console_screen.dart` | `DevState.motionTarget`·`isReal`, '모의'/'실제 장치' 배지(서버 응답만 근거), 실제 장치면 Z 조그 줄 숨김·준비 안 됨 이유 표시·명령 잠금(정지는 늘 열림)·홈 기한 100 s, 실제 장치라고 명시하지 않은 모의 아닌 서버는 종전처럼 잠금 |
| 문서 | `docs/protocol.md` | `dev_motion`·`dev_motion_result`·`act_info.dev_motion_protocol` |

## 2. 안전 규칙 ↔ 구현

| 규칙 | 어디서 |
|---|---|
| 기본 꺼짐. env 두 개 + RPi4 실물 링크일 때만 | `deps.dev_real_motion_enabled`(둘 다), 어댑터 `_problem`(`act_info.motion=="serial"`·`dev_motion_protocol≥1`), RPi4는 serial일 때만 광고 |
| 아니면 지금 그대로 모의 | env 하나라도 없으면 `MockMotionAdapter` — 기존 개발자 시험 그대로 통과 |
| 중재·소유권 규칙 유지 | ControlArbiter·세션 비밀값·request_id 중복·빈도 제한 변경 없음. 반납은 `_maybe_release_locked`만. 움직이기 전 거절도 `_finish_settle`로 나간다 |
| 일반 실행 중·비상정지 걸림·링크 끊김이면 거절 | RPi5: 중재자(세션 시작 `execution_busy`), 어댑터(`estop_latched`·`estop_unknown`·`link_down`). RPi4: `execution_busy`(실행·확인 주행·정지 버튼 대기), `estop_latched`, `outlet_offline`, `motion_not_ready` |
| 한 번 조그 상한 | RPi5 `SIMPLELAY_DEV_REAL_MAX_STEP_MM`(기본 1 mm, 상한 5 mm로 묶음 — 0 이하·숫자 아님은 시작 거절), 매니저·어댑터 두 곳. RPi4 10 mm 울타리 |
| 소프트 리밋 = RPi4 모션 설정 | RPi4가 `move_to` → `check_soft_limits`(`SIMPLELAY_MOTION_X/Y_MIN/MAX_MM`) → `soft_limit` |
| 원점 먼저 | RPi4 `not_homed`(어댑터 상태 + status 재확인), 펌웨어도 `not_homed` |
| 누름 = 솔레노이드 시간 누름 ≤ 800 ms | RPi4 `press_mode_unsupported`·`press_too_long`, 어댑터의 MCU `z_on_max_ms` 검사, 펌웨어 상한 |
| 정지는 언제나 | `/dev/stop`·세션 끝·세션 안 `stop`·heartbeat 끊김·일반 `/stop` → 어댑터 `stop` → RPi4 `dev_motion stop` → MCU `stop`. 옛 RPi4면 `abort drive`. 링크가 끊겨 확인 못 하면 종전처럼 fault 잠금. RPi4 `abort`도 진행 중 개발자 조작을 멈춘다 |
| 자동 재전송·재개 없음 | 요청 하나 = 프레임 하나 = 답 하나. 기한 초과는 실패 + 정지. 정지로 끊기면 원점부터. 폰은 누를 때 한 번만 보낸다 |
| 규약 판 | `act_info.dev_motion_protocol: 1`, 없으면 RPi5가 보내지 않고 `dev_protocol_unsupported` |

## 3. 켜는 법 (env·순서)

**RPi4** (`/etc/simplelay/…` 또는 실행 env): 실제 모션 어댑터가 필요하다 — 이것 없이는 `dev_motion_protocol`을 알리지 않는다.

```
SIMPLELAY_MOTION_MODE=serial
SIMPLELAY_MOTION_PORT=/dev/ttyUSB0          # ESP32 USB 시리얼(실제 장치 이름 확인)
SIMPLELAY_MOTION_BAUD=115200
SIMPLELAY_MOTION_STATUS_TIMEOUT_S=… HOME_TIMEOUT_S=75 MOVE_TIMEOUT_S=… PRESS_TIMEOUT_S=…
SIMPLELAY_MOTION_R_OUT=1400 PULLEY_TEETH=20 BELT_PITCH_MM=2 A_SIGN=1 B_SIGN=1   # 펌웨어 config.h와 같게
SIMPLELAY_MOTION_X_MIN_MM=3 Y_MIN_MM=3 X_MAX_MM=… Y_MAX_MM=…                  # 소프트 리밋(원점 후퇴 3 mm 이상)
SIMPLELAY_MOTION_PRESS_MODE=duration PRESS_DRIVE_MS=… PRESS_DWELL_MS=…        # 구동+유지 ≤ 800
```
(전체 이름은 `firmware-motion-corexy/README.md` "RPi4 설정과 맞출 값"·`serial_motion.MOTION_ENV_NAMES`. 값은 전부 실측 필요.)

**RPi5**:
```
SIMPLELAY_ACT_MODE=uart                     # RPi4 링크(없으면 실물 준비 안 됨: act_link_unavailable)
SIMPLELAY_DEV_MODE=1
SIMPLELAY_DEV_TOKEN=<16자 이상>
SIMPLELAY_DEV_REAL_MOTION=1                 # 이것이 없으면 지금과 똑같이 모의
SIMPLELAY_DEV_REAL_MAX_STEP_MM=1            # 선택, 기본 1, 상한 5
```

폰: 설정 → 개발자 탭(앱 `developer_mode`) → 개발자 도구 → 토큰 저장. 배지가 **'실제 장치'** 이고 "지금은 움직일 수
없어요" 문장이 없어야 조작이 열린다. 순서: 세션 시작 → **홈** → 1 mm 조그 → 누르기. 정지 버튼은 언제나 열려 있다.
끄려면 RPi5 `SIMPLELAY_DEV_REAL_MOTION`을 지우고 백엔드를 재시작한다.

## 4. 하드웨어 날 순서

각 단계에서 이상하면 **멈추고 기록**한 뒤 넘어가지 않는다. 물리 E-STOP을 손 닿는 곳에, 모터 전원(VM)은 E-STOP 경유.

1. **bring-up 빌드 먼저**(`esp32dev_bringup`, 데스크톱 USB·시리얼 모니터) — `firmware-motion-corexy/README.md` "처음 켤 때
   순서" 0~7: 배너·엔코더 → 모터 A/B 방향(벨트 전) → 벨트 뒤 +X/+Y → `Z`·작은 `G` 이동·게인 → `T 100` 공중 누름 → `H` 스톨 원점.
   잡은 부호·게인은 `config.h`에 옮긴다. **이 빌드가 올라간 채로는 RPi4 개발자 조작이 `bringup_firmware`로 거절된다.**
2. **시연 빌드(`esp32dev`)를 올리고** RPi4 env(§3)를 펌웨어 `config.h`와 맞춘다. RPi4에서 조그 CLI로 먼저 확인:
   `python -m rpi.tools.jog --fake-mcu --rehearsal-config`(리허설) → 실제 포트 `status`
   ([jog-cli devlog](devlog_2026-09-29-jog-cli.md) §5). `act_main`을 켜고 로그에 "developer motion ops accepted"를 확인.
3. RPi5 env(§3)로 백엔드를 켜고 폰 개발자 도구에서 배지 '실제 장치'·준비됨을 확인. `/dev/state`의 `real_motion_ready`가
   `true`가 아니면 `real_motion_reason`을 읽고 멈춘다.
4. **홈** — E-STOP에 손을 올린 채. 원점 방향·후퇴(3 mm)를 눈으로 확인. 홈 전 조그가 `not_homed`로 거절되는지도 한 번 본다.
5. **작은 조그** — X+1 → X−1 → Y+1 → Y−1(기본 상한 1 mm). 자로 실제 이동을 재어 `docs/실측-기록표.md`에. 방향이 반대면
   펌웨어 부호부터(RPi4 `A_SIGN`/`B_SIGN`은 펌웨어와 함께). 소프트 리밋 밖 조그가 `soft_limit`으로 거절되는지 확인.
   정지 버튼(폰)·일반 `/stop`·폰 앱을 내려 heartbeat 끊기가 각각 MCU `stop`으로 가는지 `SIMPLELAY_MOTION_LOG_PATH` 줄 기록으로 확인.
6. **누르기** — 가장 짧은 `PRESS_DRIVE_MS`·`PRESS_DWELL_MS`부터, 누를 곳 없이 공중에서 먼저. 발열·복귀·냉각 거절(`z_cooldown`)을 본다.
   그다음 조그로 맞춘 버튼 위에서 한 번.

## 5. 시험

**수정 전 실패 확인(red-first).** 시험 세 파일을 먼저 쓰고 돌렸다 — 구현 전에는 세 파일 모두 수집 단계에서 실패
(`rpi.services.dev_real_motion` 없음, `DevMotionMsg` 없음). 구현 뒤에는 안전 장치를 하나씩 되돌린 변형으로 해당 시험이
실패하는지 확인했다(모두 확인 뒤 원본 복구):

| 되돌린 장치 | 결과 |
|---|---|
| env 하나(`SIMPLELAY_DEV_MODE`)만으로 실물 어댑터 | 1 failed |
| RPi4 모의 모션 거절 / 옛 RPi4 규약 확인 / 비상정지 거절 / 링크 끊김 거절(RPi5) | 각 1 failed |
| 조그 상한 — 매니저만 제거 / 매니저+어댑터 제거 | 1 passed(이중 울타리) / 1 failed |
| RPi5 정지 전달 제거 | 3 failed(/dev/stop·heartbeat 끊김·일반 /stop) |
| 옛 RPi4 정지 대체(`abort drive`) 제거 | 1 failed |
| 매니저가 움직이기 전 거절을 실패로 취급(정지를 보냄) | 2 failed |
| RPi4 원점 확인 두 곳 제거(한 곳만이면 다른 곳이 막음) | 2 failed |
| RPi4 10 mm 울타리 / 비상정지·준비 확인 / 일반 실행 중 확인 / bring-up 거절 / 800 ms 상한 / 광고를 늘 싣기 | 각 1 failed |
| RPi4 `dev_motion stop`이 MCU stop을 안 보냄 / `abort`가 개발자 조작을 안 멈춤 / 진행 중 조작이 있어도 execute 받음 | 2·1·1 failed |
| 폰 `isReal`을 늘 false로 | 2 failed(실제 장치 배지 시험 둘) |

변형 중 처음엔 `abort` 시험이 살아남았다 — 가짜 MCU 이동 지연(1.0 s)이 이동 기한(1.0 s)과 같아 기한 초과 정지가
대신 `stop`을 보냈다. 지연을 0.6 s로 줄이고 결과가 `stopped`인지까지 보게 고쳤다.

- 새 시험: `rpi/tests/test_dev_real_motion.py` 24건(가짜 RPi4 링크 + 실제 FastAPI), `rpi4/tests/test_dev_motion.py` 19건
  (실제 ActExecutor + SerialMotionClient + 가짜 MCU), `rpi4/tests/test_dev_motion_link.py` 2건(RPi5 매니저 → ActClientController →
  ActClient ⇄ ActExecutor → DevMotionService → 가짜 MCU 끝-끝), 폰 위젯 3건(모의 배지·실제 장치 배지와 조작·준비 안 됨 이유와 명령 잠금).
- 실행: 백엔드+rpi4 `PYTHONUTF8=1 .venv/Scripts/python.exe -m pytest -q rpi rpi4 --basetemp C:/pyt_dev/<고유> -p no:cacheprovider`
  → **2,655 passed**(작업 전 2,610 + 45, 저장소 가드 포함 — `test_repo_guard.py` 단독 5 passed. 새 파일은 아직 추적 전이라 가드가 내용을 보지 않아 금지어를 따로 확인: 없음). 폰 `flutter analyze` error·warning 0(기존 info 4),
  `flutter test --exclude-tags screenshot` **579**(576 + 3), `--tags screenshot` **55** 통과(골든 갱신 없음 — 개발자 도구 골든 없음).

## 6. 한계·남은 것

1. **실물 0건.** 정지 '확인'은 RPi4가 MCU에 정지 줄을 썼다는 뜻이다 — 물리 정지(엔코더 속도 0)는 아니다. 최종 권한은 물리 E-STOP.
2. 실물 조그는 TTL(누르고 있는 동안만)이 아니라 상한으로 묶인 절대 목표 한 번이다. 한 번 이동 중에는 정지로만 끊는다.
3. `press <버튼>`은 **지금 위치**에서 누른다 — 버튼 좌표로 가지 않는다. 버튼 id는 등록·보정 확인과 기록용 이름이다.
4. 기한(홈 90 s·조그 20 s·정지 3 s)과 기본 상한 1 mm는 호스트 박자·첫날 값이다(측정 필요). 폰 홈 기한 100 s.
5. 위치 기준은 MCU 엔코더(모터 축) — 벨트 미끄럼은 보이지 않는다(firmware devlog §9-4).
6. 개발자 조작 중 RPi5 프로세스가 죽으면 진행 중 이동은 상한 안에서 끝나고, RPi4·MCU 쪽 정지는 RPi4 이동 기한·펌웨어 워치독에 맡긴다
   (RPi5 heartbeat 감시자도 함께 죽기 때문).
7. `CLAUDE.md` 아키텍처 줄의 "/dev mock 전용" 문구는 이 세션에서 고치지 않았다(설정 파일 수정은 사용자 확인 뒤) — 바꿀 문장:
   "개발자 API(`/dev/*`): `SIMPLELAY_DEV_MODE` + `SIMPLELAY_DEV_TOKEN`(일반 API 키와 별개), **기본 모의, 실물은 env 두 개
   (`SIMPLELAY_DEV_MODE`·`SIMPLELAY_DEV_REAL_MOTION`) + RPi4 실물 링크(`act_info.motion=serial`·`dev_motion_protocol`)일 때만**".
