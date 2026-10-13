# 2026-10-06 — UART 첫 연결 실패에도 백엔드 기동 (인계 §6)

[노트북 인계 2차 §6](인계-2026-10-06-노트북-2.md). **모의·단위 시험 수준이며 보드 확인 전이다.**

## 문제

`open_uart_act_controller`가 첫 연결을 그 자리에서 기다렸다. RPi4 실행기가 꺼져 있으면(`socket://` 거절,
`/dev/tty*` 없음) 예외가 나 백엔드가 서비스를 만들지 못했다(첫 요청에서 기동 실패). 재연결(`4aedf5f`)은 한 번
이어진 뒤의 끊김만 다뤘다.

## 수리

- `rpi/services/act_client.py`: `ActClient(None, None, connector=...)`로 스트림 없이 만들 수 있다 — 링크 끊김
  (`link_up=False`, `link_down_reason="not connected yet"`, `ever_connected=False`)으로 시작하고, `start()`의 읽기
  루프가 배경에서 첫 연결을 시도한다. 첫 시도는 바로, 실패하면 재연결과 같은 간격(0.5초부터 두 배, 상한 5초).
  이으면 `hello`부터 보내고, `estop_state` 답을 받기 전까지 걸림 상태는 `None`(모름)이다. 잇기 전 보내기는
  `ActLinkError`.
- `rpi/services/act_client_controller.py`: 공장이 첫 연결을 기다리지 않고 위 방식으로 만든다. `link_status()` 추가.
- `rpi/api/service.py`: 거절 사유 순서 = 걸림 → **링크 끊김·첫 연결 전 `ACT_LINK_DOWN_REASON`
  ("누름 장치 연결 안 됨 — 다시 연결하는 중이에요")** → 상태 모름(확인 중). 기존 412 준비 안 됨 경로 그대로.
  `actuator_link_up()` 추가. 끊긴 동안 사유가 "확인하는 중"에서 이 문장으로 바뀌었다(재연결 시험 단언 갱신).
- 상태 노출: `/status.actuator_link_up`(새 필드, 보고 없는 실행 대상이면 null), `/health.actuator_ready=false`
  (링크 끊김일 때), `/connections` 누름 장치 항목 `error`·"누름 장치 연결 안 됨"(`down`).
- 화면: 폰(가전 상세·직접 조작·제안 화면)과 키오스크(직접 조작·연결 아이콘)는 이미 `readiness_reasons`와
  `/connections` 제목을 그대로 보인다 — **Flutter 코드 변경 없음**(키오스크 버전 그대로 1.8.1).
- 기본값·줄 단위 JSON 규약은 그대로다.

## 시험

- `rpi/tests/test_act_client_first_connect.py` 3건: 스트림 없이 시작 → 거절 → 배경 연결 → hello → 답 뒤 성공;
  공장이 첫 연결 실패에도 돌아오고 계속 다시 시도; API까지(412 "누름 장치 연결 안 됨"·`/status`·`/health`·
  `/appliances`·`/connections` → 이은 뒤 답 전 "확인하는 중" → 답 뒤 실행 성공).
- 수정 전 코드에서 3건 모두 실패 확인(공장은 `OSError`로 실패, 클라이언트는 `link_up=True`로 시작, 사유 상수 없음).
  재연결 시험의 공장 시험은 첫 연결이 배경이 되어 연결을 기다리게 고쳤다.
- 백엔드+rpi4 `pytest rpi rpi4`: **2,438 통과**(PYTHONUTF8=1, ASCII basetemp). `test_repo_guard.py` 통과.

## 한계

- 보드에서 확인 전: RPi4 실행기를 끈 채 RPi5 백엔드를 띄웠다가 실행기를 켜 자동으로 붙는지 확인해야 한다.
- `/health`가 이제 `get_service`에 의존한다 — 서비스 생성이 다른 이유(예: `SIMPLELAY_L3_MODE=real` 기동 거절)로
  실패하면 `/health`도 실패한다(종전엔 그 경우에도 ok였다).
- 폰 홈 카드는 사유 없이 "준비 필요"만 보인다(상세에서 사유). 폰에 전역 링크 표시는 넣지 않았다.
