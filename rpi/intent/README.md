# intent

사용 패턴 학습 + 목적 → 버튼 시퀀스 의도 해석 (공감지능). Touch Bridge의 Gemini 프롬프트를 확장 재사용.

현재 `RuleBasedIntentResolver`는 `우유 데워줘`를 `해동 → 시간 90초 → 시작`으로 변환한다.
좌표와 G-code는 알지 못한다. `LlmIntentResolver`는 M4에서 출력 검증과 규칙 기반 fallback을
설계한 뒤 구현할 인터페이스 자리이며, 지금은 외부 LLM을 호출하지 않는다.
