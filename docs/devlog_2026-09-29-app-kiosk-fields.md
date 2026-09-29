# 2026-09-29 — 폰 앱·키오스크가 이번 주 서버 필드를 읽는다(결과 · ThinQ 경로 · 시나리오 카드)

9/29에 서버에 넣은 필드([결함 4건 §4](devlog_2026-09-29-defects.md), [ThinQ U1](devlog_2026-09-29-thinq-u1.md))를
화면이 전혀 읽지 않았다. 원격(UART) 실패가 `last_status=safety_stopped`로 와서 키오스크가 "실행을 멈췄어요"라고
안내하던 결함도 여기서 고쳤다. **실제 ThinQ·실제 RPi5 패널·실폰으로는 확인하지 않았다(모의 서버·위젯 테스트까지).**

필드 이름은 `rpi/api/schemas.py`(`StatusResponse`·`SuggestionResponse`·`HistoryEntryResponse`)와
`rpi/api/thinq_router.py`(`/readiness/{id}`·`/scenarios`·`/thinq/devices`·`command_payloads`)에서 옮겼고,
시뮬레이터 서버(`SIMPLELAY_THINQ_MODE=mock python -m rpi.simulator_main --port 8774`)의 실제 응답으로 다시 대조했다.

## 1. 화면이 말하는 것

공통 규칙은 두 앱에 같은 파일로 둔다: `app/lib/models/command_result.dart` · `rpi5-touchscreen-app/lib/models/command_result.dart`.

| 서버 값 | 결과 단어 | 한 문장(폰 상태 화면·음성) |
|---|---|---|
| `last_outcome=success`(물리) | 성공 | 종전 그대로(모의/실기기/미확인 3갈래) |
| `success` + `last_route=thinq` | 성공 | "명령을 보냈고 가전 상태를 확인했어요." · 모의면 "모의 ThinQ … 실제 가전은 조작하지 않았어요." |
| `stopped` | 정지됨 | "실행을 멈췄어요. 장치가 멈췄는지 확인해 주세요." |
| `safety_stop` | 안전 정지 | "눌림을 확인하지 못해 안전하게 멈췄어요. 가전을 확인해 주세요." |
| `failed` | 실패 | 물리 "실행하지 못했어요." / ThinQ "명령이 실행되지 않았어요." |
| `unconfirmed`(ThinQ) | 확인 못 함 | "명령을 보냈지만 확인하지 못했어요. 가전을 직접 확인해 주세요." · 접수 불명이면 "…받았는지 알 수 없어요(접수 불명). 다시 보내기 전에…" |

- **옛 서버(`last_outcome` 없음)** 는 종전 `last_status` 판정 그대로다(`safety_stopped` → 종전 "멈췄어요").
- 확인 수준: `state_confirmed`일 때만 "상태 확인됨". ThinQ `receipt=accepted`+확인 없음 → "접수됨", `receipt=unknown` → "접수 불명",
  `not_dispatched` → "보내지 않음", 거절 → "실행 안 됨". 물리는 `operation_confirmed`/`press_confirmed`/`reported`/`none`을 그대로 옮긴다.
- **ThinQ 확인 못 함은 실패도 성공도 아니다.** 폰은 새 국면 `ExecutionPhase.unconfirmed`(주의 색, 정지 버튼 없음 — 보낸 클라우드
  명령은 취소할 수 없다), 키오스크는 `KioskFailureReason.unconfirmed`/`receiptUnknown`(주의 색·물음표, **'다시 시도'·'버튼으로 조작' 없음** — 다시 보내면 중복 실행).
- 모의 표시는 기존 모의 표시(폰 `modeLabel` 배너, 키오스크 상단 "모의 실행 · 실제 조작 아님")를 그대로 쓴다.

### 폰 앱
- 실행 상태 화면: 끝난 실행 아래에 결과 단어 · 경로(물리 버튼/ThinQ) · 확인 수준 칩과 서버 한 줄(`last_detail`).
- 실행 기록: outcome으로 결과 문장(정지됨/안전 정지/보냈지만 확인하지 못했어요/가전 상태를 확인했어요), 둘째 줄에
  "경로 ThinQ · 확인 접수됨". ThinQ 기록·확인 못 함에는 버튼 단계와 '버튼으로 직접 조작'을 펼치지 않는다. 옛 기록(unknown)은 말하지 않는다.
- 제안 확인: `commands`가 있으면 시나리오 카드 — "시나리오 · 저녁 휴식"(`/scenarios` 이름), 서버 질문, "근거: …", 명령마다
  번호 · 서버 요약(예: "공기청정기(모의) 전원 켜기") · 경로 배지 · 준비 안 됨 이유. ThinQ 가전은 폰 가전 목록에 없어도
  '대상을 찾지 못함'으로 빠지지 않는다. 넘기기·30분 쉬기·동작 바꾸기·다시 받지 않기는 종전 조건 그대로.
- **409(승인 재검사 실패)**: 서버 detail에 '승인'이 있으면(`ApprovalMismatch/Expired/Invalid` 문장) "제안 내용이 바뀌어 다시 확인이
  필요해요" 안내 → 카드를 로컬에서 지우고 곧바로 `/suggestions` 재조회. '다른 작업 실행 중'(같은 409)은 종전 안내.
  이를 위해 `_checkStatus`가 오류 본문을 UTF-8 바이트로 푼다(FastAPI는 charset 없이 보내 한글 detail이 깨졌다).
- 준비 상태: 시나리오 명령 대상마다 `GET /readiness/{id}` — 준비 안 됐으면 실행 버튼 위(물리 제안과 같은 자리)에 이유를 말하고
  실행을 막는다. 조회 실패는 막지 않는다(서버가 412로 다시 거절). 412면 서버 문장을 그대로 보여 준다.
- 설정 › 제어 가전: `GET /thinq/devices`가 있으면 "ThinQ 가전"(모의면 "모의 연결(실제 가전 아님)") 목록과 준비 상태·이유.
- 홈 제안 줄: 시나리오는 버튼 순서 대신 명령 요약.

### 키오스크(5상태 흐름 안)
- 제안: 시나리오면 왼쪽 큰 질문(서버 문장 그대로, "[시연 데이터]" 표시 유지) + "근거: …", 위에 "시나리오 · 이름", 오른쪽 "승인하면 할 일"
  목록(24px 요약 + 경로 배지). 조작판 목록(/appliances)에 없는 ThinQ 대상도 승인할 수 있고, 준비 안 된 대상이 있으면
  '지금 실행'을 잠그고 아래 줄에 이유(빨강). 음성은 "…바꿀까요? 화면에서 지금 실행을 눌러 주세요."
- 승인 409(승인 문장) 또는 412: 실패 화면('다시 시도')으로 보내지 않고 처음 화면 + 같은 문장 스낵바·음성, 즉시 재조회.
- 완료: `last_outcome`으로 이유를 가른다 — **원격 실패는 더 이상 "실행을 멈췄어요"가 아니다**(결함 §4 후속). 성공/실패 아래에
  "ThinQ · 상태 확인됨"처럼 경로·확인 수준, 실패면 서버 한 줄. ThinQ 성공 제목은 "가전 상태를 확인했어요".
- `KioskApiService._ensureOk`가 `KioskApiException(statusCode, detail)`을 던진다(기존 호출부는 `catch (_)`라 동작 같음).

## 2. 서버에 없어서 하지 않은 것

- **`/appliances`에는 `control_path`가 없다**(`ApplianceResponse`에 필드 없음). ThinQ·모의 선풍기는 서버 구성 가전이라
  `/appliances`에 나오지 않는다(U1 로그 §4). 그래서 물리 가전 목록에 경로 배지를 붙이지 않았고(전부 물리), ThinQ 가전은
  폰 설정에서 `/thinq/devices`로 따로 보여 준다. 키오스크 가전 선택(수동 버튼 조작)에는 ThinQ 가전을 넣지 않았다 — 누를 버튼판이 없다.
- 제안 응답에는 시나리오 **이름**이 없다 → `/scenarios`로 받는다(실패하면 이름 없이 질문만).
- `/scenarios/last-run`(단계별 결과)은 화면에 쓰지 않았다. 다단계 시나리오의 결과는 `/status`의 마지막 단계 기준으로만 보인다.
- 폰 SSE는 원래 쓰지 않는다. 키오스크 SSE는 status 이벤트를 폴링 트리거로만 쓰므로 필드 파싱은 `/status` 한 곳이다.

## 3. 검증

- 폰 `flutter analyze`: error·warning 0(기존 info 5). 비골든 **423 통과**(`--exclude-tags screenshot`, 직전 404 + 새 19).
- 키오스크 `flutter analyze`: error·warning 0(기존 info 1). 비골든 **153 통과**(직전 145 + 새 8).
- 새 테스트: 폰 `test/models/command_result_test.dart`(7) · `test/providers/thinq_result_test.dart`(6) ·
  `test/screens/scenario_suggestion_test.dart`(4, 409 경로 포함) · `test/screens/thinq_result_screens_test.dart`(2),
  키오스크 `test/kiosk_phase_test.dart` 끝 8건(원격 실패 문구·안전 정지·시나리오 카드·준비 안 됨·409·확인 못 함·접수 불명·모의 상태 확인).
- **실패 확인(변형):** 폰 `isApprovalChanged`를 false로 → 409 테스트 실패. 키오스크 완료 판정에서 `last_outcome`을 빼면
  원격 실패·안전 정지 2건 실패. 확인 후 원복.
- **골든:** 이 PC에서는 비교 불가 — 폰·키오스크 `screenshot_test.dart`의 setUpAll이 `C:\flutter\flutter\bin\cache\...materialicons-regular.otf`
  (데스크톱 SDK 경로 고정)를 열다 실패한다. 경로가 고정되지 않은 학습·출처 골든(폰 2 · 키오스크 6)은 통과. 골든은 갱신하지 않았다 —
  기존 골든 화면은 옛 필드(경로·outcome 없음)만 쓰므로 새 칩·줄이 나오지 않는 것이 의도지만, 데스크톱에서 `--tags screenshot`로 비교가 필요하다.
- 모의 서버 대조: `/demo/scenario/evening_rest` 카드(`scenario_id`·`commands[].summary/route`), `/readiness/air_purifier`(thinq operable)·`/readiness/fan`,
  `/scenarios` 이름, `POST /thinq/command set_wind_strength HIGH` 뒤 `/status`(`last_outcome=success`·`last_route=thinq`·`last_confirmation=state_confirmed`·
  `last_execution_mode=mock`)·`/history`(`outcome`·`route`·`receipt`·`confirmation`·`detail`)가 Dart 모델이 읽는 이름과 같음을 확인. 서버는 확인 후 종료.
- 키오스크 웹 빌드(`kiosk-web/`, 미추적)는 다시 만들지 않았다 → 브라우저 `/kiosk/`로 새 카드를 눈으로 보지는 않았다.

## 4. 남은 일

1. 데스크톱(골든 폰트 경로가 맞는 PC)에서 폰·키오스크 골든 비교, 필요하면 시나리오 카드·확인 못 함 완료 화면 골든 추가.
2. 키오스크 웹 재빌드 후 `/kiosk/`에서 저녁 휴식 카드·모의 ThinQ 결과를 눈으로 확인(15.8형 1920x1080).
3. `/scenarios/last-run`으로 다단계 시나리오의 단계별 결과(2단계 중 몇 번째에서 멈췄는지) 표시.
4. `/appliances`에 `control_path`가 생기면 모델은 이미 필드를 모르는 채로 무시하므로, 그때 배지를 붙인다.
5. 실제 ThinQ(PAT·모델명) 연결 뒤 "접수됨/접수 불명" 문구를 실측 사례로 다시 본다.
