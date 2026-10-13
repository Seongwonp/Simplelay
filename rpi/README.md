# rpi — 라즈베리파이 Brain 레이어 (SimpleLay 신규 핵심)

> 역할: RPi5 허브 백엔드(FastAPI) — 의도 해석·승인·제안·실행 상태·폰/키오스크 API. 폴더 이름 `rpi/`는 보드 하나로 설계하던 시절에서 왔고, 지금은 RPi5에서 돈다.

XY 갠트리(Touch Bridge 재사용) 위에 얹는 SimpleLay만의 지능·검증 레이어.

| 모듈 | 역할 | 마일스톤 |
| --- | --- | --- |
| [verifier/](verifier/) | 전류·음향 센서로 "진짜 눌렸나" 검증 | M1 |
| [controller/](controller/) | 폐루프 — 명령 → 검증 → 실패 시 재시도 | M2~M3 |
| [intent/](intent/) | 사용 패턴 학습 + 의도 해석 (공감지능) | M4 |
| [api/](api/) | 앱/로그 연동 | M5 |

설계: [../docs/architecture.md](../docs/architecture.md) · [../docs/closed-loop-design.md](../docs/closed-loop-design.md)

Python 3.11 이상에서 하드웨어 없이 폐루프 전체를 실행할 수 있다.

```bash
python -m pip install -e '.[test]'
python -m pytest
```

## 현재 mock 범위와 실장 지점

- `verifier.MockVerifier`: 주입한 성공/실패 시나리오만 반환한다. 센서 수치가 아니다. M1에서
  `Verifier`를 구현하는 접점+전류/음향 어댑터와 실측 기반 판정·캘리브레이션을 추가한다.
- `controller.mock.MockGrblClient`: `ok` 또는 예외 응답을 흉내 내고 명령을 기록할 뿐 모터를
  구동하지 않는다. M2에서 연결 방식을 확정한 뒤 `GrblClient` 구현을 추가한다.
- `MockAlertSink`, `MockSafetyController`: 호출을 기록할 뿐 앱 알림이나 E-STOP을 작동하지 않는다.
  M5와 하드웨어 안전 설계에 맞춘 각 인터페이스 구현이 필요하다.
- `LlmIntentResolver`: 향후 모델 출력 검증과 fallback 설계 후 연결할 인터페이스 자리이며,
  현재 목적 해석은 규칙 기반으로만 동작한다.
- `intent.InMemoryUsageLog`, `FixedClock`, `MockPurposeExecutor`: M4를 하드웨어·DB·앱 없이
  검증하기 위한 구현이다. 운영 DB는 `UsageLog`, 앱 승인 전달은 제안 API 경계 뒤에 연결한다.

보정 명령은 "XY 조정 필요"와 "Z 깊이 증가 필요"만 표현한다. 실제 거리·깊이·대기 시간은
하드웨어 실측 및 Z 소프트 상한을 정한 뒤 GRBL 어댑터/기기 프로필에서 안전하게 결정해야 한다.
