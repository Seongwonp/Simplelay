# controller

폐루프 제어: 명령 → verifier 검증 → 실패 시 좌표 보정 후 재시도(횟수 한도). 설계: [../../docs/closed-loop-design.md](../../docs/closed-loop-design.md)

`ClosedLoopController`는 시퀀스의 각 버튼을 GRBL 전송 → 검증 순서로 처리한다. 실패하면 XY
미세 조정과 Z 깊이 증가를 요청하며, 최초 시도를 포함해 기본 3회까지만 시도한다. 모두 실패하면
남은 시퀀스를 실행하지 않고 안전 정지와 알림 포트를 각각 한 번 호출한다.

`MockGrblClient`, `MockAlertSink`, `MockSafetyController`는 테스트용 기록 객체이며 실제 장치를
제어하지 않는다. M5에서 `AlertSink`, `SafetyController` 구현을 추가한다. 보정량과
응답 대기 시간은 실측 전이므로 현재 코드에서 수치로 정하지 않았다. `RetryWaiter`가 실제 대기
구현 지점이며 기본 `NoOpRetryWaiter`와 테스트용 `MockRetryWaiter`는 전혀 sleep하지 않는다.

## GrblClient — 첫 실제 구현체

`DbusGpioClient`(`dbus_gpio.py`)가 `GrblClient`의 첫 실장이다. "버튼 누름"을 GPIO 펄스
하나로 표현한다: 페리페럴을 프로세스당 한 번만 활성화(`EnablePeripheral`)하고, 누를 때마다
열기(`Open`) → 값 1 → `pulse_seconds` 대기 → 값 0 → 닫기(`Close`) 순으로 D-Bus를 호출한다.
D-Bus 자체를 파이썬 바인딩으로 부르지 않고 기기가 제공하는 D-Bus CLI를 서브프로세스로 호출하는
방식을 택했다 — 이 환경에서 별도 파이썬 D-Bus 바인딩이 문서화돼 있지 않기 때문이며, 나중에
진짜 바인딩으로 교체해도 `GrblClient` 인터페이스는 그대로다.

버튼 이름 → GPIO 페리페럴 id 매핑은 이 모듈이 결정하지 않는다(실제 배선이 아직 확정되지
않았으므로) — 호출자가 `button_peripheral_ids`로 명시적으로 주입한다. 배선이 정해지면
`rpi/api/deps.py`의 `MockGrblClient` 자리에 `DbusGpioClient(button_peripheral_ids={...})`를
넣으면 된다. 서브프로세스 호출은 `runner` 콜러블로 주입 가능해 실제 CLI·D-Bus·하드웨어
없이도 전체 흐름을 테스트한다(`rpi/tests/test_dbus_gpio.py`).
