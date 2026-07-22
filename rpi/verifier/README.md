# verifier

전류·음향 센서로 버튼이 실제로 눌렸는지 판정한다. 자세한 설계: [../../docs/closed-loop-design.md](../../docs/closed-loop-design.md)

- `Verifier.verify(button)`은 눌림 여부와 0~1 신뢰도를 반환하는 하드웨어 독립 계약이다.
- `MockVerifier`는 테스트 시나리오를 순서대로 반환하는 명시적 mock이며 실측 데이터가 아니다.
- `SensorVerifier`는 실제 구현 자리다. M1 실측 후 접점과 전류/음향 입력, 캘리브레이션 및
  2단 판정 로직을 이 인터페이스 뒤에 구현한다.
