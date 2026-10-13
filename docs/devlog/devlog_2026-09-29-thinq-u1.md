# 2026-09-29 — ThinQ U1-a 연결 + U1-b·U1-c(모의): 명령 계약 · 경로별 준비 상태 · 모의 어댑터 · 다가전 시나리오

심사 의견(9/29): "하드웨어 버튼뿐 아니라 소프트웨어적 가전 제어(ThinQ)도 포함하고, 특정 상황을
시나리오화해 여러 가전이 공조하는 구조를 만들라." 팀 결정([ThinQ 연동 검토](../ThinQ-연동-검토-2026-09-22.md):
공식 파이썬 SDK로 직접 ThinQ Connect)에 따라 **계약·경로·시나리오 구조를 서버에 넣었다.**

> **모의(mock)까지다.** 실제 ThinQ 클라우드 호출은 없다. 실물 클라이언트(`RealThinqClient`)는 부르면
> 항상 `NotImplementedError("… SIMPLELAY_THINQ_PAT 필요, 실물 미구현 …")`다. 모의에서 본 "상태 확인됨"은
> 실제 가전의 동작 근거가 아니며, 이력·상태에는 `execution_mode=mock`으로 남는다.
> 폰(`app/`)·키오스크 화면은 이번에 바꾸지 않았다(문구 분기 1-7 미착수).

## 1. 무엇이 모의이고, 무엇이 실물 자료를 기다리나

| 부분 | 지금 | 실물로 가려면 |
|---|---|---|
| ThinQ 클라이언트 | `MockThinqClient` (공기청정기: 전원·풍량·운전 모드 / 세탁기: 읽기 전용 + 세탁 완료 이벤트 주입) | **PAT**(connect-pat.lgthinq.com) + 보유 가전 **모델명** + U0 스파이크로 얻은 **프로필 속성 이름·허용값** |
| 동작 대응표 | `rpi/services/thinq/bindings.py` 기본표 — resource·property 이름(camelCase)과 허용값은 SDK 소스에서 옮긴 **추측/확인 필요** | U0에서 `async_get_device_profile` 결과로 표만 교체 |
| 선풍기(저녁 휴식) | `MockButtonController`(모의 물리 실행기, 센서 근거 없음 → 확인 근거 `reported`) | 실물 선풍기 노드 + 4축 준비 상태 |
| 상태 확인 | 조회(poll)만. 상한 `SIMPLELAY_THINQ_CONFIRM_SECONDS`(기본 3초, **추측**) | MQTT 푸시·이벤트 구독은 U2 이후. 구형 기기 5분 주기는 상한 안에 못 들어오는 것이 정상일 수 있다 |

SDK 대조 기준: **pythinqconnect 1.0.14**(`pip` 이름 `thinqconnect`, 설치하지 않음, 2026-09-28 소스 확인).
포트 `ThinqClientPort.list_devices / get_status / post_control` ↔ `ThinQApi.async_get_device_list /
async_get_device_status(device_id) / async_post_device_control(device_id, payload)`. 생성자는
`ThinQApi(session, access_token, country_code, client_id)`, 오류는 `ThinQAPIException`(코드 표
`ThinQAPIErrorCodes`). 제어 payload는 `{resource: {property: value}}`로 가정(공기청정기 자원
`operation`·`airFlow`·`airPurifierJobMode`). 포트는 동기이고, 실물 어댑터는 전용 이벤트 루프 스레드에서
SDK 코루틴을 돌리는 방식(기존 `ActClientController`와 같은 구조)으로 붙인다.

## 2. §5 충돌 8건 — 결정 표

설계 §7·§8과 노트북 작업목록 §0 제안이 기우는 쪽으로 정했다. 사용자 결정이 필요한 1·5·6은 **제안대로**
갔고, 반대 의견이 생기면 이 표를 고친다.

| # | 충돌 | 결정 | 구현 위치 |
|---|---|---|---|
| 1 | 승인 후 재해석 | **물리·ThinQ 모두 승인 고정.** 시나리오 카드는 확정 `Command`를 들고 다니고, 승인 시 정의로 다시 만든 명령과 지문을 대조 → 다르면 `ApprovalMismatchError`(409)·카드 내림·재승인. 물리 패턴 제안은 카드의 미리보기 시퀀스에 묶어, 승인 때 해석이 다르면 실행하지 않음. 미리보기가 비었던 카드(해석 실패)는 보여 준 명령이 없어 종전 동작. **ThinQ 경로 제안(패턴·환경·데모)도 카드를 만들 때 목적을 명령으로 확정해 같은 지문 경로로 승인하며, 승인 시 목적을 다시 해석해 대조한다** — 정의가 바뀌었으면 보내지 않고 재승인. 목적 해석이 안 되면 확정 명령이 없어 묶지 않는다(미리보기가 비었던 물리 카드와 같음). `execute_purpose`·`submit_purpose`가 ThinQ 가전에 승인 결속 인자(`approved_buttons`·`expected_buttons`)를 받으면 버리지 않고 대조한다 — ThinQ 명령은 버튼을 들지 않으므로 불일치(409) | `suggestions._purpose_commands`·`_approved_commands`·`_approval_options`, `service._check_approved`, `service_commands._prepare`·`_submit_thinq_purpose` |
| 2 | 결과 표시 | `/status`·SSE·`/history`에 `route`·`last_receipt`·`last_confirmation`·`last_detail`(기존 필드 유지, 하위 호환). **앱·키오스크 문구 분기는 미착수**(이번 범위에서 Flutter 제외) | `schemas.py`, `router.command_status_fields` |
| 3 | 상태 enum | 물리 `ExecutionStatus`에는 추가하지 않고, 명령 계약 `CommandStatus.UNCONFIRMED`를 쓴다. ThinQ 결과면 `/status.last_status`가 `unconfirmed`(실패 아님)일 수 있다 — 물리 결과는 종전 값 그대로 | `service_commands`, `router.command_status_fields` |
| 4 | 학습 조건 | 기존(REAL+DIRECT+성공) 유지 + **ThinQ는 `state_confirmed`일 때만 성공으로 기록**, 접수만 된 결과는 실패로 적어 습관에 안 들어감. 시나리오·승인 실행은 사용 이력에 넣지 않음(제안 수락 선호도 별도 집계는 미구현). `UsageRecord`에 열 추가는 하지 않았고, 이력(job_history)에는 옆 표 `job_history_command`로 경로·수신·확인 근거를 남긴다(옛 기록은 unknown) | `service_commands._run_thinq_step`, `persistence.save_job_command_meta` |
| 5 | 정지 의미 | ThinQ `request_stop()`은 **보내기 전 명령만 취소**(`cancelled_before_dispatch`). 이미 보낸 명령은 `sent_uncancellable`로 보고하고 확인 대기만 끊는다. **가전 운전 정지(전원 끄기)는 자동으로 보내지 않는다**(별도 승인 동작). 시나리오 남은 단계는 보내지 않음. `/stop` 응답에 `cloud_cancelled`·`cloud_uncancellable` | `thinq/controller.py`, `service._stop_command_paths`, `EmergencyStopReport` |
| 6 | 실행 락 | ThinQ job은 **전송 + 확인 대기 상한**까지만 실행 게이트를 잡는다. 상한 안에 못 보면 `unconfirmed`로 끝내고 게이트를 놓는다. 늦게 바뀐 상태는 job을 되살리지 않고 `/thinq/status/{id}` 재조회로만 보인다 | `ThinqController._execute` |
| 7 | 준비 상태 게이트 | 경로별: 물리는 기존 4축. ThinQ는 모드·클라우드 연결·계정 내 기기 존재·온라인·읽기 전용 여부, 실행 직전에 동작 지원·인자 범위. **확인 못 한 필수 조건은 조작 불가**(412). `runs_locally` 예외는 **내장 가전만**으로 좁혀 서버 구성 가전이 로컬 갠트리로 흘러가지 않게 함 | `ThinqController.readiness`, `service._require_ready`·`runs_locally`, `GET /readiness/{id}` |
| 8 | 감사 문구 | ThinQ `unconfirmed`는 "'…' 명령을 보냈지만 확인하지 못했어요. 가전을 직접 확인해 주세요.", 거절·미전송은 "'…' 명령이 실행되지 않았어요." | `service_commands._record_command_care` |

## 3. 확인 수준(수신과 확인은 별도 축)

| 상황 | status | receipt | confirmation | 사용자 말 |
|---|---|---|---|---|
| 보냈고 상한 안에 조회 값이 요청 값 | succeeded | accepted | state_confirmed | 상태 확인됨 |
| 접수 응답은 받았는데 상태를 못 봄 | unconfirmed | accepted | none | 접수됨 |
| 보내기 전부터 이미 그 값(변경을 볼 수 없음) | unconfirmed | accepted | none | 접수됨 |
| 전송 중 끊김·응답 유실 | unconfirmed | unknown | none | 접수 불명 |
| 클라우드 거절 | failed | accepted | none | 실행 안 됨 |
| 미연결 확인·정지로 전송 전 취소 | failed / stopped | not_dispatched | none | 보내지 않음 |

자동 재전송은 어떤 경우에도 없다(중복 실행). 오프라인은 **실행 전에 412**다 — 결코 "성공"으로 끝나지 않는다.

## 4. 구조

- `rpi/commands/approval.py` — `ApprovalMismatchError`·`ApprovalExpiredError`·`ApprovalInvalidError`(모두 409).
- `rpi/services/thinq/` — `client.py`(포트·오류·`RealThinqClient` 자리), `mock_client.py`, `controller.py`
  (`CommandController` 프로토콜·`ThinqController`·`StopOutcome`·`ThinqReadiness`), `bindings.py`(대응표), `config.py`.
- **왜 `ButtonSequenceController`가 아닌가:** `execute(buttons)`에 동작명을 라벨처럼 넣으면 풍량·온도처럼
  인자와 허용값이 있는 동작을 표현할 수 없다(설계 §2·§7). 그래서 옆에 `execute_command(cmd) -> CommandResult`
  프로토콜을 두고, 실행 게이트·정지·이력은 서비스의 기존 흐름을 재사용한다.
- `rpi/api/service_commands.py` — `SimpleLayService`의 믹스인. 명령 단위 실행(`submit_command`·`submit_approved`),
  실행 직전 재검사, 다단계(시나리오) 실행, 단계별 `CommandResult`, 완료 이벤트(`JobFinishedEvent`).
  한 단계라도 성공(확인)으로 끝나지 않으면 **나머지 단계는 보내지 않는다.** 다단계 job의 이력은 `job_id-1`,
  `job_id-2`처럼 단계 번호가 붙는다.
- 가전 레지스트리 — `ApplianceDef.control_path`(기본 physical)·`thinq`(기기 ID·대응표). ThinQ 가전·모의 선풍기는
  **서버 구성 가전**(`register_system`, 메모리만): 저장·편집·삭제 불가, `GET /appliances`(폰·키오스크 목록)에는
  나오지 않는다(버튼 격자 없는 가전을 기존 화면이 그리지 않게).
- `rpi/scenarios/` — 시나리오 **정의(데이터)** + 트리거 엔진. 엔진은 제안만 만든다.
  - `cook_then_air` 조리 확인 → 공기 관리: 전자레인지 물리 실행이 **REAL + L3(operation_confirmed)** 로 끝나면
    일반 제안, **MOCK 성공**이면 시연 제안(`is_demo`, 근거에 "모의 실행 … 실제 가열을 확인한 것은 아니에요").
    L1·보고만 받은 성공·UNKNOWN은 트리거가 아니다. 카드: "공기청정기 강풍으로 바꿀까요?" → 승인 ⇒ ThinQ `set_wind_strength HIGH`.
  - `evening_rest` 저녁 휴식: 공기청정기 켜기(ThinQ) + 선풍기 약풍(물리, 모의 실행기). 시연 트리거
    `POST /demo/scenario/evening_rest`로만. 브라우저 `/simulator/routine`의 독립 모의는 그대로 둔다.
  - ThinQ 준비가 안 됐으면 카드를 만들지 않는다(승인해도 412일 제안을 띄우지 않음).

## 5. API

| 경로 | 내용 |
|---|---|
| `GET /thinq/devices` | 모드·실행 환경·기기 목록·등록 가전(동작 표·준비 상태). off면 404 |
| `GET /thinq/status/{id}` | 상태 다시 조회("보냈지만 확인 못 함" 뒤) |
| `POST /thinq/command` | 직접 명령 `{appliance_id, action, args}` → job_id. 요청 자체가 승인. 422(동작·인자)·412(준비)·409(실행 중) |
| `POST /execute` | ThinQ 가전이면 등록된 목적 문장(예: "강풍으로 바꿔줘")을 명령으로 바꿔 ThinQ 경로로. 버튼 시퀀스 경로(`/execute-buttons`)는 거절 |
| `GET /readiness/{id}` | 경로별 준비 상태(physical 4축 / thinq 모드·연결·기기·온라인) |
| `GET /scenarios` · `GET /scenarios/last-run` | 시나리오 정의 · 마지막 명령 실행의 단계별 결과 |
| `POST /demo/scenario/{id}` | 시연 트리거 → 카드(실행 안 함) |
| `POST /demo/thinq/event` | `{"event": "wash_complete" \| "wash_start"}` — **mock 모드만**(real이면 409) |
| `GET /thinq/events` | 최근 모의 이벤트 |

`/suggestions` 항목에 `scenario_id`·`commands[{target_id, route, action, args, buttons, summary}]`가 붙는다.

## 6. 환경 변수

| 변수 | 값 |
|---|---|
| `SIMPLELAY_THINQ_MODE` | `off`(기본) · `mock` · `real`. 모르는 값이면 기동 실패 |
| `SIMPLELAY_THINQ_PAT` | 개인 액세스 토큰. 서버는 **있는지만** 기억하고 값은 속성·로그·DB·응답 어디에도 두지 않는다 |
| `SIMPLELAY_THINQ_COUNTRY` | 국가 코드(기본 `KR`) |
| `SIMPLELAY_THINQ_CONFIRM_SECONDS` | 상태 확인 대기 상한(기본 3, 0~60) |
| `SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER` · `SIMPLELAY_THINQ_DEVICE_WASHER` | real 모드의 ThinQ 기기 ID(없으면 그 가전을 등록하지 않음) |

## 7. 실물로 바꾸는 순서(나중에)

1. U0 스파이크(저장소 밖 스크립트): PAT로 `async_get_device_list`·`async_get_device_profile`·`async_get_device_status`
   덤프 → 보유 모델의 속성 이름·허용값·쓰기 가능 여부 표(모델명·날짜). 원문 출력은 커밋하지 않는다.
2. `bindings.py` 기본표를 그 결과로 교체(모델별로 다르면 모델 키로 나눔).
3. `RealThinqClient`를 SDK로 구현: 전용 asyncio 스레드 + aiohttp 세션, `client_id`는 설치별 UUID4를 설정 파일에 한 번 생성,
   오류 코드 → `ThinqOfflineError`/`ThinqCommandRejected`/`ThinqTransportError` 매핑, PAT는 환경 변수에서 읽어 즉시 SDK에만 넘김.
4. `SIMPLELAY_THINQ_MODE=real` + 기기 ID 환경 변수. U2(단일 제어 실기기)는 소유자 현장에서 요청 접수/상태 변경/실제 결과를 나눠 기록.

## 8. 검증

- 새 테스트 `rpi/tests/test_thinq_u1.py` **30건**: 승인 결속(대상·경로·동작·인자 변경 시 불일치), 대응표 거절,
  확인 수준 6종(상태 확인·접수됨·지연 확인·이미 같은 값·응답 유실·거절/미연결), 오프라인 준비 안 됨(서비스·API 412),
  정지(전송 전 취소·전송 후 취소 불가·전원 끄기 자동 전송 없음), 실물 자리(REAL·NotImplementedError), 설정(모르는 모드 거절·PAT 비보관),
  경로 라우팅(`/execute`→ThinQ, 버튼 시퀀스 거절, 전자레인지 물리 유지), 장치·이벤트 API·off 기본값·real 미구현 412,
  시나리오 끝까지(트리거→제안→승인→ThinQ 명령, 자동 실행 없음), 정의 변경 시 재승인, 저녁 휴식 2단계·미확인 시 다음 단계 미전송,
  물리 제안 승인 고정, PAT가 로그·이력·CSV·응답·SQLite에 없음.
- **실패 확인(변형):** `_check_approved` 무력화 → 물리 승인 고정 테스트 실패, 상태 조회를 항상 목표값으로 → 확인 수준 6건 실패,
  시나리오 지문 대조 끄기 → 재승인 테스트 실패. (테스트는 새 코드 경로를 대상으로 하므로 수정 전 코드에서는 import 단계부터 실패.)
- 기존 테스트 수정 2건: `/stop` 응답 전체 비교에 `cloud_*` 빈 목록 추가, `test_empathy`의 재해석 테스트 이름·설명을 승인 고정으로 교체(동작은 같은 시퀀스라 통과).
- 백엔드 전체: 아래 커밋 시점 수치 참조(기존 `dbus_fast` 1건 실패는 그대로, 별도 `--basetemp`로 tmp_path 권한 오류 회피).

## 9. 남은 일

- (2026-09-29 보완) ThinQ 목적 경로의 승인 결속 구멍을 막았다 — ThinQ 가전 제안은 생성 시점에 명령을 확정하고, 승인 때 다시 해석해 지문이 다르면 `ApprovalMismatchError`(409)로 보내지 않는다. 모의 어댑터 기준 검증이며 실물 호출로는 확인 전이다.
- 1-7 앱·키오스크 문구 분기(설계 §6 표) + 골든 — `last_status=unconfirmed`, `last_confirmation`을 화면이 아직 모른다.
- 제안 수락 선호도 별도 집계, `UsageRecord`의 경로·확인 열.
- 원복 제안(이전 설정 저장·사용자 변경 확인), 전자레인지 종료 지속 감지 — U3.
- 가전 운전 정지 동작을 별도 승인 동작으로 노출하는 UI.
- 사용자에게 받을 것: **PAT**, 공기청정기(우선)·세탁기 **모델명**, 앱 등록·원격 제어 활성화 여부, U0 덤프로 확인할 **동작 속성 이름·허용값**, 시연장 인터넷.
