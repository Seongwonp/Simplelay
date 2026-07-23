# intent

사용 패턴 학습 + 목적 → 버튼 시퀀스 의도 해석 (공감지능). Touch Bridge의 Gemini 프롬프트를 확장 재사용.

## 명시적 명령

`RuleBasedIntentResolver`는 `우유 데워줘`를 `해동 → 시간 90초 → 시작`으로 변환한다. 좌표와
G-code는 알지 못한다. 이 명시적 명령 경로는 M4 제안 경로와 독립적으로 그대로 동작한다.

`LlmIntentResolver`는 모델 출력 검증과 규칙 기반 fallback을 설계한 뒤 구현할 인터페이스
자리이며, 지금은 외부 LLM을 호출하지 않는다.

## M4 공감지능

1. `SimpleLayService`가 완료된 명시적 실행의 시간·목적·성공/실패를 `UsageLog`에 기록한다.
2. `PatternDetector`가 현재 시간대와 같은 구간의 성공 기록을 목적별로 집계한다.
3. 설정된 최소 반복 횟수에 도달하면 `ProactiveSuggestionService`가 pending 제안을 만든다.
4. 제안 생성만으로는 어떤 버튼도 누르지 않는다. 제안 ID에 대한 `approve()`가 정확히 한 번
   호출되어야 기존 `IntentResolver → ClosedLoopController` 경로가 실행된다.

시간대 구간과 최소 반복 횟수에는 임의 기본값이 없다. `PatternConfig`로 반드시 주입해야 하며,
운영 정책과 사용자별 학습 결과가 생기면 그 설정을 교체한다. 실패한 실행은 로그에는 남지만
제안 학습 횟수에는 포함하지 않는다.

## mock과 실장 지점

- `InMemoryUsageLog`는 프로세스 종료 시 사라지는 소프트웨어 구현이다. 실제 DB/파일 저장소는
  `UsageLog`를 구현해 교체한다(TODO M5).
- `FixedClock`은 테스트가 지정한 시각만 반환하는 mock이다. 운영에서는 `SystemClock`을 사용한다.
- `MockPurposeExecutor`는 승인 호출을 기록할 뿐 폐루프를 실행하지 않는다. 통합 경로에서는
  실제 `SimpleLayService`를 주입한다.
- 제안 표시, 사용자 승인 UI와 승인 요청 인증은 앱/API 연동 범위이므로 M5에서 구현한다.
