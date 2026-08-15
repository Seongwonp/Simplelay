# api

앱 연동 및 실행 이력/성공률 로그 API.

현재 `SimpleLayService`가 목적 실행과 마지막 결과 상태 조회를 제공하는 프레임워크 독립 진입점이다.
FastAPI/앱 전송과 영속 로그는 M5에서 이 서비스 바깥의 어댑터로 추가한다.

## 준비 상태와 종료

`SimpleLayService`는 "프로세스가 시작됨"과 "명령을 받을 준비가 됨"을 구분한다.

- 기본값(`start_ready=True`)은 지금까지의 동작과 같다. 향후 FastAPI로 감쌀 때 컨트롤러·
  검증기 등 하드웨어 의존성이 실제로 초기화됐는지 먼저 확인하고 싶다면 `start_ready=False`로
  생성한 뒤, 확인이 끝나는 시점에 `mark_ready()`를 호출한다. 그 전까지 `execute_purpose()`는
  `ServiceNotReadyError`를 던진다.
- `request_shutdown()`은 이후 들어오는 `execute_purpose()` 호출만 `ServiceNotReadyError`로
  거부한다. 이미 시작된 실행(폐루프 재시도 도중 포함)은 중간에 끊기지 않고 끝까지 진행된다.
- `status()`가 돌려주는 `StatusSnapshot.ready`로 두 상태를 한 번에 확인할 수 있다
  (`ready and not shutting_down`).
