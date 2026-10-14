# 2026-10-14 밤 — HIGH 재확인 2차(외부) 수리: 공유 스레드 풀 고갈·이벤트 루프의 잠금 대기가 정지를 막던 것 · 동시 변경의 되살림 · 설정 응답의 판 어긋남 (데스크톱)

외부 2차 재확인 보고서(저장소 밖, `3fd85ee` 기준)는 H-R1을 **닫힘**, H-R2·M-R1을 **부분**으로 판정하고 새 결함 4건을 냈다 — HIGH H-RR1·H-RR2, MEDIUM M-RR1·M-RR2.
네 건을 고쳤다. 보고서 부록 B~D의 재현 순서를 저장소 시험(`rpi/tests/test_eval_recheck2_stop.py`)으로 고정하고, **수정 전 코드에서 실패하는 것을 먼저 확인**했다.
새 기능·화면 변경은 없다(폰·키오스크 코드는 바꾸지 않았다).

> **검증 수준: 시험까지.** Uvicorn 서버 하나(이벤트 루프 하나)·요청마다 따로 연 httpx 클라이언트·임시 SQLite·모의 ThinQ(규칙 시험은 공식 SDK + 로컬 모의 클라우드)로만 확인했다.
> 보드·실가전·실패널·실폰은 쓰지 않았다. DB 대기는 시험이 **실제 DB 잠금**을 잡거나 저장 함수에 건 문이다. 풀 크기는 기본값 그대로다(이 PC: AnyIO 토큰 40, asyncio 기본 실행기 16).
> 정지 지연 값은 **Windows 개발 PC에서 HTTP 요청 시작부터 Python `request_stop` 진입까지**(개발자 정지는 매니저 `emergency_stop` 진입)다 — 모터 정지 시간·보드 성능이 아니다.
> **물리 비상정지(E-STOP)가 최종 권한이다.** 이번 수리는 소프트웨어 정지를 공유 풀 고갈·DB 대기에서 떼어 놓는 보조 안전이고, 아래 표의 **시험한 조건에서만** 상한(0.5초) 안을 확인했다. 어떤 부하에서도 정지를 보장한다는 뜻이 아니다.

## 1. 커밋

| 커밋 | 내용 |
|---|---|
| `f1ad837` | 정지 전용 실행 줄(`rpi/api/stop_lane.py`)·인증 의존성 async·`/stop`·`/dev/stop`의 의존성과 정지 작업을 공유 풀 밖으로, 가전 목록·보호자 알림·루틴 저장소의 읽기를 DB 쓰기 잠금에서 분리, 루틴 켜기·전체 교체와 자동 실행 규칙 다시 허용을 저장소 원자 연산으로, 조용한 시간 응답을 저장 결과의 사본으로, 시험 17개 |
| (이 기록) | 이 기록, 1차 재확인 기록의 범위 주석, protocol.md 한 단락, 인계 §8-14, CLAUDE.md 한 줄 |

## 2. 항목별 — 재현·수정 전·고친 뒤

상한 `STOP_CALL_BOUND_S` = 0.5초(H-N2·H-R1과 같다). 각 시험은 정지 뒤에도 DB 대기가 **풀리지 않은 채**임을 확인하고, 끝나면 대기를 풀어 앞선 요청이 모두 200으로 끝나는지 본다.

| # | 재현(시험) | 수정 전 | 고친 뒤(개발 PC, 여러 번) |
|---|---|---|---|
| H-RR1 | 실제 DB 잠금을 잡고 (anyio) `GET /history`를 AnyIO 기본 토큰 수(40)만큼, (asyncio) `POST /dnd`를 기본 실행기 크기(16)만큼 보내 **모두 DB를 기다리는 것을 센 뒤** 정지 — 폰(LAN 주소로 보이게 + API 키), 키오스크(루프백), 개발자(`/dev/stop` + 개발자 토큰) — `test_stop_reaches_request_stop_while_the_shared_thread_pools_are_exhausted[5]` | 다섯 갈래 모두 3초 안에 정지 진입 없음 | 6회: anyio — 폰 **16.7~38.4 ms**·키오스크 **12.6~37.6 ms**·개발자 **15.8~23.0 ms**, asyncio — 폰 **14.4~28.4 ms**·키오스크 **16.1~34.2 ms**, 응답 200, 키 없는 LAN 정지는 그동안에도 401 |
| H-RR2 | `PUT /appliances/audit_custom`의 `save_appliance`가 멈춤(가전 목록 쓰기 잠금 쥔 채) → `GET /thinq/status/air_purifier`·`GET /thinq/devices`(async)가 목록을 읽음 → `/stop` — `test_stop_is_not_blocked_by_a_thinq_read_while_an_appliance_save_waits[2]` | 둘 다 정지 진입 없음·응답 없음(루프가 잠금을 기다림) | 6회: 상태 **15.5~38.6 ms**·목록 **13.0~35.8 ms**, 상태·목록 응답 200(저장 전 값 — 새 가전 아직 없음), 저장을 풀면 등록 200 |
| H-RR2 같은 모양 | 보호자 알림 DB 쓰기(`POST /demo/care-event`)가 알림 잠금을 쥔 채 멈춤 → 키오스크가 주기적으로 부르는 `GET /ambient`(async)가 최근 알림을 읽음 → `/stop` — `test_stop_is_not_blocked_by_the_kiosk_ambient_poll_while_a_care_event_write_waits` | 정지 진입 없음 | 6회: **13.1~37.9 ms**, `/ambient` 200 |
| 저장소 읽기 | 가전 목록·보호자 알림·루틴 저장소 — 쓰기가 DB에서 멈춘 동안 읽기 — `test_store_reads_do_not_wait_for_a_stuck_write` | 첫 검사(가전 목록)에서 대기 | 셋 다 50 ms 안, 저장 전 값 |
| M-RR1 | 단일 Uvicorn: A의 켜기(또는 전체 교체)를 루틴을 읽은 뒤·저장 앞에서 세움 → B의 삭제·편집·켜기 200 → A를 놓음 — `test_a_routine_change_does_not_overwrite_…[enable×delete·enable×edit·put×delete·put×enable]` | 넷 다 A 200 — 지운 루틴 되살아남(최종 200), 편집이 옛 이름·HIGH로 되돌아감, 교체가 끝난 켜기를 덮음 | 켜기×삭제 → A 404·최종 404, 켜기×편집 → A 200(새 이름·LOW·켜짐), 교체×삭제 → 404·최종 404, 교체×켜기 → 409·켜짐 유지 |
| M-RR1 같은 모양 | 자동 실행 규칙 다시 허용이 규칙을 읽은 뒤 다른 요청의 삭제·값 바꾸기가 끝남 — `test_re_allowing_an_auto_rule_does_not_resurrect_or_revert_…[delete·value]` | 둘 다 200 — 지운 규칙이 **켜진 채** 되살아남, 바꾼 값이 옛 값·켜짐으로 되돌아감 | 삭제 → 404·없음, 값 바꾸기 → 409·새 값·꺼짐 |
| M-RR2 | A `PUT /quiet-hours`(켜기) 저장 멈춤 → B(끄기) 메모리 적용·저장 대기 → A 저장 완료 → B 저장 실패 — `test_quiet_hours_responses_bind_the_value_to_the_save_that_wrote_it` | A 응답 `enabled=false`·`persisted=true`(DB는 `true`) | A `true`·`persisted=true`(DB `true`), B `false`·`persisted=false`·`session_only=true`, 지금 값 `false`, 재시작 뒤 `true` |
| 잠시 쉬기 계약 | 같은 교차를 `POST /dnd` → `DELETE /dnd`로 — `test_pause_responses_keep_the_same_contract_when_two_changes_cross` | **통과**(응답에 값이 없어 어긋날 것이 없다 — 재현이 아니라 계약 확인) | A `persisted=true`, B `false`·`session_only`, 재시작 뒤 A |

수정 전 실패는 새 시험을 먼저 쓰고 구현을 고치기 전 코드에서 돌려 확인했다(17개 중 16 실패, 잠시 쉬기 계약 1 통과). 기존 H-N1·H-N2·H-R1·H-R2·M-R1·결합 시험
(`test_eval_recheck_stop.py`·`test_auto_rule_eval4.py`·`test_quiet_close.py`·`test_pause_persist.py`·`test_quiet_hours.py`)은 고치지 않고 모두 통과했다.

## 3. 설계와 경계

### 정지 전용 줄(H-RR1) — `rpi/api/stop_lane.py`

- FastAPI는 `def` 의존성·라우터를 **AnyIO 기본 토큰**(프로세스 공용)에서, `asyncio.to_thread`는 루프의 **기본 실행기**에서 돌린다. 1차 수리는 DB를 쓰는 라우터를 이 두 풀로
  옮겼으므로, DB가 멈추면 그 요청들이 두 풀을 채운다. 정지는 (1) 인증 `require_api_key`(def) (2) 서비스 의존성 `get_service`(def) (3) 정지 작업(`to_thread`)에서 그 풀이 필요했다.
- 고친 것: `require_api_key`를 **async**로(헤더·환경 변수만 보는 메모리 일 — 모든 라우터에 적용, 동작은 같다). `/stop`의 서비스 의존성은 async `_stop_service`
  (캐시가 차 있으면 메모리 읽기, `dependency_overrides`는 그대로 따른다, 아직 없으면 정지 전용 실행기에서 만든다). 정지 작업 넷(실행 정지·개발자 세션·자동 실행 규칙·루틴)은
  **정지 전용 실행기**(`STOP_LANE_WORKERS` = 6)에서. `/dev/stop`도 async 접근 검사(`require_dev_stop_access` — 같은 검사, 토큰·빈도 제한 그대로) + 전용 실행기.
- 키오스크 정지는 같은 `POST /stop`(루프백)이라 같이 고쳐졌다. 시험은 키오스크 앱이 아니라 같은 요청을 보내는 httpx로 했다.
- **토큰 수를 늘리지 않았다.** 일반 DB 요청의 동시성 제한(세마포어로 빠른 503)도 검토했지만 넣지 않았다 — 정지는 이제 그 풀을 쓰지 않고, 일반 요청에 503을 새로 내면 폰·키오스크의
  재시도·오류 표시가 바뀐다(새 동작). DB가 멈춘 동안 일반 요청(`/history`·`/dnd`·`/status`의 일부)이 기다리는 것은 그대로다(§5).

### 이벤트 루프에서 DB 대기 잠금을 읽던 것(H-RR2)

- `ApplianceRegistry`: 쓰기 잠금(판 번호 검사 + DB 쓰기 + 메모리 교체, DB를 기다리는 동안 쥔다)과 **메모리 잠금**(읽기·교체 순간만)을 나눴다. 읽기(`get`·`list`·`list_all`·
  `system_appliances`)는 메모리 잠금만 — async 라우터가 루프에서 읽어도 DB를 기다리지 않는다. **DB 먼저 규칙은 그대로**: 메모리는 DB가 성공한 뒤에 바꾸므로 저장 중 읽기는 저장 전 값,
  DB가 실패하면 메모리도 그대로. 판 번호 충돌 검사는 쓰기 잠금 안 그대로(409 계약 유지, 기존 판 번호 시험 통과).
- `CareEventStore`: 기록(DB 쓰기·번호)은 쓰기 잠금, 최근 목록(`recent`)은 메모리 링 잠금만. DB가 성공한 뒤에만 링에 넣는다.
- `RoutineStore`: 읽기는 잠금 없는 불변 사본(통째로 교체), 쓰기는 쓰기 잠금 안에서 DB 먼저.
- ThinQ 라우터 코드는 바꾸지 않았다 — 읽는 쪽 잠금이 DB를 기다리지 않게 된 것으로 루프 경로가 없어졌다.

### 읽은 뒤 저장하는 변경(M-RR1)

- `RoutineStore.update(id, change)`: 쓰기 잠금 안에서 **최신** 루틴을 읽어 바꾸고 저장한다(없으면 404). 켜기는 이것으로 `enabled`·`updated_at`만 바꾼다.
- `RoutineStore.replace(routine, expected)`: 전체 교체는 읽은 그 객체가 저장 순간에도 그대로일 때만(지워졌으면 404, 바뀌었으면 **409** "다른 곳에서 이 루틴이 바뀌었어요 — 목록을 새로 고친 뒤 다시 저장해 주세요").
  루틴에는 판 번호가 없어 **객체 동일성**(같은 프로세스의 저장소가 바꿀 때마다 새 객체로 교체)으로 대조한다. 클라이언트가 보내는 판 번호는 없다(새 API를 만들지 않았다) — 409는 서버가 읽은 뒤·쓰기 전 몇 ms 창에서만 난다.
- 자동 실행 규칙 다시 허용(`set_enabled(True)`): 철회(`_revoke`)와 같은 전송권 잠금 안에서 읽은 규칙이 그대로인지 보고 바꾼다(삭제 404·바뀜 409). 끄기·값 바꾸기·삭제는 원래 그 잠금 안의 원자 연산이었다.
- `save`(그대로 덮기)는 새 루틴 만들기·초안 저장(새 ID)에만 쓴다.

### 설정 응답의 판(M-RR2)

- `SnapshotSetting.persist_report(version)`: 결과와 함께 **그 결과가 가리키는 사본·판**(이 호출이 쓴 것, 이미 쓰여 있음을 확인한 것, 쓰려다 실패한 것)을 돌려준다.
- `PUT /quiet-hours` 응답은 그 사본으로 상태를 만든다. 저장을 기다리는 사이 다른 요청이 바꿨으면 응답 값은 지금 값과 다를 수 있다 — 그 대신 값과 `persisted`가 같은 판을 말한다.
  지금 값은 `GET /quiet-hours`(protocol.md에 적었다).
- 잠시 쉬기(`/dnd`)는 응답에 값이 없어 같은 어긋남이 없다. `persisted`는 '이 요청의 변경이 저장된 판에 들어갔는가'만 말한다(시험으로 확인, 코드 그대로).

## 4. 전수 점검 — async 라우터가 루프에서 부르는 동기 호출과 읽은 뒤 저장하는 모양

점검: `rpi/api`·`rpi/main.py`의 모든 `async def` 라우터를 AST로 뽑아 `await` 밖의 호출을 나열하고, 그 호출이 잡는 잠금이 **DB·네트워크를 기다리는 동안 쥐어지는지**까지 따라갔다.
범위는 이 점검 시점의 라우터 본문이다(의존성은 스레드에서 풀린다).

| 라우터 | 루프에서 읽는 것 | 판정 |
|---|---|---|
| `GET /thinq/status/{id}`·`/thinq/devices`·`/thinq/events`·`POST`·`GET /demo/thinq/fault`·`POST /demo/thinq/event` | 가전 목록(`get`·`system_appliances`) | **고침**(가전 목록 읽기 분리) |
| `GET /ambient`(키오스크 주기 조회) | 보호자 알림 `recent`·가전 목록·서비스 상태 | **고침**(알림 기록 분리) |
| `POST /routines/candidates/{key}/save` | 루틴 목록(`_names`) | **고침**(루틴 저장소 읽기 분리) |
| `GET /readiness/{id}`·`POST /appliances/{id}/verify-pass` | 가전 목록(이미 스레드) | 그대로 |
| `/status`·SSE `/events` | 서비스 잠금(게이트 안 DB 대기 없음, 1차)·경보·자동 실행 기록(메모리 잠금) | 그대로 |
| `GET /nodes` | 노드 레지스트리(1차에서 DB 쓰기 분리) | 그대로 |
| `GET /quiet-hours`·`/health/detail`·`/wellness-pause`·`/presence*`·`/sensors`·`/alerts` | 불변 사본·메모리 | 그대로 |
| `/routines/runs*`·`/routines/log`·`/routines/{id}/trigger`·`/scenarios`·`/demo/scenario/{id}` | 루틴 엔진·실행기 기록(메모리 잠금) | 그대로 — **첫 호출의 엔진 생성은 루프에서**(남은 예외) |
| 자동 실행 규칙 라우터·`approve-and-allow` | 규칙 사본(잠금 없음)·세대(메모리) | 그대로 |

| 읽은 뒤 저장 | 판정 |
|---|---|
| `PUT /routines/{id}`·`POST /routines/{id}/enable` | **고침**(원자 연산) |
| 자동 실행 규칙 다시 허용 | **고침**(전송권 잠금 안 대조) |
| 자동 실행 규칙 끄기·값 바꾸기·삭제 | 원래 원자(`_revoke`) |
| 가전 등록·보정·삭제·사진 매핑 저장 | 판 번호 대조가 쓰기 잠금 안. `expected_revision` 없는 요청은 종전대로 덮기(구버전 클라이언트 경로 — 의도) |
| 루틴 초안 저장 | 매번 새 ID — 덮을 옛 객체 없음 |
| 자동 실행의 '대상 무효 → 끄기'(`_try_run`, 라우터 아님) | **남음** — 읽은 규칙으로 덮는다. 그 사이 지워졌으면 **꺼진 채** 되살아날 수 있다(자동 실행은 하지 않음) |

## 5. 남은 위험(고치지 않음·측정하지 않음)

- **시험한 조건만:** 두 기본 풀을 각각 채운 경우, 가전 목록·알림 기록 쓰기 하나가 멈춘 경우다. 두 풀을 동시에 채운 경우, 정지 전용 줄 자체가 찬 경우(정지 요청 여럿이 노드 브로드캐스트 상한
  `EMERGENCY_STOP_BROADCAST_SECONDS`까지 기다리는 중), 연결 수천 개 같은 HTTP 층 포화는 재지 않았다.
- **루프를 멈추는 다른 코드:** 첫 요청의 싱글턴 생성(루틴·시나리오 엔진)은 루프에서 돈다. 서비스 잠금을 오래 쥐는 코드가 생기면 정지는 그만큼 늦는다(지금 게이트는 메모리 읽기만).
- **일반 요청은 DB를 기다린다:** DB가 멈추면 `/history`·`/dnd`·`/status`의 일부 경로는 응답이 늦거나 없다. 동시성 제한(503)은 넣지 않았다(§3).
- **SQLite 연결 하나·잠금 하나(시간 제한 없음)** 는 그대로다.
- **보드에서 재지 않았다.** RPi5(4코어)의 기본 실행기는 이 PC(16)보다 작다(8 예상 — 계산값, 미확인). 보드에서 저장 실패·DB 정지를 일부러 만들지 않는다.
- 자동 실행의 '대상 무효 → 끄기' 덮기(§4 마지막 줄).

## 6. 검증

- 백엔드+rpi4 전체 **3,097 통과·10 건너뜀·1 실패**(건너뜀은 matplotlib 없음) · 새 시험 17개. 1 실패는 문서 링크 시험 — 이 기록이 아직 추적되지 않아서다(1차 때와 같다). 문서 커밋 뒤 링크 시험을 다시 돌려 통과했다.
- 배포 스크립트 시험은 Git 설치 폴더의 `usr/bin/sh`를 PATH에 넣고 실행했다. `bin/sh`(감싸는 실행 파일)를 넣으면 `test_old_server_pause_end_is_read_before_removal_and_passed_on`이 실패한다(가짜 `curl` 대신 다른 `curl`이 잡히는 것으로 추정 — 원인 미확인). `deploy/`는 바꾸지 않았고 `usr/bin/sh`로는 9개 모두 통과.
- 새 시험 파일은 6번 돌려 모두 통과(위 표의 범위).
- 폰·키오스크 코드는 바꾸지 않아 Flutter 시험·analyze는 돌리지 않았다.
- repo guard·문서 링크 시험 통과(문서 커밋 전 스테이징 상태와 커밋 뒤).

## 7. 남은 것

- **배포:** RPi5 백엔드(·RPi4 같은 이미지)를 같은 커밋으로 — [인계](../인계-2026-10-13-데스크톱.md) §8-14. 폰·키오스크 코드는 바뀌지 않았다. 옛 폰·키오스크가 새 서버에 붙어도 동작은 같다
  (루틴 교체 409는 폰 루틴 편집기의 기존 오류 처리가 서버 문장을 그대로 보인다 — 코드 확인, 위젯 시험은 더하지 않았다. 켜기 404는 종전 '없는 루틴' 404와 같은 경로).
- §5 남은 위험.
