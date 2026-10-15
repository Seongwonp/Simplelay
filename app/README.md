# app — 폰 앱 (Flutter, Android)

> 역할: 폰 앱 — 승인·실행·정지·기록·가전 추가·루틴·설정. RPi5 허브 API에 붙는다. 앱 골격은 Touch Bridge에서 가져와 확장했고([재사용 경계](../docs/reuse-boundary.md)), 승인·결과·제안·가전 등록 화면은 SimpleLay 신규다.

## 구조 (`lib/`)

| 폴더 | 무엇 |
| --- | --- |
| `screens/` | 화면 — 홈(`home_screen.dart`)·제안(`suggestion_screen.dart`)·상태(`status_screen.dart`)·기록(`history_screen.dart`)·루틴(`routines_screen.dart`·`routine_editor_screen.dart`)·가전 추가 5단계(`add_appliance_wizard_screen.dart`)·가전 상세·수동 조작·음성·폰 연결(`pairing_screen.dart`)·설정·개발자 콘솔(`developer_console_screen.dart`) |
| `providers/` | 상태(Provider) — 허브 연결·API(`rpi_api_provider.dart`)·실행 상태·정지·비상정지·제안·루틴·음성 정지 등 |
| `services/` | 허브 HTTP(`rpi_api_service.dart`)·개발자 API·음성·TTS·사진·mDNS 찾기 |
| `models/` | 서버 응답 모델 — 명령 결과·정지 단계 문장(`command_result.dart`)·실행 상태·비상정지·자동 실행 규칙·루틴 |
| `widgets/` | 공용 위젯 — 비상정지 띠·자동 실행 확인 시트·ThinQ 상태 카드·버튼 격자·입력 보호 |
| `theme/` | 색·글자 크기 |

서비스는 생성자 주입이라 시험에서 가짜로 바꾼다. 키오스크와 같은 서버 응답을 읽지만 모델은 아직 각 앱에 따로 있다(공용 패키지는 [`packages/`](../packages/README.md)의 리허설 화면 하나).

## 정지 표시

정지 결과는 서버의 정지 단계(보냄 → 모션 보드 응답 → 멈춤 확인)를 그대로 보여 준다. 일반 화면 문구 기준은 [용어와 화면 문구](../docs/용어와-화면문구.md),
'확인됨' 수준이 키오스크와 어떻게 다른지는 [코드 구조](../docs/코드-구조.md) §2.

## 시험·빌드

```powershell
flutter test --exclude-tags screenshot     # 위젯·단위 시험(10/15 기준 886개, 골든 제외)
flutter test --tags screenshot             # 골든 비교(갱신 없이)
flutter analyze                            # error·warning 0이어야 커밋
flutter build apk --release                # JDK17 + Android SDK
```

- 한글 경로에서 Dart 분석 서버 문제가 있었다 — ASCII 정션 경로에서 실행한다(작업 규칙 문서).
- 에뮬레이터 설치 APK는 `--split-per-abi`로 빌드해야 덮어쓰기된다.
- **검증 수준:** 에뮬레이터 → RPi5 → RPi4 경로는 실물 확인(9/30~), **실폰은 미확인**. 기준 표는 [README](../README.md) 검증 수준.
