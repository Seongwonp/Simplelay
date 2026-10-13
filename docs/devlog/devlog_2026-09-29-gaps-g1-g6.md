# 2026-09-29 — 본선 시연 gap G1·G2·G3·G6 (재시도 기록·L3 판정 배선·세탁 완료 카드·ThinQ 장애 주입)

[본선 시연 시나리오 v2](본선-시연-시나리오-v2.md) §6의 서버 쪽 gap 네 개를 닫았다.
앞선 세션이 중간 저장한 **WIP 커밋 `108bc58`**(21파일, 테스트 미확인)를 파일별로 검토해 그대로 살리고,
빠진 테스트·G3·프로토콜 문서를 더했다. **실물(RPi4 UART·전력 센서·ThinQ 클라우드)로는 하나도 확인하지 않았다.**
앱·키오스크 화면도 이번에 바꾸지 않았다 — 새 필드는 서버 응답에만 있다.

## 1. G1 — 재시도 수가 성공에서도 살아남는다

- 원인: RPi4 `result` 프레임은 집계 `retry` 하나뿐이었고, RPi5 `synthesize_execution_result`는 성공이면 모든 버튼을
  `attempts 1`로 합성했다. 그래서 시뮬레이터·UART 모드에서 `/history.retry_count`가 항상 0.
- `108bc58`에서 한 것(검토 후 유지): RPi4 `ActExecutor`가 `button_results`(버튼별 `ok`·`attempts`·실패 층·보정)를
  보내고, RPi5 `ActClient.parse_button_results`가 **엄격하게** 읽는다(이름 순서·성공 모순·중간 실패면 통째로 버리고
  종전 집계로). 버튼별 보고가 없는 옛 RPi4면 집계 `retry`를 마지막 버튼에 싣는다(어느 버튼인지는 모름 — 하한값).
  `/status`·SSE `last_retry_count`(버튼 결과가 없으면 `null`, 0으로 지어내지 않음), 트윈 `result.button_results`.
- 이번에 더한 것: `rpi4/tests/test_act_link_retry_l3.py` — 실제 `ActClient`↔`ActExecutor` 메모리 파이프로
  성공 0/1/2회, 실패(안전 정지) 0/1/2회, 정지(`stopped`) 1회, 옛 프레임, 버튼 결과 없음을 확인한다.
  `parse_button_results`를 None으로 바꾸면 G1 6건이 실패함을 확인했다.

## 2. G2 — L3 판정을 결과 프레임에 싣는다 (배선만, 실물 센서 없음)

- `108bc58`: `rpi/controller/power_operation.py`에 `SIMPLELAY_L3_MODE=off|mock|real`. off(기본)는 판정기 없음 → `null`.
  mock은 합성 전력 파형으로 **실제 판정기**(`PowerSignatureDetector`)를 돌리고 `SIMPLELAY_L3_MOCK_OUTCOME`으로
  확인/미확인을 고른다. **real은 CT·ADS1115 리더가 아직 없어 기동을 거절한다** — 있는 척하지 않는다.
  `result`에 `operation_confirmed`(true/false/null)·`operation_detail`·`operation_source`(real/mock)·`execution_mode`.
  `LayerOutcome.mock`이 참이면 통과해도 확인 수준을 `operation_confirmed`로 올리지 않는다(`reported`).
  `/history`·CSV `operation_confirmed`(SQLite는 옆 표 `job_history_operation`), `/status`·SSE `last_operation_*`.
- 시나리오 엔진: `cook_then_air` 일반 제안은 **REAL + 실물 L3 true**만. UART 컨트롤러는 실행 환경을 모르므로(UNKNOWN)
  RPi4가 보고한 `execution_mode`를 쓴다. 엔진 코드는 확인 수준(`operation_confirmed`)만 보면 되므로 문서 주석만 고쳤다.
- 테스트(같은 파일): off → null, mock 확인 → true지만 `reported`, mock 미확인 → false·안전 정지·사유, 실물 자리 판정
  true → `operation_confirmed`. 트리거: 실물 L3 true만 일반 카드, L3 없음·모의 L3·L3 false는 카드 없음, 모의 실행은
  시연 카드 유지. `SIMPLELAY_L3_MODE` 값 검사.
- `docs/protocol.md` UART `result` 절에 확장 필드 표와 읽는 규칙을 적었다.

## 3. G3 — 세탁 완료 → 제습기 제안 (모의)

- `rpi/scenarios/catalog.py`에 `wash_then_dry`: ThinQ 세탁기 `wash_complete` 이벤트 → "세탁이 끝났어요. 실내 건조를
  위해 제습기를 켤까요?", 근거 "세탁기가 세탁 완료를 알렸어요 — 빨래를 실내에 널면 습도가 올라가요 (시연: 모의 이벤트예요)",
  승인 시 ThinQ 제습기 전원 켜기. 시나리오 정의에 `event_reason`(이벤트 트리거 근거 문장)을 더했다.
- 모의 제습기 `mock-dehumidifier-01`(가전 ID `dehumidifier`, 전원만 쓰기 가능). 모의 클라이언트의 값 검사를 기기별로
  나눴다. **속성 이름 `operation.dehumidifierOperationMode`는 추측**(공기청정기와 같은 모양). 가전 종류 목록(폰과
  공유하는 계약)에 제습기가 없어 `other`로 두었다 — 서버 구성 가전이라 `GET /appliances`에는 안 나온다.
- ThinQ off면 제습기가 등록되지 않아 카드 없음·에러 없음. 제습기가 오프라인이어도 카드 없음.
- **같이 고친 결함:** 시나리오 엔진은 제안 서비스가 처음 만들어질 때 ThinQ 이벤트를 구독한다. 서버를 막 띄우고
  첫 요청이 `/demo/thinq/event`면 구독 전이라 카드가 **조용히** 안 생겼다(테스트에서 재현). 이벤트 주입 전에 엔진을
  먼저 만든다.

## 4. G6 — 모의 ThinQ 장애 주입 API

- `108bc58`의 `POST /demo/thinq/fault {"device_id","mode","latency_ms"}` / `GET /demo/thinq/fault`를 검토하고 테스트를 붙였다.
  `device_id`는 ThinQ 기기 ID나 가전 ID. `normal`로 걷어 낼 때까지 유지된다.
  - offline → 준비 상태 `disconnected`, 명령 412(보내지 않음)
  - unconfirmed → `last_status unconfirmed`, `receipt accepted`, `confirmation none`(접수됨, 실패 아님)
  - lost → `receipt unknown`(접수 불명). 가전 쪽 상태는 바뀐다. 자동 재전송 없음
  - latency_ms → 기기별 조회·전송 지연(0~30000)
- ThinQ off면 404, real이면 409(mock 전용). 모르는 기기 404, 모르는 모드·범위 밖 지연 422.

## 5. 검증

- 새 테스트: `rpi4/tests/test_act_link_retry_l3.py` 19건, `rpi/tests/test_thinq_g3_g6.py` 14건. `test_thinq_u1.py`의
  모의 기기 목록 기대값에 제습기를 더했다.
- 백엔드 전체 pytest **1,843 통과, 1 실패** — 실패는 기존 `test_dbus_native.py`(이 PC에 `dbus_fast` 없음)로 이번 변경과 무관.
- `node --test rpi/tests/*.test.cjs` 22 통과.
- 시뮬레이터(`SIMPLELAY_THINQ_MODE=mock`, `--port 8776`) 실측(HTTP 응답만):
  - 실패 주입 1회 후 "즉석밥 데워줘" → `/status` `last_retry_count 1`, `/history` `retry_count 1`(즉석밥 attempts 2),
    CSV `즉석밥:ok:2 시작:ok:1`, 트윈 `result.button_results`에 보정 1건.
  - `wash_complete` → `wash_then_dry` 카드 → 승인 → `state_confirmed`, 제습기 `POWER_ON`.
  - fault offline → readiness `disconnected`·명령 412, unconfirmed → accepted/none, lost → unknown/none, normal로 해제.

## 6. 확인하지 못한 것 · 남은 일

- 폰·키오스크 화면: `last_retry_count`·`last_operation_*`·`operation_confirmed`·세탁 완료 카드를 **읽지 않는다**(Flutter 미반영).
  폰 재시도 배지는 기존 `/history.retry_count`를 읽으므로 뜰 것으로 예상하지만 눈으로 보지 않았다.
- RPi4 실기기 UART로 새 `result` 필드 왕복 미확인. RPi4를 옛 코드로 두면 집계 `retry`만 온다(여전히 마지막 버튼에 실림).
- L3 real: 실물 `PowerSensor`(CT 클램프 + ADS1115) 드라이버와 임계값 실측 전까지 `real`은 기동 거절. 실물 자동 트리거는 그 뒤.
- 제습기 실물 속성 이름·실물 ThinQ 이벤트 구독(`RealThinqClient`)은 G7과 함께.

다음 작업 ID: Flutter 새 필드 표시(G1 배지·L3 표시), G4(다단계 결과 표시), G5(`control_path`).
