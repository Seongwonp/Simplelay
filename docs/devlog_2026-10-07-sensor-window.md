# 2026-10-07 누름 관측 구간 — 인계 노트북-3 §A (H1·H2)

평가 기준 커밋 `1727698`의 HIGH H1·H2 수리. **전부 모의(가짜 하드웨어 모듈) 수준이다 — ADS1115·마이크 실물 연결 0건.** 임계값·간격은 모두 추측이며 실측 필요로 남긴다.

## 결함
- **H1** `CurrentSensor.is_pressed`는 이동평균 창(`window_size` 20)이 찰 때까지 늘 False였다. 생성 때 기준선을 채우지 않고 시도당 1회만 읽어, 기본 설정 첫 버튼은 3회 재시도 후 `safety_stopped`. 음향만 성공하면 0.45 < 0.50. 기존 시험은 `verify()`를 미리 여러 번 불러 결함을 가렸다.
- **H2** `SounddeviceReader` 콜백이 큐(4)가 차면 **새 프레임을 버렸다**. `ClosedLoopController`는 누름이 끝난 뒤에야 센서를 한 번 읽어, 큐에 남은 누름 전 소리로 판정할 수 있었다. 마이크 프레임이 1초 안 오면 0 프레임(=무음)을 돌려 단절과 무음이 섞였다.

## 바꾼 것
- **관측 구간 하나**: 컨트롤러가 누르기 직전 `verifier.begin_press(button)` → 누름 → `verify()`가 구간을 닫아 판정, 누름 명령이 실패하면 `cancel_press()`.
  - 전류(`CurrentSensor.open_window/close_window`): 누르기 직전 `window_size`개로 기준선, 누르는 동안 배경 스레드가 `sample_interval_s`마다 시각과 함께 읽음, 누름 뒤 `post_press_s`까지 더 읽고 닫음. 기준선 대비 `press_threshold_a` 초과 표본이 `min_samples_above`개 이상이면 누름.
  - 마이크(`AudioSensor.open_window/close_window`): 콜백이 프레임마다 monotonic 시각을 찍는다. 구간 시작 때 큐에 쌓인 프레임은 버리고, 구간 `[시작, 누름 끝+post_press_s]` 안 프레임만 판정한다.
- **큐**: 길이 `queue_frames`(128 ≈ 4 s), 차면 가장 오래된 것을 버리고 최신을 남긴다(`dropped` 집계).
- **단절 ≠ 무음·0**: ADC 읽기 예외·비유한 값·(선택) `valid_voltage_range` 밖 전압, 마이크 스트림 비활성, 구간 안 프레임 0개 → `SensorUnavailable`(`rpi/verifier/base.py`). 한쪽만 끊겨도 판정하지 않는다. 컨트롤러는 **다시 누르지 않고** 안전 정지(`L1 press sensor unavailable …`) + 알림. 누르기 전 기준선을 못 읽으면 아예 누르지 않는다.
- 배선: `FailureInjectionVerifier`(`rpi/services/demo_failure.py`)가 `begin_press`·`cancel_press`를 안쪽으로 넘긴다 — 실제 진입점(`rpi4/act_main._build_executor`)이 센서 검증기를 이 래퍼로 감싸므로 필요했다. 주입 실패 때는 열린 구간을 닫는다. `rpi4/act_main.py`·`rpi4/models`는 건드리지 않았다.
- 새 설정값(`rpi/verifier/config.py`, 전부 추측·실측 필요): 전류 `sample_interval_s` 0.002 · `post_press_s` 0.05 · `min_samples_above` 2 · `max_window_s` 30 · `valid_voltage_range` None, 마이크 `queue_frames` 128 · `post_press_s` 0.15 · `stall_timeout_s` 0.5 · `min_frames_above` 1. 기존 임계값(12 mA·0.35·가중치 0.55/0.45·0.50)은 그대로.

## 시험 (`rpi/tests/test_sensor_window.py`, 13건)
실제 진입점과 같은 배선: `SIMPLELAY_SENSORS_ENABLED=true` + `act_main._build_executor`, 하드웨어 라이브러리(`board`·`busio`·`adafruit_ads1x15`·`sounddevice`)만 가짜 모듈로 바꿔 실제 `Ads1115Reader`·`SounddeviceReader`·`SensorVerifier()`(기본 설정) 생성 경로를 탄다. 모션만 누를 때 신호를 내는 대역. 준비 호출 없음.
- 기본 설정 첫 실행 → 첫 누름에 성공(신뢰도 1.0)
- 누르기 전 큐에 쌓인 버튼음 → 소리 증거 아님(audio ❌, 전류만 0.55)
- 다른 부하가 먼저 켜져 있음 → 누름 기여만 Δ100 mA / 부하 증가 뒤 누름 반응 없음 → 전류 ❌ / 옛 방식으로 창을 채운 뒤 누르기 전 부하 증가 → 누름으로 세지 않음
- ADC 누름 중 단절 → 1회 누름 후 정지 / 누르기 전 단절 → 누르지 않음 / 마이크 프레임 없음·스트림 정지 → 1회 누름 후 정지
- 전류 0·무음(연결됨) → 단절이 아닌 정상 재시도 경로(3회)
- 큐가 차면 최신 유지, 프레임 시각 단조 증가, 구간 스레드 누수 없음

**수정 전 코드에서 실패 확인:** 13건 중 10건 실패(9건은 판정 차이 — `safety_stopped`·`audio=✅`·OSError 전파·3회 누름·0번 프레임 잔존, 1건은 `drain` 없음). 통과 3건은 대조 시험(부하 증가+무반응, 0·무음 정상 경로, 스레드 누수)으로 옛 코드에서도 같은 결과가 맞다.
`test_sensor_verifier.py`의 `TestSensorVerifier` 준비 호출 8곳을 지웠다(그대로 두면 새 구간에서 기준선이 스파이크로 잡혀 3건 실패 — 가림이 사라졌다는 뜻).

## 검증
- 백엔드+rpi4 `PYTHONUTF8=1 pytest -q rpi rpi4` **2,451 통과**(골든 없음). `test_repo_guard.py` 5 통과. 중간 실행에서 `test_act_client.py::test_late_result_after_timeout…`이 부하 중 한 번 실패, 단독 3회·전체 재실행 통과(센서와 무관한 시간 의존 시험).

## 한계
- 실물 미검증. Windows 타이머 해상도(약 15 ms) 때문에 개발 PC에서 구간당 전류 표본이 몇 개뿐이다 — RPi4에서 ADS1115 실제 표본 수·잡음은 측정 필요.
- 구간은 `grbl.press()` 전체(XY 이동+Z 누름)를 덮는다. 이동 중 우연히 생긴 전류·소리는 여전히 증거로 셀 수 있다. MCU `press_start` 이벤트로 구간을 좁히는 일은 남음.
- ACS712가 빠져도 ADC가 그럴듯한 전압을 내면 단절로 못 본다. `valid_voltage_range`는 분압 회로(M2) 확인 뒤 정한다.
- 위험 소리 감시 루프가 쓰는 `SounddeviceReader.read_frame()`은 여전히 1초 무프레임 때 0 프레임을 돌려준다(그 루프는 범위 밖).
- 한 센서만 끊겨도 판정하지 않는다(보수적). 한 센서만으로 이어 갈지는 실측 뒤 팀이 정한다.
