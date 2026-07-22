# rpi — 라즈베리파이 Brain 레이어 (SimpleLay 신규 핵심)

XY 갠트리(Touch Bridge 재사용) 위에 얹는 SimpleLay만의 지능·검증 레이어.

| 모듈 | 역할 | 마일스톤 |
| --- | --- | --- |
| [verifier/](verifier/) | 전류·음향 센서로 "진짜 눌렸나" 검증 | M1 |
| [controller/](controller/) | 폐루프 — 명령 → 검증 → 실패 시 재시도 | M2~M3 |
| [intent/](intent/) | 사용 패턴 학습 + 의도 해석 (공감지능) | M4 |
| [api/](api/) | 앱/로그 연동 | M5 |

설계: [../docs/architecture.md](../docs/architecture.md) · [../docs/closed-loop-design.md](../docs/closed-loop-design.md)

> 언어/런타임(Python 권장)과 의존성은 M1 착수 시 확정. 지금은 골격만.
