# rpi5-touchscreen-app — 키오스크 (Flutter)

> 역할: RPi5에 붙은 15.8형 터치 패널 키오스크 — 평소·제안·실행 중·가전 동작 중·완료 화면과 정지 버튼. 매일 쓰는 사람(당사자)이 큰 글씨로 승인·거절·정지한다.

800×480 설계 캔버스를 패널 크기(1920×1080)에 맞춰 비율 확대한다(`lib/widgets/kiosk/kiosk_canvas.dart`). 터치는 USB로 들어온다.
옛 HTML 키오스크(`rpi/touchscreen/index.html`)를 옮겨 온 것에서 시작했고, 지금은 그보다 기능이 많다(SSE·큰 글씨·음성 안내·가전 동작 중 대기).

## 화면 (`lib/`)

화면 단계는 `widgets/kiosk/kiosk_phase.dart`의 `KioskPhase`(idle · suggestion · executing · done · manual · hold)다.

| 화면 | 파일 |
| --- | --- |
| 평소 — 인사말·날씨·연결 상태·가전 띠 | `widgets/kiosk/idle_view.dart` · `connection_status.dart` · `appliance_strip.dart` |
| 제안 — 할 일 문장·승인/거절·다음부터 자동 허용 안내 | `widgets/kiosk/suggestion_view.dart` |
| 실행 중 — 지금 누르는 버튼·진행·정지 버튼 | `widgets/kiosk/executing_view.dart` · `top_progress_bar.dart` |
| 완료·실패 — 결과·정지 단계 문장 | `widgets/kiosk/done_view.dart` |
| 가전 동작 중 — 누름 장치가 가전 정지 버튼 위에서 기다림, 정지는 정지 버튼 누름으로 전달 | `widgets/kiosk/hold_view.dart` |
| 직접 조작·가전 고르기 | `widgets/kiosk/manual_view.dart` · `appliance_select_view.dart` |
| 폰 연결 승인(QR·6자리 코드) | `widgets/kiosk/pairing_view.dart` |
| 겹침 — 비상정지 띠·위험 소리 알림·쉬기·설정·자동 실행 알림·연습 띠 | `estop_banner.dart` · `danger_alert_overlay.dart` · `dnd_overlay.dart` · `settings_overlay.dart` · `auto_run_notice.dart` · `practice_band.dart` |

- 화면 상태와 서버 대조는 한 파일 `screens/kiosk_screen.dart`(약 1,650줄)에 모여 있다 — 나누는 것은 결선 뒤 계획([코드 구조](../docs/코드-구조.md) §7).
- 서버 호출은 `services/kiosk_api_service.dart`(같은 보드의 `http://localhost:8000`), 실시간 갱신은 `services/kiosk_event_stream.dart`(SSE).
- 서버 응답 모델은 `models/`(명령 결과·정지 단계 문장 `command_result.dart`·비상정지·자동 실행). '멈춤 확인' ✓ 표시는 엔코더로 멈춤을 확인한 경우만 — 폰 개발자 콘솔과 다르게 의도한 차이다([코드 구조](../docs/코드-구조.md) §2).

## 검증 수준 (10/15)

- 위젯 시험 400개(골든 제외) + 골든 52장 — **화면 문구·배치는 시험 조건에서만 확인했다.**
- 15.8형 실패널 표시·부팅 자동 실행은 실물 확인(9/30~10/7)이지만, **10/15 문구 개선판은 아직 실패널에 설치·확인하지 않았다**(보드의 키오스크는 이전 판).

## 시험·빌드

```powershell
flutter test --exclude-tags screenshot     # 위젯·단위 시험
flutter test --tags screenshot             # 골든 비교(아이콘 글꼴: test/support/golden_fonts.dart)
flutter analyze
```

- **보드 설치 파일 빌드:** 일반 `flutter build`가 아니라 **저장소 밖의 로컬 전용 플랫폼 빌드 환경**(보드 제조사 툴체인)이 필요하다. 빌드 환경과 산출물은 커밋하지 않는다.
  보드 쪽 자동 실행·감시는 [`deploy/`](../deploy/README.md)의 키오스크 감시 컨테이너.
- **웹 빌드:** 브라우저 시뮬레이터용으로 웹 빌드를 만들면 백엔드가 `/kiosk`로 서빙한다 — [`scripts/deploy_kiosk.ps1`](../scripts/deploy_kiosk.ps1), [브라우저 시뮬레이터 실행](../docs/브라우저-시뮬레이터-실행.md).
- 플랫폼 디렉터리(빌드 도구가 만드는 고정 이름 폴더)는 빌드 도구 형식 그대로 둔다.
