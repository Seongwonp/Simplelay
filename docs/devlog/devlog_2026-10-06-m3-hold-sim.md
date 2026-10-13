# 2026-10-06 — 시연 v3 갭 M3: 전부 모의 등급의 정지 버튼 대기·보관 흉내

> **모의까지다.** 모터·Z 누름 모듈·CT 전력 리더 없이 시뮬레이터(모의 RPi4 실행기)로만 돌렸다.
> 모의 위치는 실물 좌표가 아니고, 폰·키오스크 화면은 실기기로 확인하지 않았다.

## 무엇이 문제였나

⑤의 "화면 정지 → 정지 버튼 위 대기 → 보관"은 RPi5가 `hold_plan_for`로 계획을 만들 때만 열린다.
계획은 정지 버튼 mm와 보관 위치가 다 있어야 생기는데, 전부 모의 등급에는 사진 매핑이 없어
`/status.hold_state`가 늘 `null`이었다(10/6 리허설 확인).

## 바꾼 것

- `rpi/services/stop_park.py` `simulated_hold_plan` — **시뮬레이터 전용.** 정지 버튼이 등록된 가전이면
  빠진 mm를 `MOCK_STOP_XY`·`MOCK_PARK_XY`(모의 위치)로 채운 계획과 위치 출처(`mock`·`calibrated`)를 돌려준다.
  정지 버튼이 없으면 `(None, "no_stop_button")`.
- `rpi/services/simulator_controller.py` — `simulates_stop_hold = True`, `arm_simulated_stop_hold`.
  선(execute 메시지)에는 종전 `hold` 필드만 싣는다. RPi4 실행기·`StopHoldSession`·보고 프레임은 UART와 같은 코드다.
  - 모의 위치 대기에서는 모의 가전을 감싸(`_UnknownAfterStopRun`) **정지 버튼을 누른 뒤 켜짐/꺼짐을 모름**으로 둔다.
    그래서 결과는 `requested_unconfirmed`("정지 요청함·미확인")를 넘지 않는다 — 전력 리더 없는 실기기와 같은 결과.
    `SIMPLELAY_HOLD_MOCK_STOP=honor`여도 정지됨을 만들지 않는다.
  - 최대 대기를 모의 가전 동작 시간(`SIMPLELAY_HOLD_MOCK_RUN_S`, 기본 30초)으로 줄여, 미확인으로 남은 대기가
    30분(실기기 설계 초기값)을 기다리지 않고 보관 위치로 간다(`park_reason hold_timeout`, "가전 종료는 미확인").
  - 정지 버튼이 없으면 `hold_state null`과 이유(`hold_unavailable_reason no_stop_button`, `hold_detail`)를 보인다.
- `rpi/api/service.py` — 실행 직전, 대상이 `simulates_stop_hold`이면 `arm_simulated_stop_hold`, 아니면 종전
  `hold_plan_for`. UART(`ActClientController`)·로컬 경로는 바뀌지 않았다.
- `/status`(옛 클라이언트는 무시): `hold_position_source`·`hold_probe_source`·`hold_unavailable_reason`.
- 사진 매핑으로 mm가 있는 가전은 종전 계획 그대로(`calibrated`) — 기존 끝단 시험의 "정지됨(모의)"도 그대로다.

## 검증

- 새 시험 `rpi/tests/test_stop_hold_sim.py` 6건. 수정 전 코드에서 6건 모두 실패 확인 — 대표 실패 줄은
  `_until(c, lambda s: s["hold_state"] == "hovering_stop" ...)`의 시간 초과(`hold_state: None`),
  `KeyError: 'hold_unavailable_reason'`, `ImportError: cannot import name 'simulated_hold_plan'`.
  첫 구현(모의 가전이 정지에만 반응하지 않게)은 모의 가전 시간이 끝날 때 늦은 하강으로 `stopped`가 나와
  두 시험이 실패했다 → 누른 뒤 '모름'으로 바꿔 통과.
- 백엔드 `pytest rpi rpi4` **2,421 통과**(직전 2,415 + 6, 골든 제외), 저장소 가드 통과.
- 서버 HTTP 리허설(v3 §3-4 ⑤-d)과 폰·키오스크 화면은 아직 안 돌렸다.
