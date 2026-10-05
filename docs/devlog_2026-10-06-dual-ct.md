# 2026-10-06 CT 두 채널 · 갭 M2(사이클 끝 기다림) · S6(인터폰) · S9(페이싱)

**검증 수준: 펌웨어 컴파일(3개 env) + 가짜 콘센트 모듈(`rpi/tools/fake_outlet.py`)·합성 기록·pytest·Flutter 위젯 시험까지.
실물 CT·ADS1115·세탁기·전자레인지 가열 0건. 채널별 보정·사이클 기준은 전부 측정 필요.** 커밋·배포 전이다.

## 사용자 결정 (10/6)

- **두 번째 CT**를 구해 전자레인지와 세탁기를 **동시에** 잰다. 콘센트 모듈은 하나, 릴레이도 하나(전자레인지).
- 세탁기는 릴레이로 끊지 않는다(앞선 D2 결정 그대로) → **세탁기 플러그는 릴레이를 거치지 않게 배선한다.**

## 한 것

| 갭 | 파일 | 내용 |
|---|---|---|
| CT 두 채널(펌웨어) | `firmware-outlet/include/config.h`, `src/ct.*`, `src/main.cpp`, `src/protocol.cpp`, `platformio.ini` | `OUTLET_CT_CHANNELS`(기본 2, ADS1115 최대 4·내장 ADC 최대 2), `OUTLET_RELAY_CH 0`. ADS1115는 단발 변환 돌려 읽기(OS 비트로 끝남 확인, `SAMPLE_HZ` 800 → 500, 2채널이면 채널당 250 Hz). 채널별 보정 표 `CT_*_CH`(측정 필요), MUX 표 `ADS1115_MUX_CH`(ch0 AIN0-AIN1·ch1 AIN2-AIN3, 겹침은 `static_assert`). 채널별 창·우편함·`seq`. `power`에 `ch`, `ready`·`status`에 `channels`·`relay_ch`. `rate`는 채널당 창 샘플 < 20이면 `bad_args`. 새 env `firebeetle32_1ct` |
| CT 두 채널(호스트) | `rpi/verifier/outlet.py` | 채널별 링 버퍼·시각 맞춤·`seq`·신선도(`_ChannelState`). `ch` 없음 = 0(호환), 잘못된 `ch`는 버림. `OutletLink.channel(ch)` → `OutletChannel` 보기(소비자에게 링크 대신). `SIMPLELAY_OUTLET_CHANNELS` 해석(`parse_outlet_channels`: 형식·범위·한 가전 두 채널·한 채널 두 가전 거절) |
| 가짜 모듈 | `rpi/tools/fake_outlet.py` | `channels`·`relay_channel`, 릴레이는 그 채널만 0 W, `set_channel_watts`, `muted_channels`, `start_run(ch=…)` |
| RPi4 배선 | `rpi4/act_main.py`, `rpi4/services/appliance_done_watch.py` | L3·꼬리·정지 확인·기록기 = `microwave` 채널. `SIMPLELAY_DONE_WATCH`가 `;`로 가전 여럿(`washer:outlet,mic;microwave:outlet`), 가전마다 자기 채널, `mic`은 한 가전만. 가짜 모듈은 대응에 맞춰 채널 수·릴레이 채널을 정한다. 모듈 `relay_ch`가 microwave 채널과 다르면 오류 로그 |
| 가전별 끝 | `rpi/verifier/done_fusion.py`, `cycle_end.py` | `done_event_for`: 세탁기 `wash_complete`·전자레인지 `heat_complete`(전자레인지 끝이 '세탁 끝 알림'을 깨우지 않게). `CycleEndConfig.for_appliance`: `SIMPLELAY_CYCLE_<가전>_<항목>` → 공통 → 가전 초기값(전자레인지 `min_run_s` 10·`settle_s` 10, 측정 필요). 주입(`/demo/appliance-done`)도 이벤트를 비우면 가전 기본 |
| **M2** | `rpi/routines/runner.py`, `engine.py`, `wiring.py`, `rpi/services/appliance_done.py` | 끝 센서가 있는 가전(`SIMPLELAY_ROUTINE_DONE_SENSORS`)은 L3 뒤 `appliance_done`을 `SIMPLELAY_ROUTINE_DONE_TIMEOUT_S`(기본 1200)까지 기다림. 구간 제출 전 `ApplianceDoneLog.mark()` 뒤의 끝만 셈, 정지 요청이면 멈춤. 센서 없으면 "시작만 확인 — 끝남 판정 센서 없음", 모의는 "시연: 모의 실행 — 시작만 확인 …". 단계에 `basis`(cycle_end·start_only·mock). 끝 센서 가전의 `after_done`은 L3가 아니라 끝에서 한 번 |
| **S6** | 서버 `appliance_registry.py`, 폰 `models/appliance.dart`·`widgets/appliance_portrait.dart`, 키오스크 `models/appliance.dart` | `intercom`(인터폰, `Icons.doorbell`, 폰 실루엣) |
| **S9** | `deploy/run_backend.sh`, 런북 §3-2·§5-0·§8 | `-e SIMPLELAY_DEMO_PACING=1` 삭제 → env 파일을 따르고 없으면 꺼짐. 기동 출력 `== 시연 페이싱: on/off ==`. LF·POSIX sh 유지 |
| 문서 | `docs/protocol.md`, `firmware-outlet/README.md`, `protocol_table.json`, 갭 문서 | S6·S9·S10·M2 닫음, H6 갱신 |

## 시험 (빨강 → 초록)

새 시험을 먼저 쓰고 실패(가져오기 실패·단언 실패)를 본 뒤 구현했다: `rpi/tests/test_outlet_channels.py`(15),
`rpi4/tests/test_outlet_channels_wiring.py`(5), `rpi/tests/test_routine_wait_done.py`(10), `test_appliance_catalog.py` 인터폰 1,
`rpi/tests/test_deploy_run_backend.py`(2), 폰 `test/models/appliance_category_test.dart`(3), 키오스크 `appliance_category_test.dart` 기대 표에 intercom.
변형 확인: `ch`를 무시하게 바꾸면 채널 시험 6건, 끝 기다림을 끄면 M2 시험 5건이 실패. 옛 `run_backend.sh`는 S9 시험에 걸린다.
의도한 기대 변경 2건: `test_routines.py`의 `wait_until_done` 설명 문구(시작만 확인 표시).

- 백엔드 `rpi rpi4` **2,377 통과**(직전 2,344).
- 폰 `flutter analyze` info 4(error·warning 0), 시험 **537**(골든 제외) 통과, 골든 **55** 통과 — `lt_editor.png`(가전 추가 종류 칩에 인터폰)만 갱신, 눈으로 확인.
- 키오스크 analyze info 1, 시험 **241**(골든 제외)·골든 **41** 통과(변화 없음). `pubspec.lock` 변동은 되돌림.
- 펌웨어(PlatformIO, `C:\pio-venv-motion`, 코어 `C:\.pio-motion`): `firebeetle32`·`firebeetle32_adc`·`firebeetle32_1ct` 모두 SUCCESS(자리표시자 `#warning`만). 플래시하지 않았다.

## 남은 것 · 주의

- 두 번째 CT 수령 → 배선(세탁기는 릴레이 밖) → 채널별 무부하 잡음·정격 부하 보정.
- ADS1115 단발 돌려 읽기의 실제 변환 시간·I2C 여유(2 ms 틱)는 실기기에서 `err` 수로 확인.
- 전자레인지 사이클 기준(`SIMPLELAY_CYCLE_MICROWAVE_*`)은 실제 가열 리허설(D3)에서 잰다. 조리 중 출력 조절 구간 전력이 대기 상한(15 W) 위라는 가정도 측정 필요.
- RPi5 `SIMPLELAY_ROUTINE_DONE_SENSORS`와 RPi4 `SIMPLELAY_DONE_WATCH`는 손으로 맞춘다(서로 확인하는 경로 없음).
- 보드에는 아직 배포하지 않았다(10/6 배포는 `5ef4578` 기준).
