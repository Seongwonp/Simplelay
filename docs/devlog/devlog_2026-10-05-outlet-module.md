# 2026-10-05 — ESP32 콘센트 모듈 경로(CT → RPi4, 버튼·릴레이 비상정지, 잔여 전류 꼬리)

**검증 수준: 컴파일 + 가짜 출력(메모리 파이프) 시험까지.** CT·ADS1115·릴레이·비상정지 버튼·가전을 붙여
돌려 본 적이 없다. 펌웨어는 플래시하지 않았다. 아래 "확인됨"은 전부 이 수준이다.

근거 결정: [하드웨어 방향 확정](../하드웨어-방향-확정-2026-09-30.md) §1·§2-3·§2-4, [본선 실행계획](../본선-실행계획-2026-09-30.md)
"CT 전력값 경로: ESP32 콘센트 모듈 → RPi4 직접", "물리 비상정지: 콘센트 모듈에 버튼과 가전 전원 차단 릴레이", 피드백 ③.

## 1. 만든 것

| 위치 | 내용 |
|---|---|
| `firmware-outlet/` | 새 PlatformIO 프로젝트(ESP32 FireBeetle, firmware-motion과 같은 고정 플랫폼). CT 샘플링(ADS1115 차동 기본 / ESP32 ADC 대안, 빌드 플래그) → 창마다 실효값 → 전력 **추정** `power` 이벤트(기본 10 Hz, `rate`로 1~20). `ready`·`ping`·`status`·`relay_on`·`relay_off`·`estop_reset`. 비상정지 버튼은 샘플링 태스크가 매 틱 보고 **그 자리에서** 릴레이를 연다(호스트 무관) → `estop` 이벤트. 릴레이 부팅 기본 꺼짐. MCU 태스크 워치독. `protocol_table.json`, README(배선 가정표) |
| `rpi/verifier/outlet.py` | `OutletLink`(읽기 스레드·응답 짝짓기·heartbeat·이벤트 듣기) + `SerialPowerSensor`(`PowerSensor` 구현, 소비자별 커서, 밀리면 최신으로 건너뜀, **끊기면 `PowerSensorStale` — 0 W를 지어내지 않음**). 모듈 `t_ms`를 호스트 단조 시각에 맞춤(재시작 때 다시 맞춤) |
| `rpi/tools/fake_outlet.py` | 가짜 콘센트 모듈(규약·릴레이·비상정지 래치·합성 가전 파형). 시험과 리허설(`SIMPLELAY_OUTLET_PORT=fake`) |
| `rpi/controller/power_operation.py` | `OutletOperationVerifier`. `SIMPLELAY_L3_MODE=real`은 `SIMPLELAY_OUTLET_PORT`가 있을 때만 이것으로 배선되고, 없으면 **종전처럼 거절**(문구만 콘센트 모듈 설정으로 바꿈). 가짜 출력이면 결과 `mock=True` + "모의 콘센트(가짜 출력) —" 접두. `PowerOperationVerifier.last_verdict`(사용 전 기준선)를 남김 |
| `rpi/verifier/power_tail.py` | 잔여 전류 꼬리(피드백 ③). 완료 판정(≤ `off_max_w`가 `off_confirm_s` 유지) 뒤 기준선 띠로 `settle_s` 머무를 때까지: `tail_s`·꼬리 평균/최대·사용 전/후 기준선, 상태 `returned`/`timeout`/`no_finish`/`no_baseline`/`stale`/`stopped`. 기준 전부 `SIMPLELAY_TAIL_*`, **측정 필요** |
| `rpi4/services/outlet_watch.py` | `OutletTailHook`(L3 확인 뒤 배경에서 꼬리를 재 `progress {phase:"power_tail"}` + 기록기 행), `OutletRunProbe`(정지 대기의 켜짐/꺼짐 — 끊기면 None) |
| `rpi4/services/act_executor.py` | `after_result` 훅, `handle_outlet_estop`(실행 중이면 abort와 같은 협조적 정지 + 모션 stop 즉시, 대기 중이면 구동부 정지·정지 버튼 누르지 않음, RPi5에 `alert kind=outlet_estop`) |
| `rpi4/act_main.py` | `SIMPLELAY_OUTLET_PORT`/`_BAUD`(fake 허용), `SIMPLELAY_OUTLET_RELAY_ON_START`(기본 끔), 기록기 전력 입력을 콘센트 모듈로, 실제 모션 정지 대기 probe를 콘센트 전력으로, estop 이벤트 → 이벤트 루프 → 실행기 |
| `rpi/verifier/recorder.py` | CSV 열 뒤에 `tail_status, tail_s, tail_mean_w, tail_max_w, pre_baseline_w, post_baseline_w` 추가, `record_power_tail()`, `LiveRecorder(power_sensor=…)` |
| `rpi/services/act_client.py` | RPi5 `ActClient.last_power_tail`(마지막 꼬리 보고, 새 실행 때 비움) |
| `docs/protocol.md` | "콘센트 모듈 링크" 절 |

## 2. 설계 판단

- **릴레이 부팅 기본 꺼짐(fail-safe).** 비상정지 장치가 리셋으로 '정지 해제'되지 않게. 대가는 모듈 재부팅 = 가전 꺼짐.
  RPi4가 시작 때 켤지는 사람이 `SIMPLELAY_OUTLET_RELAY_ON_START=1`로 고른다. 호스트 침묵 시 릴레이 열기는 기본 끔(빌드 플래그).
- **버튼 차단은 MCU 안에서만 끝난다.** 호스트 `estop` 처리는 구동부 정지·알림일 뿐, 가전 전원 차단을 호스트에 의존하지 않는다.
- **끊김은 '데이터 없음'.** 센서가 0 W나 마지막 값을 반복하면 L3가 '전력이 오르지 않음'으로 잘못 말한다. 예외로 올려
  컨트롤러의 기존 '전력 센서를 읽지 못함' 안전 정지 경로를 탄다.
- **꼬리는 결과 프레임이 아니라 뒤따르는 progress 프레임.** L3는 '시작 확인'에서 결과를 보내고, 꼬리는 가전이 끝난 뒤에야
  생긴다. 결과를 수십 초 붙잡지 않으려고 `phase:"power_tail"`로 따로 보낸다. 실행 이력·이력 CSV(`history_csv`)에는 아직
  잇지 않았다 — 이력 행은 결과 때 쓰여 꼬리가 올 때는 이미 저장돼 있다(이을 자리는 RPi5 `last_power_tail`).
- 12 W 같은 잔여 전력은 `off_max_w`(30 W) 이하라 완료 판정 유지 구간에 먼저 들어간다. `tail_s`는 그 **뒤**부터 띠 복귀까지다
  (정의는 `power_tail.py` 머리말). 기준을 바꾸면 숫자 의미가 바뀌므로 실측 후 한 번 정한다.

## 3. 확인한 것

- 펌웨어 컴파일: 아래 §4.
- 백엔드: 아래 §4 숫자. 새 시험 `rpi/tests/test_outlet_protocol.py`(표 ↔ 가짜 출력 ↔ 펌웨어 소스 이름, 해석, 시각 맞춤,
  끊김, 밀림, 릴레이·래치), `rpi/tests/test_power_tail.py`(꼬리 계산·기록기 열), `rpi4/tests/test_outlet_l3.py`(L3 real 배선·
  가짜 출력 확인/미확인·릴레이 꺼짐·끊김 → 판정 불가, estop → 정지 경로·알림, 꼬리 프레임, RPi5 ActClient까지).
- 실패 확인: ① 옛 `operation_verifier_from_env`는 콘센트 링크를 받을 수 없음(`TypeError`/거절) 확인 후 배선.
  ② 센서가 끊김에 0 W를 돌려주는 변형 → `test_stale_stream_raises_instead_of_returning_zero`·
  `test_l3_stale_stream_stops_as_unreadable_sensor` 실패 확인. ③ estop 처리에서 `request_stop`을 빼는 변형 →
  `test_outlet_estop_event_stops_the_running_sequence_and_alerts` 실패 확인.

## 4. 숫자

- 펌웨어(PlatformIO 6.x, 저장소 밖 venv `C:\pio-venv`, 코어 `C:\pio`, 빌드 `C:\pio-build\firmware-outlet`):
  `firebeetle32`(ADS1115) **SUCCESS** — RAM 5.7%(30,564 B)·Flash 22.9%(299,768 B).
  `firebeetle32_adc` **SUCCESS** — RAM 5.8%·Flash 23.5%. 우리 소스의 경고는 의도한 `PLACEHOLDER` `#warning` 하나뿐.
  처음 사용자 폴더 코어(`%USERPROFILE%\.platformio`)에서는 프레임워크 압축 해제가 Windows 경로 길이 제한으로 실패했다 —
  짧은 코어 경로로 해결(시스템 설정은 바꾸지 않음). **플래시하지 않았다.**
- 백엔드(`pytest rpi rpi4`, 다른 작업이 진행 중인 `rpi/tests/test_motion_z_mode.py` 제외): 시작 전 2,190 → **2,232 통과**(+42 새 시험).
  `rpi/tests/test_repo_guard.py` 5 통과(새 파일은 아직 추적 전이라 금지어를 따로 grep — 없음).

## 5. HW 팀원에게 받을 것

1. CT 실제 모델(전압 출력형 SCT-013-030인지, 전류 출력형 + 부담 저항인지)과 물리는 자리(AC 라인 스플리터 L 한 가닥).
2. ADS1115 사용 여부·주소·바이어스 회로(차동 AIN0-AIN1 가정) 또는 ESP32 ADC 직결 여부.
3. 릴레이 모듈 극성(활성 HIGH/LOW)·접점 정격·코일 전원, 재부팅 중(High-Z) 열림 확인.
4. 비상정지 버튼 접점(NC 가정)·핀.
5. 핀 배치(가정: SDA 21, SCL 22, CT ADC 36, 릴레이 26, 버튼 27).
6. ESP32 보유 수량(모션도 ESP32로 가면 두 개).
7. 220 V 배선 안전 점검 절차(절연 케이스).

실측으로 정할 것(측정 필요): 무부하 잡음 → `CT_NOISE_FLOOR_A`, 정격 부하 비교 → `CT_CAL_GAIN`, 현장 전압·주파수,
버튼 → 릴레이 차단 지연, USB 시리얼 지연(`t_ms` 맞춤 오차), `SIMPLELAY_OUTLET_STALE_MS`, `SIMPLELAY_TAIL_*` 전부.

## 6. 발표에서

- ○ "ESP32 콘센트 모듈 펌웨어와 RPi4 수신·판정 배선을 만들었고, 가짜 출력으로 규약과 정지 경로를 시험했습니다.
  실물 CT 보정과 릴레이 시험은 부품 배선 뒤입니다."
- ✕ "콘센트 모듈로 소비 전력을 측정합니다", "물리 비상정지가 동작합니다", "잔여 전류를 기록합니다"(실측 없음).

## 교차 리뷰 뒤 수리 (2026-10-05 밤)

Copilot CLI와 별도 검토 에이전트가 따로 리뷰했다. 고친 것:

| 항목 | 내용 | red 근거 |
|---|---|---|
| H1 | 콘센트 비상정지가 RPi4에 걸리지 않아 다음 `execute`가 그대로 움직였다 → RPi4 `estop_latched`, 사람 확인(`POST /stop/ack` → UART `estop_ack`) 전까지 `execute`·`verify_pass` 거절, 버튼이 눌린 채면 해제 거부. `/status.estop_latched`·준비 상태 "비상정지가 걸려 있어요"·실행 412 | 수정 전 쉬는 중 비상정지 뒤 실행이 성공 |
| H2 | ESP32 래치가 RAM에만 있어 재부팅·DTR로 풀렸다 → RTC·NVS에 보존, 부팅 시 릴레이 꺼짐·`relay_on` 거절, `ready`에 보고 | 컴파일만 |
| M1 | 샘플이 적은 측정 창이 0 W를 지어냈다 → 펌웨어는 창을 건너뛰고, 호스트는 `n`·`err` 기준으로 버린다(기준값 측정 필요) | n=1·0 W 줄이 받아들여짐 |
| M2 | 콘센트가 조용해져도 L3 밖에선 몰랐다 → 마지막 수신 3초 넘으면 `outlet_offline`로 실행 거절, 포트 재연결, `status` 2초 주기 확인 | — |
| L1 | 같은 줄 반복을 MCU 재시작으로 보고 신선도를 갱신했다 → `ready`나 `seq` 리셋 때만 기준을 다시 잡는다 | 중복 30줄이 신선한 값으로 남음 |
| L6 | 솔레노이드 최대 켬 시간·냉각 대기를 호스트가 몰랐다 → `z_on_max_ms`로 사전 거절, `z_cooldown`은 `retry_ms`만큼 기다려 한 번 재시도, 움직이지 않은 `soft_limit`은 경보·재원점 대신 단순 거절 | `soft_limit`이 MotionAlarm으로 감 |

남은 것: 폰·키오스크에 비상정지 해제 버튼이 아직 없다(준비 상태 문구로만 보인다). 트립 직후 몇 ms 안에 전원이 끊기면 NVS 기록 전이라 래치가 사라질 수 있다(버튼이 계속 눌려 있으면 부팅 때 다시 걸린다). 실물 미검증.
