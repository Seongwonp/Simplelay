# 2026-09-28 — 모션 어댑터 뼈대·CoreXY 변환·좌표 전달·누름 주변 원시 기록기

하드웨어(FIT0482 ×3, JMOD-MOTOR-1 ×2, 제어 MCU 미정) 수령 전, 하드웨어 없이 시험할 수 있는 범위만 만들었다.
**모든 새 실행 경로는 실물 미검증이다.** 메모리 파이프·가짜 MCU·mock 센서로만 시험했다. "모터가 움직인다"는
근거로 쓰지 않는다. 기본 실행 경로는 여전히 `MockGrblClient`다(`SIMPLELAY_MOTION_MODE` 기본 `mock`).

원칙: 하드웨어 기술 조사 보고서 C·D절의 식만 쓴다. 모르는 값(R_out·풀리 톱니 수·벨트 피치·XY 리밋·방향 부호·
Z 누름 깊이/시간·타임아웃)은 **기본 None**이고, 그 값이 필요한 동작은 움직이기 전에 거절한다. 공식 공칭 700이나
"GT2 2 mm·20T" 같은 흔한 값을 기본값으로 넣지 않았다. 테스트의 수치는 전부 "시험용 임의 값"으로 표시했다.

## 1. CoreXY 변환 — `rpi/controller/kinematics.py`

- 순수 함수: `ΔA = ΔX + ΔY`, `ΔB = ΔX − ΔY`와 역, `L = N/R_out · Z_p · p`와 역, `res = Z_p·p/R_out`.
- `CoreXYConfig`(모든 필드 Optional, 기본 None): `counts_per_output_rev`(R_out, 디코딩 배율 포함 실측값),
  `pulley_teeth`, `belt_pitch_mm`, `x_min_mm`·`x_max_mm`·`y_min_mm`·`y_max_mm`(소프트 리밋), `a_sign`·`b_sign`.
- 비어 있는 값이 필요하면 `KinematicsNotConfigured`(비어 있는 필드와 환경 변수 이름을 메시지에 적음).
  리밋 밖이면 `SoftLimitExceeded`. `from_env()`는 없는 값을 None으로 남긴다.
- Z는 변환 기구 미정이라 mm 변환을 두지 않았다(보고서 D절).

## 2. 모션 MCU 어댑터 뼈대 — `rpi/controller/serial_motion.py`

- `SerialMotionClient(GrblClient)`: `execution_mode = REAL`(실제 액추에이터를 명령하는 어댑터라는 선언. 물리 성공과는 별개),
  `requires_coordinates = True`. 명령: `status`/`connect`, `home`, `move_to(x_mm, y_mm)`, `press(PressCommand)`,
  `request_stop()`/`reset_stop()`.
- 프로토콜: **줄 단위 JSON**, 요청 `id`로 응답 짝짓기. G-code를 고르지 않은 이유는 다른 링크와 도구를 공유하고,
  엔코더 DC 모터용 필드를 비표준 확장 없이 싣고, GRBL 설계가 이미 폐기됐기 때문이다(`docs/protocol.md` 새 절).
- 전송은 `LineTransport`(`write_line`/`read_line`)로 주입. 시험은 `InMemoryLinePipe`, 실기기는 `PySerialLineTransport`(미검증).
- 상태: UNKNOWN → UNHOMED → READY / BUSY / STOPPED / ALARM. 홈 확인 전 이동·누름 거절(`auto_home`은 기본 꺼짐).
- 움직이기 전에 확인하는 것: 좌표 유무, 재시도 XY 오프셋·깊이 증가 설정과 상한, 소프트 리밋, 기구 값, 기한 설정.
- 기한 초과: `stop` 전송 후 위치를 믿지 않음(재홈 전까지 거절). 늦게 온 응답은 `id`가 달라 버린다.
- MCU `ok:false`·`alarm` 이벤트 → ALARM. 판독 불가 줄은 무시하고 로그.
- 정지: `ClosedLoopController.request_stop()`이 어댑터의 `request_stop()`을 **즉시** 부른다(설계 §2 "이동 중 정지" 1·2항).
  블로킹 누름이 `MotionStopped`로 끝나고 폐루프는 재시도하지 않는다. 정지로 끊긴 뒤에는 재홈 전까지 준비 안 됨.
  보낸 것은 '명령 전송' 단계까지이며 MCU 정지 보고·물리 정지 확인은 실물에서 잰다.
- `MotionSafetyController`: 폐루프 안전 정지를 MCU `stop`으로 전달.
- `rpi4/act_main.py`: `SIMPLELAY_MOTION_MODE=serial` + `SIMPLELAY_MOTION_PORT` + `SIMPLELAY_MOTION_BAUD`(둘 다 기본값 없음)이면
  어댑터를 꽂는다. 기구·누름 값이 비어 있으면 시작 로그에 목록을 남기고 누름마다 거절한다. 알 수 없는 모드는 시작 거절.
- 설계 §3(누름 구간을 검증기에 넘기기), 재시도·페이싱 대기의 즉시 깨우기(설계 §2 3항), MCU 버전 조회, H1a용 홈·조그 CLI는 **하지 않았다**.

## 3. 좌표가 실행기까지 — `PressCommand`·폐루프·UART·서비스

- `PressCommand`에 선택 필드 `x_mm`, `y_mm`, `press_ms`(버튼맵의 누름 유지 시간)를 추가. 한쪽 좌표만·NaN은 거절.
  다이얼(`detents`)은 어댑터가 회전 동작을 모르므로 싣지 않았다.
- `ButtonTarget(x_mm, y_mm, press_ms)`, `ClosedLoopController.execute(buttons, targets=None)`.
  좌표가 필요한 어댑터(`requires_coordinates`)인데 좌표 없는 버튼이 있으면 **아무것도 누르기 전에** `MissingButtonCoordinates`.
- RPi5↔RPi4 `execute`에 선택 필드 `targets`(`docs/protocol.md`). 비어 있으면 키를 넣지 않아 종전 줄과 같다.
  RPi4는 이상한 `targets`가 섞이면 메시지 전체를 버린다.
- `SimpleLayService`: 보정 버전과 **같은 순간에** 레지스트리의 보정 좌표를 스냅샷해 실행 스레드로 넘긴다.
  `supports_button_targets`를 밝힌 실행 대상(`ClosedLoopController`, `ActClientController`)에만 넘기고, 좌표가 없으면
  종전 `execute(buttons)` 호출 그대로다. 격자 칸 번호로 좌표를 만들지 않는다.
- 하드웨어 연결 설계 §1의 "어댑터가 서버 값을 받을지, RPi4 로컬 프로필만 쓸지" 결정은 아직 열려 있다. 이번 변경은 서버 값을
  받을 수 있는 길을 만든 것이지 결정이 아니다. RPi4 로컬 보정 프로필·버전 보고는 없다.

## 4. 누름 주변 원시 기록기 — `rpi/verifier/recorder.py`

- 기존 판독 인터페이스를 그대로 쓴다: `CurrentReader.read_voltage()`, `AudioReader.read_frame()`, `PowerSensor.read()`.
  판정기(`CurrentSensor.is_pressed`·`AudioSensor`·`fuse`·`PowerSignatureDetector`)는 import하지 않는다(테스트 고정).
- 전류는 **전압 그대로** 남긴다(영점·감도가 추정값이라 A 환산 시 가정이 섞인다). 음향은 RMS·피크·샘플 수, JSONL에서 원시 PCM 선택.
  전력은 W와 센서 시각. 모든 행에 호스트 단조 시각(ns).
- CSV·JSONL 출력. 창 모드(`--pre-s`/`--post-s`): 링 버퍼에 두었다가 `press_start` 전·`press_end` 후 구간만 남긴다.
  창 길이는 측정 필요 값이라 **기본은 창 없음(전부 기록)**.
- 실행 경로 훅: `RecordingGrblClient`(어떤 GrblClient든 감싸 누름 호출 앞뒤를 찍고 실행 모드·좌표 요구·정지 훅을 그대로 드러냄),
  `motion_event_hook`(MCU 이벤트를 `mcu_` 접두로 찍어 호스트 시각과 구분 — 시리얼 지연 측정용).
- CLI: `python -m rpi.verifier.recorder --mock --duration 2` / `--current --adc-gain <값> --audio`. `--current`는 gain 기본값이 없다.
  합성 입력과 실측 입력은 섞지 않는다. 실물 전력 센서 구현은 아직 없어 `--power` 실측 옵션은 두지 않았다.
- 기존 `rpi/bench/raw_recorder.py`(9/14, 벤치 키보드 CSV, verifier 비의존)는 그대로 둔다. 새 기록기는 실행 경로에 끼우는 쪽이다.
- `act_main`에는 아직 기록기를 배선하지 않았다(실측 입력 리더를 동시에 여는 구성은 실기기에서 확인 필요).

## 하드웨어 담당자가 채워야 할 값 (전부 현재 미설정 → 누름 거절)

| 환경 변수 | 뜻 | 근거·방법 |
|---|---|---|
| `SIMPLELAY_MOTION_R_OUT` | 출력축 1회전당 카운트(디코딩 배율 포함) | 출력축 1회전(또는 10회전) 실측, x1·x4 구분(보고서 E절 6) |
| `SIMPLELAY_MOTION_PULLEY_TEETH` | 구동 풀리 톱니 수 | 제작자 제공(E절 7) |
| `SIMPLELAY_MOTION_BELT_PITCH_MM` | 벨트 피치 mm | 제작자 제공(E절 7) |
| `SIMPLELAY_MOTION_X_MIN_MM` · `_X_MAX_MM` · `_Y_MIN_MM` · `_Y_MAX_MM` | 원점 기준 소프트 리밋(여유 뺀 값) | 기구 치수(E절 7) |
| `SIMPLELAY_MOTION_A_SIGN` · `_B_SIGN` | 모터 A·B 방향 부호(±1) | 배선·엔코더 방향 실측(E절 6) |
| `SIMPLELAY_MOTION_PRESS_MODE` | `depth` 또는 `duration` | Z 기구 결정(E절 8) |
| `SIMPLELAY_MOTION_PRESS_DEPTH_COUNTS` · `_STEP_COUNTS` · `_MAX_COUNTS` | depth 모드 Z 목표·재시도 증가·상한(Z 카운트) | Z 기구 실측 |
| `SIMPLELAY_MOTION_PRESS_DRIVE_MS` · `_STEP_MS` · `_MAX_MS` | duration 모드 구동 시간·증가·상한 | Z 기구 실측 |
| `SIMPLELAY_MOTION_PRESS_DWELL_MS` | 누름 유지 시간(버튼맵 `press_ms`가 우선) | 가전 버튼 실측 |
| `SIMPLELAY_MOTION_RETRY_XY_OFFSETS_MM` | 재시도 n회차 XY 오프셋 `dx,dy;dx,dy` | 버튼 크기·기구 정밀도 실측 |
| `SIMPLELAY_MOTION_STATUS_TIMEOUT_S` · `_HOME_` · `_MOVE_` · `_PRESS_TIMEOUT_S` | 명령별 응답 기한 | 이동·홈·누름 시간 실측 |
| `SIMPLELAY_MOTION_PORT` · `SIMPLELAY_MOTION_BAUD` | MCU 장치 경로·보드레이트 | MCU·펌웨어 결정(E절 10) |

MCU 펌웨어 쪽은 `docs/protocol.md`의 "모션 MCU 링크" 절이 제안 계약이다. 펌웨어가 정해지면 그 절과 어댑터를 함께 고친다.

## 검증

- 백엔드 전체(`.venv/Scripts/python.exe -m pytest -q -p no:cacheprovider`): 변경 전 **1,531 통과** / 1 실패 / 41 오류 →
  변경 후 **1,644 통과**(+113: 변환 28, 어댑터 29, 좌표 전달 29, 기록기 19, act_main 배선 8) / 1 실패 / 41 오류.
  실패 1건(`test_dbus_native.py::TestAddText::test_encodes_metadata_and_returns_id`, dbus_fast)과 오류 41건(`tmp_path` 임시 루트
  PermissionError)은 변경 전과 같은 환경 문제다. 골든 없음(백엔드).
- 결함을 되살린 변형에서 새 테스트가 실패하는 것을 확인했다: 정지 전달 제거, 늦은 응답 `id` 필터 제거, 소프트 리밋 제거,
  좌표 사전 검사 제거, 서비스 좌표 스냅샷 제거, `targets` 키 검사 제거, `ActClient`의 `targets` 전송 제거, 기록기 사전 창·사후 창 제거.
  각각 확인 뒤 원래 코드로 되돌렸다.
- 전체 실행 한 번에서 `test_act_client.py::test_result_with_wrong_sequence_id_does_not_complete_pending`(0.2 s 기한의
  시간 민감 테스트)이 실패했다. 단독 5회·전체 재실행에서 모두 통과해 부하에 따른 흔들림으로 본다(같은 시각 다른 작업이 기기를 쓰고 있었다).
- 프로젝트에 설정된 파이썬 린터가 없어 린트는 실행하지 않았다.
- 실물 모터·엔코더·MCU·ADS1115·마이크로는 아무것도 확인하지 않았다.

## 다음

1. 하드웨어 담당자에게 위 표의 값과 보고서 E절 질문 답을 받는다. 받기 전에는 serial 모드로 누름이 나가지 않는다.
2. MCU·펌웨어 결정 뒤 `docs/protocol.md` 모션 절을 확정하고, H1a(홈·리밋·소량 조그·정지 지연 3단계) 전용 CLI를 만든다.
3. 설계 §3: 누름 구간(`press_start`/`press_end`)을 검증기에 넘기는 인터페이스와 기록기의 링 버퍼 재사용.
4. 설계 §1 결정: 서버 좌표 vs RPi4 로컬 보정 프로필·버전 보고.

커밋·푸시는 수행하지 않았다.
