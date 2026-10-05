# 2026-10-06 세탁 끝 판정 — CT 전력 하강 + 종료음 융합 (결정 D2, 갭 S8·M1)

**검증 수준: 가짜 콘센트 모듈(`rpi/tools/fake_outlet.py`)·합성 음·pytest까지. 실물 세탁기·CT·마이크 0건. 기준값은 전부 측정 필요.**

## 사용자 결정 (10/6 확정)

- 세탁 완료 = 콘센트 모듈 **CT 전력 하강(1순위)** + **종료음(마이크, 교차 확인)**.
- 둘이 시간 창 안에서 맞을 때만 "세탁이 끝났어요". 하나뿐이면 "세탁이 끝난 것 같아요 — 확인해 주세요"(끝났다고 단정하지 않는다).
- 세탁기는 **CT로 재기만** 하고 콘센트 릴레이로 끊지 않는다.
- 무대 세탁기는 돌리지 않으므로 리허설 주입이 필요하고, 주입은 주입이라고 표시한다.

## 한 것

| 부분 | 파일 | 내용 |
|---|---|---|
| CT 사이클 끝 | `rpi/verifier/cycle_end.py` | 운전(≥ `run_min_w`, `min_run_s` 이상) 뒤 대기(≤ `standby_max_w`)에 `settle_s` 머물면 끝. 더 짧은 하강(담금·헹굼 사이)은 `dips`로만 센다. 끊김(`max_gap_s`·`note_gap`)은 대기 시간으로 세지 않는다. 순수 함수 `detect_cycle_ends` + 스트리밍 `CycleEndTracker` |
| 종료음 | `rpi/verifier/end_beep.py` | 위험 소리 DSP 재사용(`_band_energy_ratio`·`_periodicity_score`). 다른 점은 패턴 끝 — 몇 번 울리고 `silence_after_s` 조용하면 그 묶음을 판정, `max_beeps` 넘으면(계속 반복 = 경보) 종료음 아님. 별도 프로필 `EndBeepConfig` |
| 융합 | `rpi/verifier/done_fusion.py` | `ApplianceDoneFusion`: `done_confirmed`·`done_power_only`·`done_beep_only`, 먼저 온 입력은 `wait_s` 동안 짝을 기다림, 쿨다운 안의 늦은 입력은 `ignored`에 기록. 출처 real/mock/injected — 하나라도 mock이면 mock |
| RPi4 배선 | `rpi4/services/appliance_done_watch.py`, `act_executor.py`, `danger_sound_monitor.py`, `act_main.py` | `SIMPLELAY_DONE_WATCH=washer:outlet,mic`. 전력 스레드(`PowerCycleFeeder`, 릴레이 명령 없음) + 마이크 프레임은 위험 소리 루프가 나눠 줌(`frame_listeners`, 스트림 하나). `appliance_done` 자체발신 프레임 |
| RPi5 | `rpi/services/appliance_done.py`, `act_client.py`, `deps.py`, `routines/engine.py` | 프레임 검증(상태·입력 불일치는 버림) → 기록(`get_appliance_done_log`) → `on_appliance_done`: 같은 가전 `after_done`, 같은 이름 `event`(`wash_complete`). 확신 없으면 루틴의 안내 문장을 읽지 않는다. 주입 "(시연 주입)", 모의 "(모의 입력)" |
| 주입(S8) | `rpi/api/router.py` `POST /demo/appliance-done` | 모의·시뮬레이터만(UART 404). 시뮬레이터면 모의 RPi4 실행기가 프레임을 보냄 |
| 문서 | `docs/protocol.md`, 갭 문서, v3 ④, 가산점 대장 | D2 확정·S8/M1 닫음(모의 수준), ④ 절차를 주입으로 |

키오스크·폰은 새 화면 없이 기존 `routine_notice` → 알림함·`/ambient` 안내 한 줄로 받는다.

## 시험 (빨강 → 초록)

새 시험 7개 파일을 먼저 쓰고 모듈이 없어 실패하는 것을 본 뒤 구현했다. 핵심 세 군데는 변형으로 다시 확인했다:
확신 없을 때 안내 문장 생략을 되돌리면 2건, 융합 창 비교를 없애면 1건, `settle_s` 대기를 없애면 사이클 시험 7건이 실패.

- `rpi/tests/test_cycle_end.py` 11 · `test_end_beep.py` 9 · `test_done_fusion.py` 10 · `test_appliance_done_routine.py` 14
- `rpi4/tests/test_appliance_done_watch.py` 8(가짜 콘센트 모듈 + 합성 음 → RPi4 프레임 → RPi5 루틴 안내 끝까지, 릴레이 명령 0건 확인)
- `rpi/tests/test_controller_factory.py` +1(UART 실행기에 완료 콜백 전달)
- 전체 백엔드 `rpi rpi4` **2,344 통과**(직전 2,291 + 53), 저장소 가드 5 통과(새 파일 포함)

## 측정 필요 (기본값은 추정)

| 값 | 환경 변수 | 기본 |
|---|---|---|
| 운전 하한 / 최소 운전 시간 | `SIMPLELAY_CYCLE_RUN_MIN_W` / `_MIN_RUN_S` | 100 W / 300 s |
| 대기 상한 / 대기 유지(= 최소 하강 지속) | `SIMPLELAY_CYCLE_STANDBY_MAX_W` / `_SETTLE_S` | 15 W / 180 s |
| 종료음 대역·임계 | `SIMPLELAY_BEEP_FREQ_LOW_HZ`·`_HIGH_HZ`·`_BAND_THRESHOLD` | 1800~4200 Hz, 0.35 |
| 삐 개수·간격·조용함·규칙성 | `SIMPLELAY_BEEP_MIN_COUNT`·`_MAX_COUNT`·`_MIN_PERIOD_S`·`_MAX_PERIOD_S`·`_SILENCE_S`·`_MAX_REL_STDDEV` | 3~12, 0.2~1.5 s, 3 s, 0.25 |
| 융합 창·기다림·쿨다운 | `SIMPLELAY_DONE_FUSION_WINDOW_S`·`_WAIT_S`·`SIMPLELAY_DONE_COOLDOWN_S` | 120 s, max(300, settle+창), 900 s |

담금 정지가 `settle_s`보다 길면 끝으로 잘못 본다. 종료음이 멜로디면 규칙성 확인을 넓히거나 프로필을 다시 잡는다.

## HW 팀원에게 받을 것

- 세탁기 모델명과 **종료음 녹음**(마이크 위치 그대로, 세탁기 운전 소음 포함 1회 이상) — 단음 반복인지 멜로디인지, 주파수.
- **마이크 위치** — 세탁기 조작부 스피커 쪽 거리(추정 1 m 안), RPi4에 붙는 마이크 하나를 위험 소리와 같이 쓴다.
- **표준 코스 1회 전력 기록**(CT, 10 Hz) — 운전·담금·탈수 구간 W, 가장 긴 정지 구간 길이, 끝난 뒤 대기 W.
- 배선: 세탁기는 **CT만 통과**(릴레이 뒤에 두지 않음). 콘센트 모듈 CT가 하나라 전자레인지 L3와 세탁기를 **동시에** 잴 수 없다 — 무대 배치를 정해야 한다.

## 남은 것

- M2: `wait_until_done`(전자레인지 끝)에는 아직 안 이었다.
- 부분 실물(UART)에서는 주입이 404 — RPi4 쪽 리허설 명령은 없다.
- 서버 HTTP 리허설(v3 §3-4 ④ 새 행)은 pytest로만 확인, 보드 미배포.
