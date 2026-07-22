# controller

폐루프 제어: 명령 → verifier 검증 → 실패 시 좌표 보정 후 재시도(횟수 한도). 설계: [../../docs/closed-loop-design.md](../../docs/closed-loop-design.md)

`ClosedLoopController`는 시퀀스의 각 버튼을 GRBL 전송 → 검증 순서로 처리한다. 실패하면 XY
미세 조정과 Z 깊이 증가를 요청하며, 최초 시도를 포함해 기본 3회까지만 시도한다. 모두 실패하면
남은 시퀀스를 실행하지 않고 안전 정지와 알림 포트를 각각 한 번 호출한다.

`MockGrblClient`, `MockAlertSink`, `MockSafetyController`는 테스트용 기록 객체이며 실제 장치를
제어하지 않는다. M2/M5에서 `GrblClient`, `AlertSink`, `SafetyController` 구현을 추가한다. 보정량과
응답 대기 시간은 실측 전이므로 현재 코드에서 수치로 정하지 않았다. `RetryWaiter`가 실제 대기
구현 지점이며 기본 `NoOpRetryWaiter`와 테스트용 `MockRetryWaiter`는 전혀 sleep하지 않는다.
