# 2026-09-29 — 홈·조그 CLI와 실행 경로 원시 기록기 배선

하드웨어(CoreXY, FIT0482 ×3, JMOD-MOTOR-1 ×2) 수령 전 작업이다. **새 경로는 전부 실물 미검증이다.**
가짜 MCU(메모리 파이프)와 합성 센서 입력으로만 시험했다. "모터가 움직인다"거나 "센서 값이 이렇다"는
근거로 쓰지 않는다. 기본 실행 경로는 그대로다(`SIMPLELAY_MOTION_MODE` 기본 `mock`, 기록기 기본 꺼짐).

## 1. 홈·조그 CLI — `python -m rpi.tools.jog` (`rpi/tools/jog.py`)

- 하드웨어 도착 첫날 사람이 `SerialMotionClient`를 한 줄씩 부리는 도구. REPL과 `-c "명령"`(여러 번, 순서대로 실행 후 종료) 둘 다.
- 연결: `--port`/`--baud`, 없으면 `SIMPLELAY_MOTION_PORT`/`SIMPLELAY_MOTION_BAUD`(기본값 없음 — 없으면 종료 코드 2).
  기구·누름·기한 값은 act_main과 같은 `SIMPLELAY_MOTION_*`에서 읽는다.
- 명령: `status`, `home`, `jog DX DY`(mm, 상대), `goto X Y`(mm, 절대), `press [--depth N | --duration MS] [--dwell MS]`,
  `stop`, `reset`, `raw JSON`, `help`, `quit`. 명령 실행 중 Ctrl+C → 정지 명령 전송.
- **거절은 어댑터 그대로**: 홈 전 이동·누름, 소프트 리밋 밖, 기구·기한 값 미설정을 도구가 따로 우회하지 않는다.
  예외 메시지는 가공 없이 `거절 <예외 이름>: <메시지>`로 출력한다 — `KinematicsNotConfigured`·`MotionConfigError`
  메시지에 채워야 할 환경 변수 이름이 그대로 보인다. 시작할 때 누름에 필요한데 비어 있는 설정 목록도 출력한다.
- **시작 시 자동 홈 없음.** `SIMPLELAY_MOTION_AUTO_HOME=true`여도 이 도구에서는 끈다(출력으로 알린다).
- 조그 기준 위치는 호스트가 짐작하지 않는다: `status`로 MCU가 보고한 A·B 카운트를 `motor_counts_to_xy`로 mm로
  바꾼 값에 더한다. 카운트 반올림 때문에 표시 좌표에 한 카운트 이하의 오차가 보일 수 있다.
- `press`는 현재 위치에서 누른다. `--depth`/`--duration`은 그 한 번만 설정을 덮어쓰고, 설정의 상한 검사는 그대로다.
- `raw`는 한 줄을 그대로 보내고 같은 `id`의 응답까지 받은 줄을 출력한다. **`move`/`press`/`home`은 거절**한다
  (홈·리밋 확인을 건너뛰기 때문). `id`가 없으면 900001부터 붙인다(어댑터 요청 id와 겹치지 않게).
- `--log 경로`: 보낸 줄 `>>`, 받은 줄 `<<`, 입력 명령 `##`, 거절 `!!`를 벽시계 시각·세션 상대 시각과 함께 **이어 쓴다**.
  원시 기록은 `data/`(.gitignore) 아래에 둔다. 저장소에 올리지 않는다.
- `--fake-mcu`: 메모리 가짜 MCU에 붙어 하드웨어 없이 리허설. `--rehearsal-config`(가짜 MCU 전용)는 **리허설용 임의 값**을
  쓴다 — 실기기에서는 거절된다. 가짜 MCU 없이 이 값을 쓰는 길은 없다.
- 가짜 MCU는 시험 파일에 있던 것을 `rpi/tools/fake_mcu.py`로 옮겨 시험과 CLI가 같이 쓴다. `move`를 받으면 A·B 카운트를
  현재 위치로 두고 `status`가 보고한다. 모르는 명령에는 `unknown_cmd` 오류로 답한다. 모터·엔코더·리밋·기한은 흉내 내지 않는다.

## 2. 실행 경로 원시 기록기 배선 — `rpi4/act_main.py`, `rpi/verifier/recorder.py`

- `SIMPLELAY_RECORDER_PATH`가 있으면 `LiveRecorder`를 열어 이어 쓴다(`.csv`면 CSV, 그 밖은 JSONL). **기본 꺼짐.**
  시작 로그에 켜짐/꺼짐과 경로, 창 모드 여부를 항상 남긴다.
- 모션 클라이언트를 `RecordingGrblClient`로 감싸 누름 호출 앞뒤(`press_start`/`press_end`)를 찍고, serial 모드면
  `motion_event_hook`을 어댑터 `on_event`로 넘겨 MCU 이벤트(`mcu_press_start` 등)를 같은 시각축에 찍는다.
  감싸도 실행 출처(`execution_mode`)·좌표 요구·정지 훅은 그대로 드러난다.
- 입력 선택(합성으로 대체하되 숨기지 않는다):
  - 전류: `SIMPLELAY_RECORDER_ADC_GAIN`이 있을 때만 ADS1115를 연다(기본값 없음). 채널은 `SIMPLELAY_RECORDER_ADC_CHANNEL`(기본 0).
  - 음향: `SIMPLELAY_RECORDER_AUDIO=true`일 때만 마이크를 연다. 위험소리 감지와 같은 마이크를 동시에 여는 것은 실기기 확인 필요.
  - 전력: 저장소에 실기기 전력 리더가 아직 없어 항상 합성.
  - 열지 않았거나 열기에 실패한 입력은 합성 값으로 기록하고, **행의 source를 `mock_current`/`mock_audio`/`mock_power`로** 적는다.
    시작 이벤트 메모와 시작 로그(WARNING)에 무엇이 합성인지와 이유가 남는다.
- 창 모드: `SIMPLELAY_RECORDER_PRE_S`·`SIMPLELAY_RECORDER_POST_S`(함께). 비우면 전부 기록 — 파일이 계속 커진다.
  창 길이는 **측정 필요** 값이라 기본값을 두지 않았다. 한쪽만 주면 시작을 거절한다.
- 기록기 변경: `record_*`와 `*_step`에 선택 인자 `source`(기본값은 종전과 같음), `CsvSink(header=False)`로 이어 쓰기 시 머리행 중복 방지.
  CLI `--mock`의 source 표기는 바꾸지 않았다.

## 3. 시험

- `rpi/tests/test_jog_cli.py` 16건: 가짜 MCU 대본 세션, 조그가 MCU 보고 위치 기준인지, 홈 전 거절(이동 명령 미전송),
  자동 홈 없음, 소프트 리밋 거절, 누름 상한, `KinematicsNotConfigured` 원문 출력, 기한 미설정 환경 변수 표시, raw 응답·거절,
  로그 파일 형식·이어 쓰기, 잘못된 입력, 인자 조합 거절, Ctrl+C → 정지 전송.
- `rpi4/tests/test_act_main_recorder.py` 10건: 기본 꺼짐(훅도 안 넘김), 켜짐 로그·합성 입력 경고, 리더 열기 실패 시 합성 대체,
  실제 리더가 열리면 `current`로 기록, 창 설정 짝 검사, CSV 머리행 한 번, mock 모션 누름 기록, serial 모션의 MCU 이벤트 순서.
- `rpi/tests/test_serial_motion.py`는 가짜 MCU를 새 모듈에서 가져온다(시험 내용 변경 없음, 29건 통과).
- 전체 백엔드: **1,684 통과**, 실패 1(기존 `test_dbus_native` dbus_fast), 오류 41(기존 tmp_path 권한). 새 시험은 tmp_path 대신 표준 임시 폴더를 쓴다.

## 4. 하지 않은 것 / 남은 것

- 실기기 시리얼·MCU 펌웨어와 한 번도 맞춰 보지 않았다. MCU 펌웨어 쪽 줄 단위 JSON 구현은 없다.
- 정지는 '명령 전송'까지다. MCU 정지 보고·물리 정지 확인은 실물에서 잰다. 물리 E-STOP이 최종 권한이다.
- 기록 파일 회전·크기 상한 없음. 창 길이·전류 gain은 실측 뒤 정한다.
- 조그 속도·가감속 설정 없음(MCU가 정한다고 가정한 규약 그대로).

## 5. 하드웨어 도착 첫날 순서

각 단계에서 이상하면 **멈추고 기록한 뒤** 다음으로 넘어가지 않는다. 물리 E-STOP을 손 닿는 곳에 둔다.

1. **전원** — 모터 전원 차단 상태로 RPi4·MCU만 켠다. MCU 시리얼 장치가 보이는지 확인(`ls /dev/ttyUSB* /dev/ttyACM*`).
   모터 전원은 E-STOP 경유로만, 벨트 장력·기구 간섭을 손으로 먼저 확인.
2. **리허설** — 같은 명령을 가짜 MCU로 먼저 친다.
   `python -m rpi.tools.jog --fake-mcu --rehearsal-config --log data/bench/jog-rehearsal.log`
   → `status` → `home` → `jog 1 0` → `press` → `stop`. 출력과 로그 형식을 눈에 익힌다.
3. **실제 포트 status** — 기구 값은 아직 비워 둔 채로
   `python -m rpi.tools.jog --port <장치> --baud <펌웨어 값> --log data/bench/jog-day1.log` → `status`.
   비어 있다고 나오는 환경 변수를 확인한다(`SIMPLELAY_MOTION_STATUS_TIMEOUT_S` 등). 응답 형식이 규약과 다르면 여기서 멈춘다.
4. **home** — `SIMPLELAY_MOTION_HOME_TIMEOUT_S`를 넉넉히 두고 `home`. E-STOP에 손을 올린 채. 원점 방향·리밋 스위치 동작을 눈으로 확인.
5. **작게 조그** — 제작자·실측 값으로 R_out·풀리·피치·방향 부호·소프트 리밋을 채운 뒤 `jog 1 0`, `jog 0 1`, `jog -1 0`처럼
   1 mm 단위로. 자로 실제 이동을 재어 `docs/실측-기록표.md`에 적는다. 방향이 반대면 `SIMPLELAY_MOTION_A_SIGN`/`B_SIGN`부터 고친다.
6. **기록기 켜고 누름** — Z 누름 깊이·시간을 가장 작은 값부터. 벤치에서는 `python -m rpi.verifier.recorder --current --adc-gain <값> --audio`
   를 옆에 띄우거나, act_main 경로라면 `SIMPLELAY_RECORDER_PATH=data/bench/press-day1.jsonl`로 켜고 누른다.
   시작 로그에서 어느 입력이 `MOCK`인지 확인한다 — 합성 입력(`mock_*`) 행은 분석에서 뺀다.
