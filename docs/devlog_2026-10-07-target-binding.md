# 2026-10-07 실행 대상 ↔ CT 채널 결속 — 인계 노트북-3 §B(H3)·§C(M1)·§D(M2)

평가 기준 커밋 `1727698`의 HIGH H3, MEDIUM M1, M2 수리. **전부 가짜 콘센트 모듈(합성 전력)·모의 모션 수준이다 — 실물 CT·세탁기·인터폰·ADS1115 연결 0건.** 임계값·채널·전압 값은 모두 실측 필요.

## 결함
- **H3** `rpi4/act_main.py`가 L3 판정기·잔여 전류 꼬리·정지 대기 전력 확인을 모두 전자레인지 CT 채널(`OUTLET_PRESS_APPLIANCE`)로 만들었다. `ExecuteMsg`에 대상이 없고 `hold.appliance_id`도 판정기에 안 쓰여, **세탁기·인터폰 실행이나 정지가 전자레인지 전력 변화로 확인될 수 있었다.** 대응(`SIMPLELAY_OUTLET_CHANNELS`)이 비면 `channel_for`가 모든 가전에 채널 0을 돌려줘 같은 일이 생긴다.
- **M1** 운영 경로 `ClosedLoopController(...)`에 `acceptance=`가 없어 L2 분기를 타지 않는다.
- **M2** `CurrentSensorConfig` 기본 영전류 2.5 V와 ADS1115 gain 2(±2.048 V)는 함께 쓸 수 없다(영점이 측정 범위 밖).

## 바꾼 것
- **프레임(execute 규약 2)** `rpi4/models/act_messages.py`: `execute.appliance_id` 필수. 없으면 `ExecuteRefusedMsg` → 실행기가 누르지 않고 `error {reason:"target_required"}`(조용히 버리면 RPi5가 응답 제한시간까지 기다린다). `hold.appliance_id`는 실행 대상과 같아야 하고(다르면 메시지 전체 버림), 없으면 대상으로 채운다. `result`에 `appliance_id`, `act_info`에 `execute_protocol: 2`.
- **결속** `rpi4/services/target_binding.py`(새 파일) `TargetBinder`: 대상 CT 채널 = 대응에 적힌 채널만, 대응이 비면 채널 0은 전자레인지만. L3 off → 판정 없음, mock → 합성(대상 무관, mock 표시), real → 대상 채널 판정기(대상마다 한 번 생성)·꼬리 훅. **real인데 채널 없는 대상은 누르기 전 `error {reason:"target_unbound"}`.** 전력으로 볼 수 없는 가전은 `SIMPLELAY_L3_NONE_TARGETS`(예: `intercom`)에 적으면 판정 없이(`operation_confirmed=null`) 실행한다. 정지 대기 확인은 계획 대상 채널, 채널이 없으면 `NoRunProbe`(정지는 미확인으로만 끝).
- **실행기** `ActExecutor(target_binder=…)`: 결속은 정지 대기 해제보다 먼저(거절이 지금 대기를 건드리지 않게), 실행 직전 `ClosedLoopController.use_operation(binding.operation)`(새 메서드), 결과 뒤 그 대상의 꼬리 훅. `act_main`은 컨트롤러를 `operation=None`으로 만들고 결속기에 맡긴다.
- **RPi5** `ActClient.execute(appliance_id=…)` 필수(없으면 보내지 않고 `ActLinkError`), 결과의 대상이 다르면 `ActLinkError`. `ActClientController.arm_execute_target`(한 번 쓰고 비움, 안 걸면 거절). `SimpleLayService._run_buttons`가 실행마다 건다 — `appliance_id` 없는 옛 요청은 규칙 해석과 같은 내장 갠트리 가전 `microwave`(`BUILTIN_GANTRY_APPLIANCE`)를 **명시해** 싣는다.
- **L2(M1)** 운영 경로에 실제 L2 판정 입력이 없다(`AcceptanceVerifier` 구현은 `MockAcceptanceVerifier`뿐, RPi4·RPi5 어디서도 `acceptance=`를 넘기지 않는다). 지어내지 않고 연결하지 않았다 — `act_main`에 주석으로 남김. 운영 경로에서 L2는 판정하지 않는다(아래 "L2 상태").
- **M2** `rpi/verifier/config.py`: `check_current_sensor_config`(`SensorConfigError`, 한국어) — gain 값, 채널 0~3, 감도 > 0, 영전류 전압이 단일 입력 측정 범위 `0 < V0 < FS` 안, 영점+누름 임계 전류 변화가 FS 미만, `valid_voltage_range`가 범위 안이고 영점을 품는지. `SIMPLELAY_CURRENT_ZERO_V`·`SIMPLELAY_CURRENT_ADC_GAIN`으로 덮는다. **`SIMPLELAY_SENSORS_ENABLED=true`일 때만** `act_main._build_verifier`가 장치를 열기 전에 검사한다 — 기본값 쌍은 거절된다. 기본(mock) 기동은 검사하지 않는다. 기본값 자체는 바꾸지 않았다(분압 회로 미확인, 실측 필요).
- 문서: `docs/protocol.md` execute 절.

## L2 상태(운영 경로)
RPi4 `act_main`의 폐루프는 버튼마다 L1(누름: 전류+소리 융합 또는 mock) 판정 뒤 바로 다음 단계로 가며, L2(가전이 입력을 받아들였나) 판정·재입력 정책은 실행되지 않는다. L2는 `ClosedLoopController` 계약과 `MockAcceptanceVerifier` 시험까지다. 결과 프레임에 L2 판정은 없다.

## 시험
- `rpi4/tests/test_target_binding.py`(9): 실제 배선(`_build_outlet` → `_build_executor`, 가짜 모듈 CT 2채널·릴레이 켬·L3 real). 가짜 모듈 자동 가동을 **늘 전자레인지 채널만** 돌게 바꾸고 — 세탁기 실행은 확인되지 않고 안전 정지, 대응 없는 인터폰은 누르기 전 `target_unbound`, `L3_NONE_TARGETS`면 null로 실행, 대응이 비면 세탁기는 `target_unbound`, 대상 없는 프레임은 `target_required`, 정지 확인은 세탁기 채널(전자레인지 꺼짐이어도 '켜짐')·인터폰은 '모름'. 대조: 전자레인지 대상은 확인됨.
- `rpi/tests/test_act_target.py`(6): 선에 대상, 대상 없으면 안 보냄, 다른 대상 결과 거절, 서비스→시뮬레이터 프레임의 대상(`induction`, 없으면 `microwave`), 안 건 컨트롤러 거절.
- `rpi/tests/test_sensor_config_check.py`(12): 기본 쌍 거절(한국어·실측 필요), 일관된 설정 통과, 모순 6종, env 덮기, `act_main` 센서 켬 거절, mock 기동 검사 없음.
- **수정 전 코드에서 실패 확인:** 대상 결속·RPi5 15건 중 14건 실패(세탁기 실행이 `operation_confirmed=True`, 인터폰이 실행·확인됨, 세탁기 정지 확인이 전자레인지 꺼짐으로 '꺼짐', 대상 키 없음 등). 통과 1건은 전자레인지 대조. M2 모듈은 검사 함수가 없어 수집 단계에서 실패.
- 기존 시험: execute 프레임·`ActClient.execute` 호출에 `appliance_id`를 넣고, 결과 비교에 `appliance_id`를 더했다. `test_sensor_window.py`는 gain 1(±4.096 V)로 둔다(기본 쌍은 이제 거절).

## 한계
- 실물 미검증. 새 RPi5 → 옛 RPi4는 옛 RPi4가 `appliance_id`를 무시해 전자레인지 채널로 판정한다 — 두 보드를 같은 판으로 배포한다(`act_info.execute_protocol`이 없으면 옛 RPi4). RPi5가 이를 막지는 않는다.
- L3 mock은 대상과 무관한 합성 전자레인지 파형이다(`mock` 표시).
- 원시 기록기(`SIMPLELAY_RECORDER_PATH`)의 전력 열은 여전히 전자레인지 채널이다(판정이 아니라 기록).
- 분압 회로가 있으면 ADC 전압 → 센서 전압 환산 비율이 필요한데 변환은 바꾸지 않았다 — `SIMPLELAY_CURRENT_ZERO_V`는 ADC 입력에서 본 값이고 감도는 그대로다. 회로 확인 뒤 정한다.

## 검증
- 백엔드+rpi4 `PYTHONUTF8=1 pytest -q rpi rpi4` **2,484 통과**(골든 없음, `bbcae0b` 위 작업 트리). `test_repo_guard.py` 5 통과. 폰·키오스크는 바꾸지 않아 실행하지 않았다.

## 교차 리뷰(`92876bd`) 수리 — 2026-10-07
- **결속 실패가 실행기 루프를 죽이던 것** `rpi4/act_main.py` `_build_target_binder`: 잔여 전류 설정 `TailConfig.from_env()`를 시작 때 한 번 읽는다(콘센트 모듈이 있을 때) — `SIMPLELAY_TAIL_OFF_MAX_W=abc` 같은 값은 첫 실행이 아니라 **시작에서 거절**(종전과 같음). `ActExecutor._on_execute`는 결속 중 예상 밖 예외를 잡아 `error {reason:"target_bind_failed"}`로 답하고 루프를 유지한다(전에는 `_dispatch → run_once → run()`으로 새어 실행기가 멈추고 응답도 없었다).
- **새 RPi5 + 옛 RPi4** `rpi/services/act_client.py`: 결과 프레임에 `appliance_id`가 없으면(옛 규약) `operation_confirmed`를 `None`(모름)으로 낮춘다 — 전자레인지 CT 확인이 세탁기 확인으로 쓰이지 않는다. 성공·재시도·버튼 결과 등 나머지는 그대로. 위 "한계"의 첫 줄(옛 RPi4가 전자레인지 채널로 판정)은 이제 RPi5에서 '모름'으로 받는다.
- **정지 대기 대상 불일치** `rpi4/models/act_messages.py`: `hold.appliance_id ≠ execute.appliance_id`면 버리지 않고 `ExecuteRefusedMsg(seq, "hold_target_mismatch", …)` → RPi5가 `error`를 받는다(누르지 않음).
- 시험 4건 추가(`test_target_binding.py` 3·`test_act_target.py` 1), 기존 hold 불일치 시험은 '실행 아님'으로 고쳤다. **수정 전 코드에서 4건 모두 실패 확인**(시작 거절 없음 `DID NOT RAISE`, 실행기 task가 `RuntimeError('boom')`으로 끝남, hold 불일치가 `None`, 옛 결과가 `operation_confirmed=True`).
- 검증: `PYTHONUTF8=1 pytest -q rpi rpi4` **2,497 통과**(골든 없음, `a2cea93` 위 작업 트리), `test_repo_guard.py` 통과.

### 후속(이번에 고치지 않은 리뷰 항목)
- **#3** `current_sensor` 측정 스레드: `join` 제한시간이 지나면 세대(generation)가 새어 옛 스레드가 남는다.
- **#5** `_reset_mid_run`이 준비 배너(재부팅) 때만 세워진다 — 누름 중 `MotionTimeout`·전송 오류에서는 세우지 않는다.
- **#6** 관찰 창(L3)이 XY 이동·자동 원점까지 포함하고, `max_window_s` 30 s와 이동 제한시간의 관계가 정리되지 않았다.
