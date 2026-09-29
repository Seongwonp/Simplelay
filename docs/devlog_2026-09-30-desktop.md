# 개발 로그 2026-09-30 — 데스크톱 마감 (노트북 인계 A·B·C·F + 감사 gap 수리)

기준: `82de83f`(노트북 인계) → 이 로그의 커밋들. 작업 중 노트북이 `da82a4c`~`a3aee0e`(문서 통합·모션 MCU 펌웨어·실모드 트윈)를 올려 그 위로 rebase 했다. 전부 **모의·브라우저 수준**이다. 실물 검증은 여전히 0건.

## 1. 노트북 커밋 11건 검증 (`f6853ef`)

데스크톱에서 전부 재실행: 백엔드 1,844(dbus_fast 테스트 포함 통과) · rpi4 128 · 폰 423 · 키오스크 153 · 패키지 5, analyze 0, 가드 통과.
골든은 노트북에서 폰트 경로 문제로 못 돌렸던 것을 이 PC에서 갱신·재비교(폰 53장·키오스크 32장) 후 이미지 확인.

## 2. U1-a 설계 대비 감사 → gap 4건

설계 문서 [U1-a 계약](ThinQ-U1a-명령-결과-승인-계약-2026-09-22.md) §5 결정 8건을 코드와 대조했다.

| # | gap | 처리 |
|---|---|---|
| 1 | ThinQ 경로 **목적** 카드(패턴·환경·데모)는 승인 뒤 목적을 재해석해 보냈다 — 시나리오 카드만 명령 고정 | `45485c3` 수리: 생성 시 명령 확정(`_purpose_commands`), 승인 시 재대조, 다르면 409. `_submit_thinq_purpose`가 버리던 승인 인자를 받아 대조 |
| 2 | `test_empathy.py` 승인 테스트 이름·주석이 재해석을 암시 | 확인 결과 9/29에 이미 "묶인 시퀀스" 기준으로 고쳐져 있어 변경 없음 |
| 3 | 폰의 BLE `result` 경로와 상태 화면 기본 문구가 경로·확인 수준 없이 "버튼 조작을 마쳤어요" | (§4 참조) |
| 4 | devlog마다 변경별 red-first 근거가 1건씩뿐 | 이 로그부터 테스트별 red/green을 적는다 |

## 3. gap 1 수리 — red → green (`45485c3`)

새 테스트(`rpi/tests/test_thinq_u1.py` §8):

| 테스트 | 수정 전 | 수정 후 |
|---|---|---|
| `test_thinq_suggestion_binds_the_command_at_creation` | FAIL(카드에 commands 없음) | PASS |
| `test_thinq_suggestion_refuses_changed_purpose_definition` | FAIL(DID NOT RAISE, 전송됨) | PASS(전송 0건) |
| `test_execute_purpose_on_thinq_refuses_a_mismatching_approved_binding` | FAIL(DID NOT RAISE) | PASS |
| `test_thinq_suggestion_dispatches_once_when_unchanged` | PASS(회귀 가드, red 아님) | PASS |

백엔드 전체 1,848 통과. Copilot CLI 교차 리뷰: §7.

## 4. gap 3 + 인계 A — 폰·키오스크 새 필드 반영 (`2decafe`)

- 폰 `RpiStatusResult`/`ExecutionStatus`, 키오스크 `KioskStatus`에 `last_retry_count`·`last_operation_confirmed`·`_source`·`_detail`. 없으면 null(0/false로 지어내지 않음).
- L3 한 줄: true "가전 동작도 확인했어요"(source mock이면 "모의 판정 — 실제 동작 근거는 아니에요" 캡션), false "가전 동작은 확인하지 못했어요", null은 표시 없음. 폰 상태 화면·키오스크 완료 화면(성공·실패 양쪽), Semantics 포함. 키오스크 음성 안내에는 넣지 않았다.
- 누수 수리: 폰 BLE `result` 경로·상태 화면 기본 헤드라인·**키오스크 완료 화면**(같은 누수가 있었다)이 실행 환경 unknown에서 "버튼 조작을 마쳤어요"를 단정하던 것을 `finishedMessage` 규칙으로 통일.
- `wash_then_dry`·`dehumidifier` 카드는 코드 변경 없이 렌더(제습기는 `other` 아이콘 폴백). 재시도 배지는 이미 서버 `retry_count`를 읽고 있었다.

| 테스트 | red 근거 | green |
|---|---|---|
| `app/test/screens/operation_confirmed_test.dart` 4건 | 변경 전 `No named parameter 'operationConfirmed'` 컴파일 실패 | PASS |
| `app/test/providers/operation_result_test.dart` 3건 | 같은 컴파일 실패 | PASS |
| `execution_status_provider_test.dart` "BLE 결과는 success만 보고 … 단정하지 않는다" | `Expected: not contains '버튼 조작을 마쳤어요' / Actual: '버튼 조작을 마쳤어요.'` | PASS |
| `history_screen_test.dart` 재시도 1회 배지 | 코드 변경 없음 → `retryCount`를 0으로 고정한 변형에서 `Found 0 widgets` 실패 확인 | PASS |
| `scenario_suggestion_test.dart` wash_then_dry 카드 | `isScenario` false 변형에서 실패 확인 | PASS |
| 키오스크 `kiosk_phase_test.dart` 5건 | `No named parameter 'lastOperationConfirmed'` 컴파일 실패 | PASS |
| 키오스크 `done_view_test.dart` 2건 + 기존 1건 수정 | 기존 "성공: 버튼 조작을 마쳤어요" 테스트가 수리 직후 red(누수의 실측 증거) → `executionMode: 'real'` 명시 | PASS |

골든: 키오스크 `done.png`·`done_large.png`·`kiosk15_done.png` 3장 갱신(헤드라인·부제만 변경, 상단 "실행 환경 미확인" 배너와의 모순 해소). 폰 골든 변화 없음.

## 5. 인계 B·C — 키오스크 웹 재빌드·시연 v2 §3 모의 리허설 완주

- `kiosk-web/` 재빌드(현재 HEAD, gitignore). Git Bash에서는 `--base-href /kiosk/`가 경로로 변환되므로 `MSYS_NO_PATHCONV=1` 또는 PowerShell.
- `SIMPLELAY_THINQ_MODE=mock SIMPLELAY_PRESENCE_GATING=true python -m rpi.simulator_main --port 8765`로 §3-3 전 장면을 HTTP로 완주하고 키오스크 웹을 붙여 확인했다.

| 장면 | 결과(2026-09-30 실측, 모의) |
|---|---|
| 0 | inject 해제 ok, `act_mode simulator`, `air_purifier` readiness `operable` |
| ① | 데모 카드 승인 → `succeeded / success / mock / physical / reported`, `last_retry_count 0`, `last_operation_confirmed true(source mock)` |
| ② | 완료 직후 `cook_then_air` 카드 자동 생성 — **키오스크 웹에 카드·"ThinQ" 배지·근거 문구가 그려짐(스크린샷 확인)**. 승인 → `thinq / accepted / state_confirmed`, 공기청정기 `windStrength HIGH` |
| ③ | 실패 1회 주입 → 성공, `/status.last_retry_count 1`, `/history` `retry_count 1`, `buttons[0].attempts 2`, `operation_confirmed true` |
| ④ | `evening_rest` 승인 → `succeeded`, last-run 1단계 `state_confirmed`, 2단계 `reported` |
| ⑤-a | 8버튼 실행 1초 뒤 `/stop` → `was_running true`, `nodes_unconfirmed [fan]`, `safety_stopped / stopped` |
| ⑤-b | 실패 3회 주입 → `safety_stopped / safety_stop`, `last_retry_count 2` |
| ⑥-b | 환경 카드 + 시나리오 카드 → 부재 보고 → `/suggestions` 빈 목록(이벤트 `presence_absent` 2건) |
| G3·G6 | `wash_complete` → `wash_then_dry` 카드(제습기 전원 켜기) 승인 `state_confirmed`. `fault offline` → readiness `disconnected`, 명령 412. `normal`로 해제 |

한계: 키오스크 웹 카드는 눈으로 봤지만 Flutter 웹 캔버스라 브라우저 자동 클릭이 안 돼 승인은 HTTP로 했다. 폰 앱·트윈 화면은 이번에 붙이지 않았다. 키오스크 웹 첫 화면에서 한글 한 글자("눌")가 잠깐 빈 네모로 보였다가 다음 화면부터 정상이었다 — 키오스크는 한글 폰트를 번들하지 않아(pubspec fonts 없음) 웹에서는 브라우저가 대체 폰트를 내려받는 동안 생기는 지연으로 보인다. RPi5 실기기는 네이티브 빌드라 해당 없음이지만, 오프라인 웹 키오스크를 쓸 계획이면 한글 폰트 번들이 필요하다(미결).

## 6. 검증 표 (이 로그의 기준 수치)

| 대상 | 결과 |
|---|---|
| 백엔드 `rpi` | 1,756 통과(노트북 `a3aee0e` rebase 후 기준, G5·G10·G13 7건 포함) |
| `rpi4` | 128 통과 |
| 폰 비골든 | 441 통과 |
| 키오스크 비골든 | 168 통과 |
| 골든 | 폰 53장 비교 통과(갱신 없음) · 키오스크 32장 통과(3장 갱신) |
| analyze | error·warning 0(기존 info 폰 5·키오스크 1) |
| 가드 | 5 통과 |

## 6-1. 시연 gap G5(서버)·G10·G13

| 항목 | 내용 |
|---|---|
| G5 | `GET /appliances`가 `control_path`(physical/thinq)를 싣고, ThinQ 가전(모의 3대)도 목록에 나온다(버튼 없음, 준비 상태는 ThinQ 경로 판정에서). ThinQ off면 종전과 같다. 화면 배지·키오스크 가전 선택은 남음 |
| G10 | 부재 게이트가 켜져 있고 부재면 `/demo/scenario/{id}`가 409 "지금은 자리에 안 계셔서 제안을 만들지 않았어요"로 거절, created 이벤트 없음. 판정은 제안 서비스 `presence_absent` 하나 |
| G13 | `POST /demo/alert` — UART 경로와 같은 `DangerAlertStore.record`를 불러 `/alerts`·SSE·보호자 알림이 같이 흐른다. uart 모드 404 |

red → green: `rpi/tests/test_demo_gaps_g5_g10_g13.py` 7건을 수정 전 코드(stash)에서 실행 → **5 failed, 2 passed**(통과 2건은 "ThinQ off면 물리만"·"재실 중이면 카드 생성"의 회귀 가드), 수정 후 7 passed.

## 6-2. 시연 gap G4·G5 화면 (`app/`·`rpi5-touchscreen-app/`)

- G5: `Appliance.controlPath`(기본 physical)·`isThinq`. 폰 홈·수동 조작·설정 칩, 키오스크 가전 선택에 ThinQ 배지(시나리오 카드의 배지를 `RouteBadge`로 공용화). ThinQ면 버튼 격자·"사진으로 버튼 채우기"·BLE 폴백 없음, 음성은 기존 `/execute` 목적 경로.
- G4: `ScenarioRun`/`ScenarioRunStep` + `GET /scenarios/last-run`. 폰 상태 화면·키오스크 완료 화면이 끝난 job과 `job_id`가 같고 2단계 이상일 때만 "단계별 결과"(경로·실행 환경·확인 수준·결과)를 그린다. 문구는 기존 `confirmationLabel`·`resultWord` 재사용.

| 테스트 | red 근거 | green |
|---|---|---|
| `app/test/screens/thinq_appliance_test.dart` 4건 | `isThinq`·`controlPath`·`route_badge.dart` 없음 컴파일 실패 | PASS |
| `app/test/screens/scenario_run_steps_test.dart` 4건 | `ScenarioRun` 없음 컴파일 실패; job_id 불일치 건은 검사 제거 변형에서 실패 확인 | PASS |
| 키오스크 `thinq_appliance_test.dart` 4건 | `KioskRouteBadge`·`isThinq` 없음 | PASS |
| 키오스크 `done_view_test.dart` +2 · `kiosk_phase_test.dart` +2 | `runSteps` 인자 없음 / 2단계 흐름 `lastRunCalls == 0` 단언 실패; 불일치 건은 변형에서 확인 | PASS |

폰 441 · 키오스크 168(골든 제외), 골든 폰 53·키오스크 32 변화 없이 통과, analyze 0. 남은 것: 폰 설정의 옛 ThinQ 목록과 칩의 이중 표시 정리, `dart format`.

## 7. 교차 리뷰

Copilot CLI는 월 사용량 초과(quota)로 응답하지 않았고, 별도 검토 에이전트는 세션 한도로 중단됐다. 이번 커밋들은 데스크톱 세션이 diff를 직접 읽어 검토했다(자동 교차 리뷰 없음).

## 8. 인계 F — 문서 정리

데스크톱에서도 같은 통합을 했지만, 노트북이 먼저 `da82a4c`로 CLAUDE.md 배너 통합·개발현황 9/28~30 반영·Z축/제어기 서술 정리를 올렸다. rebase 시 충돌은 노트북 판을 택하고, 데스크톱 판에서는 이 로그 링크와 검증 수치만 얹었다.

## 9. 다음

- 하드웨어 도착 → H0~H1([jog-cli](devlog_2026-09-29-jog-cli.md) 첫날 순서).
- ThinQ 실물: PAT·가전 확보 후 `RealThinqClient`.
- 폰 앱을 시뮬레이터(LAN, API 키)에 붙여 §3을 폰 화면까지 완주.
- 폰 설정 옛 ThinQ 목록·칩 이중 표시 정리(팀 결정).
- 오프라인 웹 키오스크를 쓸 경우 한글 폰트 번들(팀 결정).
