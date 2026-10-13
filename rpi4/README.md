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
