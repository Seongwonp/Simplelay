# packages — 폰·키오스크 공용 Dart 패키지

> 역할: 폰 앱(`app/`)과 키오스크(`rpi5-touchscreen-app/`)가 경로 의존성으로 함께 쓰는 Dart 패키지.

| 패키지 | 무엇 | 쓰는 곳 |
| --- | --- | --- |
| [`routine_rehearsal/`](routine_rehearsal/) | 여러 가전 루틴 **리허설 화면**(시뮬레이터 API만 부른다 — 실제 명령을 보내지 않음) | `app/pubspec.yaml` · `rpi5-touchscreen-app/pubspec.yaml` |
| [`appliance_artwork/`](appliance_artwork/) | 가전 종류 **선 그림**(문자열 종류 키 → 그림). 폰·키오스크가 같은 그림을 쓴다 | `app/pubspec.yaml` · `rpi5-touchscreen-app/pubspec.yaml` |

- 시험: `cd packages/routine_rehearsal; flutter test`.
- 두 앱의 서버 응답 모델(명령 결과·정지 단계 문장 등)은 아직 각 앱에 따로 있다. 공용 모델 패키지로 모으는 것은 결선 뒤 계획이다([코드 구조](../docs/코드-구조.md) §7).
