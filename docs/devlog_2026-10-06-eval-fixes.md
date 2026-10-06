# 2026-10-06 평가 수리 — HEAD a0f25f7 두 평가의 결함

두 평가(교차 평가 A·B·C 항목 + Copilot 리뷰)가 짚은 결함을 고쳤다. **전부 모의·가짜 콘센트·컴파일 수준이다.**
실물 CT·릴레이·ADS1115·세탁기·전자레인지·마이크로 확인한 것은 없고, 새로 둔 기준값(쿨다운·기다림 상한·보고 주기)은
설계 초기값이라 **측정 필요**다. 수리마다 회귀 시험을 먼저 써서 수정 전 코드에서 실패하는 것을 확인했다(아래 "빨강 근거").

## 항목별

| 항목 | 수리 | 빨강 근거(수정 전 실패 줄) |
|---|---|---|
| A1 채널 대응 비면 모두 채널 0 | `require_outlet_channels`: 콘센트 전력을 읽는 가전(L3 real·기록기·실물 모션 = 전자레인지, `DONE_WATCH`의 outlet 가전)이 둘 이상인데 `SIMPLELAY_OUTLET_CHANNELS`가 비면 포트를 열기 전에 **기동 거절** | `test_empty_mapping_with_two_done_watch_appliances_refuses_start` — `Failed: DID NOT RAISE RuntimeError` (L3+세탁기 조합도 같음) |
| A2 릴레이 채널 ≠ 전자레인지 채널·없는 채널 | `outlet_module_channel_problem`: 시작 때 어긋나면 거절, 실행 중 모듈이 다르게 알리면 execute를 `outlet_offline`으로 거절. 가짜 모듈은 릴레이 채널을 대응에서 베끼지 않음(`SIMPLELAY_FAKE_OUTLET_RELAY_CH` 기본 0, `_CHANNELS`) | `test_fake_relay_channel_is_not_derived_from_the_mapping`·`test_mapped_channel_missing_on_the_module_refuses_start` — `DID NOT RAISE` |
| A3 ADS1115 돌려 읽기 | 변환 중(OS=0)이면 새 변환을 시작하지 않고 틱을 건너뜀(최대 3틱 뒤 판독 실패), 값은 설정 레지스터 MUX로 찾은 **실제 변환 채널** 창에. 기본 보고 주기를 CT 둘 이상이면 5 Hz로(채널당 50점 = 호스트 하한 20의 2.5배), `config.h`가 2배 미만이면 컴파일 오류. 세 env 빌드 SUCCESS, 굽지 않음 | `test_ads1115_round_robin_waits_for_conversion_and_tags_by_converted_mux` — `ValueError: substring not found`; `test_default_report_rate_leaves_margin_over_the_host_minimum` — `assert 'CT_DEFAULT_SAMPLES_PER_CHANNEL < 2 * …' in …` |
| A4 모듈 재부팅으로 꺼진 릴레이 | 자동으로 켜지 않는다. 켜 둔 릴레이가 재부팅(ready·status relay off)으로 꺼지면 RPi4가 `source:"outlet_reboot"`로 걸리고 "콘센트 모듈이 다시 켜져 전원이 꺼져 있어요 — 확인 후 켜 주세요"로 실행 거절. 같은 사람 확인(`POST /stop/ack`)이 버튼 확인 뒤 `relay_on` | `test_module_reboot_with_relay_expected_on_latches_until_human_ack` — `AssertionError: condition not met in time` |
| B1 입력 하나뿐인 끝을 확인으로 침 | `done_confirmed`만 통과. 하나뿐이면 단계 `status:"probable"`, "끝난 것 같아요 — 확인해 주세요 (… 감지 — 다음 단계는 보내지 않았어요)"로 루틴을 멈추고 알림함에 남김(보수적 선택) | `test_single_input_cycle_end_stops_the_routine_with_please_check` — `assert 2 == 1` (뒤 단계가 나감) |
| B2 쿨다운 900 s 하나 | `DoneFusionConfig.for_appliance` — `SIMPLELAY_DONE_<가전>_COOLDOWN_S` → 공통 → 전자레인지 60 s·그 밖 900 s | `test_second_microwave_end_within_fifteen_minutes_is_not_dropped` — `AttributeError: … has no attribute 'for_appliance'` (기존 설정으로는 5분 뒤 두 번째 끝이 `ignored`) |
| B3 after_done 두 번·자기 제외 없음·목록 어긋남 | 엔진이 가전마다 사이클(실행을 낸 루틴, 이미 깼나)을 기억해 끝 알림에서 한 번만·자기 루틴 제외. RPi4 `act_info.done_watch`를 받아 `DoneSensorSet`이 RPi5 env·가전 목록과 대조(어긋나면 log.error, RPi4 목록을 따름) | `test_after_done_fires_once_per_cycle…` — `assert 2 == 1`; `test_cycle_end_does_not_wake_the_routine_that_ran…` — `['rt-…', 'rt-…'] == ['rt-…']`; `ImportError: cannot import name 'DoneSensorSet'` |
| B3 추가(ID 공간) | RPi5 `SIMPLELAY_ROUTINE_DONE_SENSORS`·루틴은 RPi5 가전 목록 ID(내장 = `microwave`), RPi4 `DONE_WATCH`는 설정한 이름 그대로 프레임에 싣는다 — **같은 공간이어야 하는데 어긋날 수 있다**(예: `home_mw`, 사용자 가전 자동 ID). handshake가 RPi4 이름을 가전 목록(`list_all`)과 대조해 "RPi5 가전 목록에 없어요 — 어떤 루틴에도 닿지 않아요"를 알린다 | `test_rpi4_done_watch_list_wins_and_mismatches_are_reported` — `ImportError` |
| B4 세탁기는 L3 시작 확인을 못 받음 | 끝 센서가 있는 가전이면 실행 성공만으로 끝 스트림을 기다린다(L3 무관). 모의 실행은 종전처럼 시연 통과 | `test_cycle_end_wait_does_not_need_l3_start_confirmation` — `UNCONFIRMED is SUCCEEDED` 실패 |
| B5 전체 정지가 기다리는 루틴을 안 멈춤 | `RoutineRunner.stop_all`(`POST /stop`이 부름), 기다림을 0.5 s씩 끊어 비상정지 확인. 시작 뒤 걸림 횟수(`estop_trips`)가 늘었으면 해제 뒤에도 멈춤 | `test_global_stop_cancels_a_waiting_routine` — `AttributeError: 'RoutineRunner' object has no attribute 'stop_all'`; `test_estop_during_wait…` — `SUCCEEDED is STOPPED` 실패 |
| C1 RPi5 재시작 뒤 걸림 상태 None | RPi5 `hello` → RPi4 `act_info` + `estop_state{announce}`; RPi4는 켜질 때도 스스로 보냄. 모르는 동안(`known:false`) 내장 가전 실행 412 "비상정지 상태를 확인하는 중이에요", 2 s 간격으로 hello 재전송 | `test_unknown_estop_state_refuses_execution_as_checking` — `assert 200 == 412`; `test_act_client_says_hello…` — `TypeError: … unexpected keyword argument 'on_act_info'` |
| C2 해제 확인이 읽기 루프를 막음 | `estop_ack`를 task로(`_start_estop_ack`, `wait_ack`) | `test_abort_is_processed_while_estop_ack_waits_for_the_outlet` — `TimeoutError` (run_once 0.5 s) |
| Copilot#2 루프가 닫힌 뒤 비상정지 | `emergency_stop_sync`: 그 스레드에서 걸림 + `request_stop` + 정지 대기 `drive_stop` | `test_estop_after_the_event_loop_closed…` — `assert 0 == 1` (정지 요청 0회) |
| Copilot#3 루틴 전달 예외를 삼킴 | 기록을 먼저 남기고, 실패는 가전·이벤트를 붙여 log.error + 알림함 "세탁 끝 알림을 보내지 못했어요"(`appliance_done_undelivered`) | `test_routine_dispatch_failure_keeps_the_record_and_leaves_a_notice` — `assert ([])` (알림 없음) |
| Copilot#4 /ambient 순간 실패가 안내를 지움 | 실패면 마지막 안내 유지, 연속 실패가 10분(조회 주기 × 횟수)이면 접음. 성공한 빈 응답은 그대로 반영 | 위젯 시험 `안내 한 줄 조회가 잠깐 실패해도…` — `kiosk_phase_test.dart line 1106` 기대 실패 |
| Copilot#5 1200 s 하나·호출자 막힘 | 가전별 상한(`SIMPLELAY_ROUTINE_DONE_TIMEOUT_<가전>_S` → 공통 → 전자레인지 900 s·세탁기 3 h → 1200 s). 기다림은 배경 스레드라 새 명령을 막지 않음(시험으로 고정, 다음 장치 단계는 그 명령이 끝나길 `idle_timeout`만큼 기다림) | `test_wait_timeout_is_per_appliance` — `assert (… 30 s 경과) < 3.0`; `ImportError: routine_done_timeouts_from_env` |
| Deploy | `run_act.sh`: env 파일의 `SIMPLELAY_OUTLET_PORT`·`SIMPLELAY_MOTION_PORT`(/dev/…)와 `SIMPLELAY_ACT_DEVICES`(예 `/dev/snd`)를 `--device`로, 없는 장치면 세우지 않음. `DATA_DIR`·`SETTLE_S` 덮어쓰기. 이미지에 `sounddevice` + `libportaudio2`(Dockerfile·build_on_device 둘 다). LF·POSIX sh 유지 | `test_image_has_the_microphone_runtime` — `'"sounddevice' in …` 실패; `test_outlet_motion_and_sound_devices_are_passed_through` — `mkdir: cannot create directory '/mnt'`(경로 고정)·장치 미전달 |
| UART 리허설 | RPi5 `SIMPLELAY_UART_REHEARSAL=1` + RPi4 `act_info.rehearsal`(모션 mock·콘센트 fake 또는 없음)일 때만 `rehearsal` 프레임으로 주입. 가짜 모듈 버튼은 실물과 같은 estop 경로. 응답 `injected_in:"rpi4_uart"`·"(시연 주입…)". 실물 RPi4면 409, 스위치 없으면 404 | `test_uart_rehearsal_*` — `AttributeError: 'ActClientController' object has no attribute 'rehearsal_status'`(종전 404) |

## 고른 것과 남긴 것

- B1은 보수적 선택(멈춤 + 확인 요청)이다. 사람이 확인하고 이어서 하는 버튼은 없다 — 루틴을 다시 실행해야 한다.
- A4는 새 API(`relay_on`) 대신 기존 해제 확인 길을 썼다. 비상정지로 꺼진 릴레이는 종전처럼 해제해도 켜지 않는다.
- C1의 `hello`는 운영 경로(UART 공장·시뮬레이터)만 보낸다(`ActClient(hello=True)`) — 줄 단위 흉내 시험이 첫 줄을 execute로
  기대해서다.
- B3 ID 공간: 자동으로 이름을 바꿔 잇지 않는다(추측 금지). 어긋나면 알리고 RPi4 목록을 따를 뿐이다.
- 문서: `docs/protocol.md`만 고쳤다(hello·act_info·rehearsal·재부팅 걸림·채널 확인·쿨다운·기다림 규칙). 다른 문서는 다른 작업이 맡는다.
- RPi4 직결 ADS1115(`SIMPLELAY_SENSORS_ENABLED`, adafruit 라이브러리)는 이미지에 넣지 않았다 — 전력은 콘센트 모듈 경로다.

## 검증(이 작업 공간, 2026-10-06)

- 백엔드 rpi + rpi4: **2,415 통과**(직전 2,377 + 새 시험 38). B1로 뜻이 바뀐 기존 시험 2건(`test_routine_wait_done`)은
  두 입력 끝으로 고쳤고, `estop_ack`가 따로 돌게 된 기존 시험 2건에 `wait_ack`, 연결 알림을 실행 흐름 비교에서 빼는 시험 2건,
  채널 대응 시험 2건(가짜 릴레이 채널 env, 거절 시점이 `_build_outlet`으로 앞당겨짐)을 맞췄다. 저장소 가드 통과.
- 키오스크: `flutter analyze` info 1(기존), 테스트 242 통과(골든 제외, +1), 골든 41 통과. `pubspec.lock` 드리프트는 되돌림.
- 펌웨어: `firmware-outlet` 세 env(firebeetle32·_adc·_1ct) 빌드 SUCCESS. 굽지 않음.
