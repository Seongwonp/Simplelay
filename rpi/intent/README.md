# intent

사용 패턴 학습 + 목적 → 버튼 시퀀스 의도 해석 (공감지능). Touch Bridge의 Gemini 프롬프트를 확장 재사용.

## 명시적 명령

`RuleBasedIntentResolver`는 `우유 데워줘`를 `해동 → 시간 90초 → 시작`으로 변환한다. 좌표와
G-code는 알지 못한다. 이 명시적 명령 경로는 M4 제안 경로와 독립적으로 그대로 동작한다.

`LlmIntentResolver`는 모델을 신뢰하지 않는 입력으로 다룬다. 응답은 반드시
`{"sequence": [...]}` 형태의 JSON이어야 하고, `known_buttons`를 넘기면 그 안에 없는 버튼
이름이 하나라도 섞이면 거부한다. JSON 파싱 실패·빈 시퀀스·미등록 버튼·클라이언트 호출
자체의 예외까지 모두 같은 경로로 처리되어, 주어진 `fallback`(보통 `RuleBasedIntentResolver`)
으로 즉시 넘어간다. fallback도 실패하면 호출자는 `UnknownIntentError` 하나만 처리하면 된다.

모델 호출은 `LlmClient` 포트(`ports.py`) 뒤에 있다. `HttpLlmClient`는 OpenAI 호환
chat-completions 엔드포인트를 표준 라이브러리(`urllib`)만으로 호출하는 실제 구현이고,
테스트에서는 `mock.py`의 `MockLlmClient`로 정해진 응답·예외를 주입한다.

버튼 이름 검증에 쓰는 어휘는 `appliance.py`의 `load_button_map()`으로
`docs/button-maps/<appliance>.json`을 읽어 만든다(`ApplianceManifest.labels`). 이 파일은
원래 앱의 좌표 매핑용으로만 쓰였는데, 이제 의도 해석 계층의 검증 사전으로도 재사용한다.

## 우선순위 조립 — `TieredIntentResolver`

`LlmIntentResolver` 하나만 놓고 보면 "모델을 먼저 부르고 실패하면 규칙으로 폴백"하는
순서다. 하지만 [docs/inference-boundary.md](../../docs/inference-boundary.md)의 결론은
반대다 — 지연시간·신뢰성·개인정보가 정확도보다 우선이라, **온디바이스(규칙)를 먼저 시도하고
외부 호출이 필요한 경로는 그 뒤에만** 와야 한다. `TieredIntentResolver(resolvers)`가 이 순서를
조립하는 도구다. 넘긴 순서대로 시도하고, 각 리졸버가 `UnknownIntentError`를 던질 때만 다음
리졸버로 넘어간다(그 외 예외는 진짜 버그이므로 그대로 전파된다).

```python
resolver = TieredIntentResolver((
    RuleBasedIntentResolver(),              # 1. 온디바이스, 결정론적, 인터넷 불필요
    LlmIntentResolver(client, known_buttons=labels),  # 2. 온디바이스/외부 모델, 마지막 수단
))
```

`rpi/api/deps.py`는 아직 `RuleBasedIntentResolver()` 단독으로만 배선돼 있다(LLM 리졸버가
실제 서비스에 연결된 적이 없음). 나중에 연결할 때는 위 조립 순서를 그대로 따른다.

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
- `MockLlmClient`는 목적 문자열에 대해 미리 정해 둔 원문 응답(또는 예외)을 돌려주는 결정론적
  더블이다. 실제 배선에서는 `HttpLlmClient`를 주입하고, API 키·엔드포인트·모델명은
  `HttpLlmClientConfig`로 외부에서 주입한다(TODO: 배선은 M5 API 계층에서).
- 제안 표시, 사용자 승인 UI와 승인 요청 인증은 앱/API 연동 범위이므로 M5에서 구현한다.
