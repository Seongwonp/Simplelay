# 키오스크 외부 평가 후 화면 수정 — 2026-10-16

## 범위와 검증 수준

- 기준 브랜치 `main`, HEAD `e4e3c3dac1d3eccd7bb106fa09748c43f66857a4`의 미커밋 변경이다. 커밋·push·브랜치 생성·stash를 하지 않았다. 새 파일은 `git add -N`으로만 표시한다.
- 키오스크 화면·시험·골든과 디자인 규격 §5만 수정했다. 서버·폰·실행 계약은 그대로다.
- **위젯·골든 시험까지 확인, 실패널 미설치.** 모터·실가전·3 m 가독성·3초 상태 구분·실기기 화면 읽기 검증을 수행한 기록이 아니다.

## 1. 비상 중 정지는 팔을 움직이는가

코드를 따라간 결론: 비상 걸림을 처리한 정지 대기 경로는 가전 취소 버튼을 누르지 않고 구동부를 정지한다. 따라서 비상 걸림 화면에서 '정지를 누르면 취소를 대신 누름'을 약속하면 틀리다.

- `rpi/api/router.py:1011-1016`: 전체 정지에서 현재 hold 상태를 읽고 실행기 정지 경로로 전달한다.
- `rpi4/services/act_executor.py:958-996`: 콘센트 비상 걸림을 설정하고 활성 hold에 `drive_stop()`을 호출한다(983-985). 실행 중이면 controller 정지 요청도 보낸다(987-991).
- `rpi4/services/stop_hold.py:363-371`: `drive_stop`은 구동부 정지 플래그와 모션 정지를 보낸다. `450-460`에서 drive 플래그를 가전 정지 요청보다 먼저 처리하고 fault로 끝나므로 `_do_stop` 누름으로 이어지지 않는다.
- `rpi4/services/act_executor.py:1188-1199`: 평상시 hold 정지는 가전 정지 요청, drive 정지는 누르지 않는 별도 분기다.

이는 코드 확인이다. 모든 타이밍의 물리 정지나 전원 차단을 실측했다는 뜻은 아니다. 화면은 '작은 팔로 조작할 수 없어요'와 가전 취소 직접 누름을 안내하고, 기존 정지 위치·크기를 유지한 채 누름 콜백을 비활성화한다. 실행 중 화면의 구동부 정지 버튼은 계속 활성이다. 서버 수리는 필요하지 않아 하지 않았다.

## 2. 화면별 수정

| 화면 | 변경 | 확인 경계 |
|---|---|---|
| hold_estop | 직접 취소 안내, 회색 비활성 정지, 과거 전력 확인 줄·버튼판 숨김, 중복 빨강 띠 제거 | E-STOP 제목 또는 상위 비상 띠가 있을 때. 연습 표시는 보존 |
| done | 실제 누름 성공은 파랑 체크와 '버튼 누름 완료', 가전 직접 확인 안내. 전력/상태 재조회가 확인된 실제 결과는 초록 체크 | 모의·환경 미상은 초록으로 올리지 않는다. 결과 확인값 `none`도 누름 완료로 올리지 않는다. ThinQ 성공 bool만으로 상태 확인을 만들지 않는다 |
| done(환경 미상) | 앰버 확인 필요 + 보고받은 사실까지만 표시 | 기본 done 골든은 환경 미상 fixture다. 이를 실제 성공으로 바꾸지 않고 실제 보고/전력 확인 골든 2장을 추가 |
| executing | 파랑 실행 띠, 진행 막대 대신 항상 위에 보이는 'N개 중 M번째' | 서버의 단계 수만 사용. 연습은 청록 유지 |
| done_failed | 다시 시도 시 확인 창. 취소 0회·확인 후 기존 콜백 1회 | 서버 재시도 정책·요청 내용은 변경하지 않음 |
| done_failed_practice | '연습을 마치지 못했어요' / '실제 가전은 누르지 않았어요' | 실제 가전이 켜졌을 수 있다는 경고 제거 |
| danger | 흰 본문 21, 채움 확인 버튼, 넘치면 스크롤 | 위험을 확정하는 문구는 추가하지 않음 |
| idle_estop | 실제 보이는 '풀기 안내'로 안내. 가전 줄의 동작 중을 확인 필요로 표시 | 비상 해제 전 과거 동작 상태를 현재 확정처럼 표시하지 않음 |
| hold_estop_confirm | 안내 전문이 폭 전체를 쓰고 글자 21. 절차·전원 복구 의미는 기존 그대로 | 정지 영역을 덮는 모달을 만들지 않음 |
| 큰 글씨 | 버튼판 전체 대신 현재 버튼만 크게, 긴 제안의 순서·근거는 전문 보기 | 질문과 중요 제한은 본문에 남김. 정지 버튼 위치·크기 유지 |
| hold_unconfirmed | '다시 / 정지 시도'로 어절 묶음 변경 | 표시만 변경 |

## 3. 실패 먼저 확인

직접 실행한 결과다. 개발자 보고를 인용한 수치가 아니다.

1. `test/kiosk_eval5_test.dart` 최초 10건: 수정 전 **1 통과·9 실패, 종료 1**. 비상 중 활성 정지/누름 약속, 누름 완료 구분, 근거 없는 상태 확인, 회색 실행 띠, 확인 없는 재시도, 모의 실패 경고, 잘못된 해제 안내, 위험 본문, 작은 버튼판을 잡았다. 위치·크기 보존 시험 1건은 수정 전에도 통과했다.
2. `test/kiosk_large_layout_test.dart` 추가 2건: **0 통과·2 실패, 종료 1**. 세부 보기 부재와 비상 안내 폭 약 447(요구 650 초과)를 확인한 뒤 배치를 수정했다. 이후 각각 통과했다.
3. 골든 점검 뒤 연습 실패 제목과 환경 미상 완료 띠 검사: **0 통과·2 실패, 종료 1** 확인 후 수정. 앞선 연습 실패 시험을 강화한 것이므로 위 실패 수를 고유 시험 개수로 합산하면 안 된다.
4. 기존 시험은 새 문구·확인 절차에 맞게 기대값을 고쳤다. 실제 키오스크 화면 시험에서도 비상 hold의 정지 API 0회, 실행 화면 정지 API 1회, 다시 시도 확인 전 승인 0회 추가·확인 후 기존 제안 승인 1회 추가를 확인한다.
5. 초기 실행 환경에서 패키지 캐시 불일치와 한글 임시 경로 때문에 실패한 것은 회귀 실패로 세지 않았다. ASCII 임시 경로와 설치된 캐시로 복구한 뒤 위 실패를 확인했다. 오프라인 의존성 준비로 바뀐 lockfile은 원래 내용으로 복원했다.

## 4. 직접 실행한 게이트

환경: Flutter 3.41.6 / Dart 3.11.4, Windows, 골든 글꼴은 기존 시험의 맑은 고딕. 아래 Flutter 명령은 준비된 의존성을 사용하도록 `--no-pub`를 붙였다.

| 명령 | 결과 | 종료 코드 |
|---|---|---|
| `flutter test --no-pub --exclude-tags screenshot` | **503 통과**, 골든 제외 | 0 |
| `flutter test --no-pub --tags screenshot --update-goldens` | **57 통과**, 골든 포함(기존 55 + 새 2) | 0 |
| `flutter test --no-pub --tags screenshot` | **57 통과**, 갱신 없이 최종 비교 | 0 |
| `flutter analyze --no-pub` | error 0, warning 0, 기존 info 1 | 1(info가 기본 fatal) |
| `flutter analyze --no-pub --no-fatal-infos` | error 0, warning 0, 기존 info 1 | 0 |
| 루트 repo guard + doc links (`-p no:cacheprovider`, ASCII 임시 경로) | **8 통과** | 0 |

기존 info는 `settings_overlay.dart:359`의 `activeColor` deprecated 안내다. 이번 범위의 오류·경고는 없으며 설정 화면은 수정하지 않았다. 골든 갱신 도중 이미지 열람 때문에 Windows 파일 매핑 잠금 오류가 발생한 실행 2회는 통과로 세지 않았다. 같은 PNG 바이트로 파일 핸들을 갱신하고 전체 갱신을 다시 실행해 57건이 통과했다. 최종 열람은 임시 복사본으로 했다.

서버는 읽기만 했으므로 백엔드 전체 회귀·실물 제어 시험은 실행하지 않았다.

## 5. 직접 열어 본 골든

저장 위치는 `rpi5-touchscreen-app/test/goldens/`. 총 40장(중복 제외)을 열었다. 지정된 `kiosk15_*` 21장 전부, `*_large` 10장 전부, 비상 대기 2장과 추가 변경 이미지를 포함한다.

- `kiosk15_appliance_select.png`
- `kiosk15_connection_modal.png`
- `kiosk15_danger.png`
- `kiosk15_dnd.png`
- `kiosk15_done.png`
- `kiosk15_done_failed.png`
- `kiosk15_done_failed_practice.png`
- `kiosk15_done_reported.png`
- `kiosk15_done_user_stop.png`
- `kiosk15_done_verified.png`
- `kiosk15_executing.png`
- `kiosk15_executing_practice.png`
- `kiosk15_hold.png`
- `kiosk15_hold_estop.png`
- `kiosk15_hold_unconfirmed.png`
- `kiosk15_idle.png`
- `kiosk15_idle_dnd.png`
- `kiosk15_idle_estop.png`
- `kiosk15_manual.png`
- `kiosk15_my_appliance.png`
- `kiosk15_suggestion.png`
- `connection_modal_large.png`
- `dnd_large.png`
- `done_large.png`
- `done_user_stop_large.png`
- `executing_large.png`
- `hold_large.png`
- `idle_large.png`
- `manual_large.png`
- `suggestion_large.png`
- `suggestion_long_large.png`
- `hold_estop.png`
- `hold_estop_confirm.png`
- `done.png`
- `done_power.png`
- `executing.png`
- `executing_retry.png`
- `hold_unconfirmed.png`
- `provenance_running_1.0.png`
- `provenance_running_1.6.png`

### 남은 문제와 한계

- 화면상 큰 글씨 제안의 반 줄 설명·실행 단계 가림·작은 버튼판 문제는 해소했다. `done_large`의 긴 부가 정보는 여전히 스크롤할 수 있다. 핵심 결과/직접 확인 안내와 복귀 버튼은 보인다.
- `connection_modal_large`의 긴 본문 일부가 스크롤 경계에 걸린다. 명시적인 범위 밖이므로 유지했다.
- 평소 `kiosk15_idle` 예보의 첫 두 시각 간격이 촘촘하다. 이번 비상 상태 표시 범위 밖이므로 남겼다.
- `hold_estop_confirm` 골든은 기존 fixture가 onConfirm/onCancel 콜백을 생략해 해제/취소가 비활성색이다. 실제 화면의 정상 콜백/해제 순서는 별도 위젯 시험이 확인한다. 이 PNG로 실제 버튼 활성 상태를 검증했다고 말하지 않는다.
- 서버 상태 전달이 늦을 때의 물리 정지, 실패널 밝기/반사·1.5 m/3 m 가독성·3초 구분, 실기기 화면 읽기는 미검증이다. 배포하지 않았다.

## 6. 변경 파일

- `rpi5-touchscreen-app/lib/theme/kiosk_colors.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/danger_alert_overlay.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/done_view.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/estop_banner.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/executing_view.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/hold_view.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/idle_view.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/run_frame.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/status_band.dart`
- `rpi5-touchscreen-app/lib/widgets/kiosk/suggestion_view.dart`
- `rpi5-touchscreen-app/test/done_view_test.dart`
- `rpi5-touchscreen-app/test/executing_view_test.dart`
- `rpi5-touchscreen-app/test/kiosk_design_test.dart`
- `rpi5-touchscreen-app/test/kiosk_estop_test.dart`
- `rpi5-touchscreen-app/test/kiosk_idle_estop_layout_test.dart`
- `rpi5-touchscreen-app/test/kiosk_large_layout_test.dart`
- `rpi5-touchscreen-app/test/kiosk_large_text_layout_test.dart`
- `rpi5-touchscreen-app/test/kiosk_phase_test.dart`
- `rpi5-touchscreen-app/test/kiosk_states_test.dart`
- `rpi5-touchscreen-app/test/kiosk_wording_test.dart`
- `rpi5-touchscreen-app/test/screenshot_test.dart`
- `rpi5-touchscreen-app/test/kiosk_eval5_test.dart` (신규)
- `rpi5-touchscreen-app/test/goldens/kiosk15_done_reported.png` (신규)
- `rpi5-touchscreen-app/test/goldens/kiosk15_done_verified.png` (신규)
- `docs/키오스크-디자인-규격-계획-2026-10-15.md` §5-2
- 이 devlog (신규)
- 위 목록 외 변경 골든 PNG는 `git diff --name-only`로 확인할 수 있다.
