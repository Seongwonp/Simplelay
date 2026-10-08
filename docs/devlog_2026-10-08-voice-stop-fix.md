# 2026-10-08 음성 정지 수리 (인계 5차 §1~3)

폰 앱(`app/`)만 바꿨다. 시험은 가짜 인식기·가짜 허브(MockClient)이며 실기기 마이크·실제 허브로 확인한 것이 아니다. 부분 결과 대기 시간(1초)은 추측이며 실기기에서 확인 필요.

| 항목 | 수정 | 수정 전 실패를 실제 실행해 확인한 결과 |
|---|---|---|
| 1 HIGH 정지 HTTP 실패 | `ExecutionStatusNotifier.emergencyStop()`이 보냈는지(`bool`)를 돌려준다. 화면 정지 버튼은 반환값을 보지 않아 동작·문구 그대로. 음성 쪽은 true일 때만 '보냄'으로 치고, 실패면 다시 듣고 다시 말하면 다시 요청한다. 허브 주소가 없을 때도 '보냄'으로 치지 않는다 | 진짜 실행 추적기 + `/stop` 500→200 가짜 허브 시험에서 첫 실패 뒤 듣기가 꺼진 채(`listening` false) 남아 두 번째 "멈춰"가 나가지 않음 |
| 2 MEDIUM 키오스크 실행 | `/status.running`을 `HubStatus.running`·`EstopState.hubRunning`으로 받아 듣기 구간에 넣었다. 폰이 추적하지 않는 실행이면 같은 `POST /stop`. `/status` 조회 실패면 대기·실행 중 값을 지워 듣기를 끈다(비상정지 걸림 값은 그대로 유지) | 서버 running·폰 idle에서 듣지 않음(1건), hovering_stop 뒤 조회 실패에서 듣기가 남음(1건) |
| 3 LOW 듣는 중 표시 | 인식기 계약에 `onDone`(엔진 자체 종료)·`onFinal`(최종 결과)을 더했다. `onDone`을 준 세션만 엔진 `done`에서 끝내고, 홈 '말로 조작하기'는 침묵 타이머 계약 그대로. "듣는 중"은 세션이 열린 뒤에만 켜고 종료 즉시 끈 뒤 다시 연다 | 엔진 `done` 뒤에도 "듣는 중"이 남음 |
| 3 LOW 부분 인식 | 정지는 최종 결과로만 한다. 정지 말뿐인 부분 결과는 1초 동안 다른 결과가 없을 때만 정지로 본다. 세션이 끝나면 대기도 버린다 | 부분 결과 "그만" 직후 정지 요청이 나감(2건: "그만 데워줘"로 이어진 경우, 부분 결과 즉시) |

## 검증 (데스크톱, Flutter `C:\flutter\flutter\bin\flutter.bat`)

- 새 시험 6건을 먼저 넣고 수정 전 코드에서 6건 모두 실패를 확인한 뒤 수정했다. 기존 시험의 정지 카운터(`_CountingExecution`)는 반환형만 맞췄고, 1번은 카운터 없이 진짜 provider로 본다.
- `flutter analyze`: error 0·warning 0(기존 info 4).
- `flutter test --exclude-tags screenshot`: **570** 통과(골든 제외, 직전 564 + 6).
- `flutter test --tags screenshot`: **55** 통과(골든, 갱신 없음).
- 백엔드·키오스크는 변경 없음.

## 남은 것

- 실기기에서 엔진 `done`이 오는 시점, 부분→최종 결과 간격, 1초 대기가 체감상 괜찮은지 확인 필요.
- 서버 `running`은 `/status` 5초 주기로 읽는다 — 키오스크에서 시작한 실행은 최대 약 5초 뒤부터 듣는다.

## 리뷰 수리 (`06469c9` 기준 리뷰 3건)

| 항목 | 수정 | 수정 전 실패를 실제 실행해 확인한 결과 |
|---|---|---|
| MEDIUM 침묵 종료를 오류로 셈 | `error_no_match`·`error_speech_timeout`은 보통 끝남과 같이 `restartDelay` 뒤 다시 연다. 포기는 권한 거부(`error_insufficient_permissions`·`error_permission`)와 엔진 없음(초기화 실패·예외)뿐. 그 밖의 오류는 1.2초부터 두 배씩 늘려 8초 상한으로 계속 다시 연다(상한은 추측 — 실기기 확인 필요). 오류 수는 부분 결과·`done`·침묵 종료에서 0으로 | 침묵 종료 6번 뒤 다시 열기가 5번에서 멈춤(`listenCalls` 5, 기대 7), 네트워크 오류 8번 뒤 다시 열기 5번에서 멈춤(기대 9) |
| LOW 모의 BLE를 '보냄'으로 침 | `BleService.emergencyStop()`이 실제로 보냈을 때만 true(모의 연결은 false). `ExecutionStatusNotifier.emergencyStop()`은 BLE 경로에서 그 값을 돌려준다. 화면 상태·문구('정지를 요청했어요.', failed)는 그대로 | 모의 BLE에서 `emergencyStop()`이 true |
| LOW '보냄'이 듣기 구간에 묶임 | '보냄'을 실행 식별에 묶었다: 폰이 추적하는 실행의 `sequenceId`(HTTP 실행은 job_id), 아니면 `/status.job_id`(`HubStatus.jobId`·`EstopState.hubJobId`로 새로 받음), 정지 버튼 위 대기면 `'hold:' + last_job_id`. 듣기 구간 안에서 식별이 바뀌면 '보냄'을 지운다. 보내는 사이 실행이 바뀌면 새 실행에 '보냄'을 새기지 않는다. 조회 실패면 job 값도 지운다 | 폰 실행 A 음성 정지 뒤 실행 B에서 듣지 않음, 서버 job_id가 kiosk-1→kiosk-2로 바뀌어도 듣지 않음 |

- 한계: 서버만 아는 실행의 식별은 `/status` 5초 조회만큼 늦다(실행 B가 시작되고 다음 조회까지는 A의 '보냄'이 남는다). `job_id`를 주지 않는 옛 서버에서는 예전처럼 듣기 구간이 끝날 때만 지운다.
- 새 시험 5건(음성 4·실행 추적 1)을 먼저 넣고 수정 전 코드에서 5건 모두 실패를 확인한 뒤 수정했다. `ble_service_test`의 모의 정지 시험은 `completion(isFalse)`로 강화.
- `flutter analyze`: error 0·warning 0(기존 info 4).
- `flutter test --exclude-tags screenshot`: **575** 통과(골든 제외, 570 + 5).
- `flutter test --tags screenshot`: **55** 통과(골든, 갱신 없음).

## 리뷰 수리 2 (조회 한 번 실패 뒤 같은 실행)

| 항목 | 수정 | 수정 전 실패를 실제 실행해 확인한 결과 |
|---|---|---|
| LOW 조회 한 번 실패로 같은 실행에 다시 들음 | `/status` 조회가 한 번 실패하면 `hubRunning=false`라 듣기 구간이 끝난 것으로 보이고, 다음 조회에서 같은 실행이 보이면 새 구간으로 여겨 '보냄'이 지워졌다. 정지를 보낸(서버가 받은) 실행의 식별을 `_sentKey`로 따로 남기고, 구간이 다시 열려도 식별이 같으면 '보냄'을 유지한다. 식별이 다르면(새 실행) 예전처럼 다시 듣고, 식별을 모르면(null, 옛 서버) 예전처럼 새 구간으로 본다 | 키오스크 실행 kiosk-X 음성 정지 → 조회 1회 실패 → kiosk-X 다시 보임에서 마이크가 다시 열림(`listening` true, 기대 false) |

- 새 시험 1건(`조회 한 번 실패 뒤 같은 job_id가 다시 보이면 다시 듣지도 보내지도 않는다`): 같은 실행 X에서 다시 듣지 않고 `/stop`도 한 번뿐, 이어서 실패 한 번 뒤 새 실행 Y면 다시 듣고 두 번째 정지를 보낸다. 수정 전 코드에서 실패 확인 후 수정.
- 별도 LOW(동작 변경 없음, 주석만): 긴 실행·대기 동안 침묵 종료마다 세션을 다시 열며 횟수 상한이 없다. 기기에 따라 시작음 반복·배터리 소모가 있을 수 있어 **실기기에서 시작음·배터리 확인 필요**. 문제가 되면 `VoiceService.listen`에서 speech_to_text의 pauseFor·listenFor(지금은 넘기지 않음)를 정하는 쪽을 먼저 검토한다.
- `flutter analyze`: error 0·warning 0(기존 info 4).
- `flutter test --exclude-tags screenshot`: **576** 통과(골든 제외, 575 + 1).
- `flutter test --tags screenshot`: **55** 통과(골든, 갱신 없음).
