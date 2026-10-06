# 2026-10-06 — UART 링크 재연결·모의 보관 위치 여유 거리 (교차 리뷰 수리)

`682715b`·`7d8f053` 교차 리뷰 결과 3건. **모의·단위 시험 수준이며 보드 재확인 전이다.**

## 1. (HIGH) RPi4 실행기가 다시 뜨면 RPi5 링크가 살아나지 않음

- 보드에서 본 것: RPi5 `SIMPLELAY_UART_PORT=socket://<RPi4>:7000` 상태에서 RPi4 실행기 컨테이너가
  재시작되면 읽기 루프가 `SerialException: read failed: socket disconnected`로 죽고, 백엔드를 다시
  켤 때까지 다음 실행이 실패(`execution_mode unknown`)했다.
- 수리(`rpi/services/act_client.py`·`act_client_controller.py`):
  - EOF·읽기 오류 → 링크 끊김 표시(`link_up=False`), 기다리던 실행·해제 확인·리허설 요청을 **바로**
    `ActLinkError`로 실패시킨다(타임아웃까지 붙잡지 않음). 그 실행의 sequence_id는 지연 응답 폐기 목록에 넣는다.
  - 걸림 상태를 `None`(모름)으로 돌린다 → 서비스가 기존 사유 "비상정지 상태를 확인하는 중이에요"로 412 거절.
    **풀림으로 가정하지 않는다.** 끊긴 동안 보내기는 `ActLinkError`.
  - `connector`가 있으면 0.5초부터 두 배씩, 상한 5초 간격으로 같은 포트를 다시 연다. 이으면 `hello`부터
    보내고, RPi4의 `estop_state` 답을 받은 뒤에만 실행이 열린다.
  - 운영 공장 `open_uart_act_controller`가 같은 포트를 다시 여는 connector를 붙인다 — `socket://`와
    `/dev/tty*`(USB 뽑힘) 공통. 기본값·줄 단위 JSON 규약은 그대로다. 첫 연결 실패 시 기동 실패도 종전 그대로.
- 시험: `rpi/tests/test_act_client_reconnect.py` 6건(끊김→거절→재연결→hello→답 뒤 성공, EOF, 간격 상한,
  서비스 거절 사유, 공장 배선). 수정 전 코드에서 6건 모두 실패 확인(기존 API만 쓰는 시험은 대기 실행이
  타임아웃까지 붙잡혀 실패, 공장 시험은 포트를 다시 열지 않아 실패).

## 2. (MEDIUM) 모의 보관 위치가 범위·여유 거리를 어길 수 있음

- `simulated_hold_plan`이 보관 위치가 정지 위치와 같을 때 x+15mm로만 비켜, 600mm 밖으로 나가거나 다른
  버튼과 15mm 안에 놓일 수 있었다.
- 수리(`rpi/services/stop_park.py`): 범위(MM_RANGE, 소프트 리밋이 있으면 그 안)·정지 위치와 보정된 모든
  버튼에서 `PARK_CLEARANCE_MM` 밖인 자리를 고른다(선호 위치가 맞으면 그대로, 아니면 5mm 격자에서 가장 가까운
  자리). 없으면 계획 없음 + 이유 `no_park_position`. 시뮬레이터 전용 — UART·실물 경로(`hold_plan_for`)는 그대로.
- 시험: `rpi/tests/test_stop_hold_sim.py` 6건 추가, 수정 전 6건 실패 확인.

## 3. (LOW) 연속 실행 사이 대기 표시 누수

- 같은 SimulatorController로 정지 버튼 있는 가전 → 없는 가전 → 있는 가전을 이어 돌려 위치 출처·대기 안 한
  이유가 서로 새지 않는지 회귀 시험을 넣었다. **수정 전 코드에서도 통과 — 누수 없음**, 시험만 추가.

## 검증

- 백엔드+rpi4 `pytest rpi rpi4`: **2,435 통과**(PYTHONUTF8=1, ASCII basetemp). `test_repo_guard.py` 통과.
- 남은 한계: 실제 보드(RPi4 컨테이너 재시작·USB 뽑기)로 재연결을 다시 확인하지 않았다. 첫 연결 자체가
  실패하면 백엔드 기동이 실패하는 것은 종전 그대로다. 끊김 감지는 읽기 오류·EOF에 의존한다 — 소켓이 조용히
  반쯤 끊긴 경우(상대가 사라졌는데 FIN이 없음)는 다음 실행의 응답 타임아웃으로만 드러난다.
