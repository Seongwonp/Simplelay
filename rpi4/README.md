# rpi4 — RPi4 실행·검증기 (Act)

> 역할: RPi5 허브가 보낸 버튼 순서를 받아 모션 보드(ESP32)로 누르고, 센서·콘센트 CT로 결과를 확인해 돌려주는 실행기.

- 진입점: `python -m rpi4.act_main` — RPi5와 줄 단위 JSON 규약([docs/protocol.md](../docs/protocol.md))으로 이어진다.
  보드에서는 [`deploy/run_act.sh`](../deploy/run_act.sh)가 컨테이너로 세운다(LAN 위 TCP↔가상 시리얼, 링크 키 인증).
- `services/` — 실행기(`act_executor.py`), 정지 대기·보고(`stop_hold.py`), 실행 대상↔CT 채널 결속(`target_binding.py`),
  콘센트 모듈 감시(`outlet_watch.py`), 개발자 조작(`dev_motion.py`), 종료음·위험 소리 감시 등.
- 하드웨어 없이 보기: `python -m rpi4.simulator --scenario all`(메모리 위 규약 왕복), `python -m rpi4.parking_simulator`(정지·보관 모의).
- 시험: 저장소 루트에서 `python -m pytest rpi4/tests`.
- `main.py`·`services/bridge.py`는 보드 역할을 나누기 전의 옛 ESP32↔RPi5 브리지다(예비 경로, 이름만 이 폴더에 남음).

검증 수준: RPi5↔RPi4 LAN 통신과 모의 실행은 보드에서 확인, 10/12 RPi4→ESP32 실물 링크로 조이스틱 이동·정지 전달까지 확인.
센서 판정·CT 판정·실제 누름은 아직 실물 검증 전이다(최신은 [README](../README.md) 검증 수준 표).

## 담당자 원본 Touch Bridge 펌웨어 연결 (2026-10-23)

HW 코드는 담당자만 수정한다. SimpleLay가 USB 명령·응답을 기존 펌웨어에 맞춘다.

RPi4 설정은 `SIMPLELAY_MOTION_MODE=serial`을 유지하고 **`SIMPLELAY_MOTION_PROTOCOL=touchbridge-v2`**를 선택한다.
기존 펌웨어용 기본값은 `line-json/v0`다. 포트와 baud는 기존처럼 명시한다.

Touch Bridge 어댑터는 mm 목표를 원본 v2 `move_only`로 보내고, 해당 명령의 `POSITIONED`·좌표·위치 토큰을 받은 뒤
`press`에 그 토큰을 한 번 사용한다. CoreXY 카운트 변환·PID·모터/핀 설정을 호스트가 다시 계산하거나 바꾸지 않는다.
연결·반복 조그에서 자동으로 `home`을 보내지 않으며, 원본이 보고한 기준 설정 상태를 읽는다.
`SIMPLELAY_MOTION_AUTO_HOME`과 기존 솔레노이드/카운트 설정은 이 어댑터에 적용하지 않는다.
원본 v2는 `press_ms` 유지 시간 지정을 지원하지 않는다. 누름 동작은 원본 SwitchBot 설정을 따른다.

기존 상태/연결/홈/이동/누름 timeout 환경변수를 사용할 수 있다. Touch Bridge 기본값은 각각 1/5/80/30/10초로,
호스트 대기 예산이며 실측 결과가 아니다. 위치 허용 오차는 원본 기본 0.7 mm이고
`SIMPLELAY_TOUCHBRIDGE_TOLERANCE_MM`로 전달한다. 타임아웃·허용 오차는 실제 기구에서 후속 확인한다.

USB는 한 리더가 읽으며 `commandId`로 응답을 분배한다. 정지 응답의 표시 상한은 `mcu_ack`다.
원본 v2 상태에는 물리 정지 검증용 엔코더 정보가 없어 `verified`를 만들지 않는다.
이 프로토콜 선택은 RPi5에 `motion:serial`과 `motion_protocol:touchbridge-v2`로 알려 기존 연결 경로를 유지한다.

[인계 도구 안내](../docs/RPi4-하드웨어-인계-2026-10-23.md) · [전체 작업 계획](../docs/통합-재설계-실행계획-2026-10-23.md).
인계용 도구와 설정 예시는 준비해도 운영 실행기를 자동으로 재기동하지 않는다.
