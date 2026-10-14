# 2026-10-14 밤 — HIGH 재확인(외부) 수리: 설정 저장 대기가 정지를 막던 것 · 이벤트 루프의 동기 DB 입출력 · 저장 실패를 성공으로 숨기던 것 (데스크톱)

외부 재확인 보고서(저장소 밖, `155705c` 기준)는 기존 H-N1을 **닫힘**, H-N2를 **부분**으로 판정하고 새 결함 3건을 냈다 — HIGH H-R1·H-R2, MEDIUM M-R1.
세 건 모두 고쳤다. 보고서 부록의 재현 순서를 저장소 시험(`rpi/tests/test_eval_recheck_stop.py`)으로 고정하고, **수정 전 코드에서 실패하는 것을 먼저 확인**했다.

> **범위 주석(2차 재확인 뒤):** '고쳤다'는 위 부록의 **단일 재현** 기준이다. 2차 재확인은 H-R1을 닫힘, H-R2·M-R1을 **부분**으로 판정했다 —
> 공유 스레드 풀 고갈과 다른 async 라우터의 잠금 대기가 정지를 막았고(H-RR1·H-RR2), 동시에 바꾼 설정의 응답 값과 저장 결과가 어긋났다(M-RR2).
> 이 기록의 '그 요청만 기다리고 `/stop`은 돈다'(§3)·'정지 경로는 이 잠금을 읽지 않는다'·'측정하지 않았다'·§4 '전수 점검'은 그 조건 안에서만 맞다. 수리: [2차 수리 기록](devlog_2026-10-14-eval-recheck2-fix.md).
새 기능·UI 확장은 없다. 화면 변경은 저장 실패 때 뜨는 한 문장뿐이다.

> **검증 수준: 시험까지.** 모의 클라우드·공식 SDK·메모리 선으로 이은 서명 링크·임시 SQLite·로컬 Uvicorn 서버로만 확인했다. 보드·실가전·실패널·실폰은 쓰지 않았다.
> DB 대기·실패는 시험이 `save_setting` 등에 건 문·예외다. 정지 지연 값은 **Windows 개발 PC에서 HTTP 요청 시작부터 Python `request_stop` 진입까지**다 — 모터 정지 시간·보드 성능이 아니다.

## 1. 커밋

| 커밋 | 내용 |
|---|---|
| `b70b7fc` | 판정 사본과 영속 쓰기 분리(`SnapshotSetting` — 조용한 시간·잠시 쉬기), `/dnd`·`PUT /quiet-hours`의 저장을 이벤트 루프 밖으로·응답에 `persisted`·`session_only`, 동기 입출력 라우터 27개를 `def`로, async 라우터 2곳의 가전 목록 읽기를 스레드로, 노드 레지스트리·완료 기록의 잠금 안 DB 쓰기 분리, 시험 15개 |
| `d847c70` | 저장 실패(`persisted: false`)면 "저장하지 못해 지금만 적용돼요. 허브를 다시 켜면 이전 설정으로 돌아가요." — 폰 잠시 쉬기 시트·홈 해제·조용한 시간 줄, 키오스크 방해 금지 창. 시험 폰 +6·키오스크 +6 |
| (이 기록) | 이 기록, eval4-fix 범위 주석, protocol.md 새 응답 필드, 인계 §8-13, CLAUDE.md 한 줄 |

## 2. 항목별 — 재현·수정 전·고친 뒤

정지 계측점은 API 응답이 아니라 **서비스의 로컬 컨트롤러 `request_stop` 진입**이다(서명 링크 시험은 메모리 선에 **abort 프레임이 쓰인 순간**까지). 상한 `STOP_CALL_BOUND_S` = 0.5초(H-N2와 같다).

| # | 재현(시험) | 수정 전 | 고친 뒤(개발 PC, 여러 번) |
|---|---|---|---|
| H-R1 ① | 허용·약풍 → 자동 실행을 판단 뒤·제출 직전에 세움 → `PUT /quiet-hours`가 실제 `save_setting('quiet_hours')`에서 멈춤 → 실행을 놓아 시작 게이트(서비스 잠금 안, `_begin_run` 호출 스택 확인)가 조용한 시간을 읽음 → API 키로 `/stop`. 로컬 모의 컨트롤러 / **서명된 RPi4 링크**(진짜 ActClient ⇄ ActExecutor) 두 갈래 — `test_stop_reaches_request_stop_while_a_quiet_hours_save_waits_and_the_start_guard_reads_quiet[local·signed_link]` | 두 갈래 모두 3초 안에 `request_stop` 진입 없음 | 5회: 로컬 진입 **4.6~6.8 ms**(첫 실행 51.5 ms 1회), 서명 링크 진입 **3.7~6.4 ms**·abort 송신 **4.1~7.1 ms**(mac·seq 있음). DB 저장은 멈춘 채 |
| H-R1 ② | 최종 재판정을 지난 자동 실행을 세움 → 같은 저장 멈춤 → 실행을 놓아 **전송권 확인(`commit`, ThinQ 실행기 잠금 안)**이 조용한 시간을 읽음 → `/stop` — `test_stop_is_not_held_by_a_commit_that_reads_quiet_while_its_save_waits` | 로컬 `request_stop`은 5.2 ms에 닿았지만(서비스 잠금은 비어 있었다) 그 뒤 **ThinQ 정지(보내기 전 취소 판정)가 3초 안에 돌아오지 않고 `/stop` 응답도 없음** — 서비스 잠금을 쥔 채 실행기 잠금을 기다렸다 | 5회: 로컬 진입 **3.7~4.5 ms**, ThinQ 정지 반환 **3.8~4.5 ms**, `/stop` 응답 **6~7 ms**. 조용한 시간이 메모리에 먼저 들어가 그 실행은 보내지 않음(모의 클라우드 제어 0건) |
| H-R2 | **Uvicorn 서버 하나(이벤트 루프 하나) + httpx 클라이언트 둘**: A가 `POST /dnd`(또는 `DELETE /dnd`) — `save_setting('suggestion_pause')`에서 멈춤 → B가 `/stop` — `test_stop_reaches_request_stop_on_one_uvicorn_loop_while_a_pause_save_waits[POST·DELETE]` | 둘 다 3초 안에 `request_stop` 진입 없음, `/stop` 응답 없음 | 5회: 진입 POST **11.6~13.2 ms**·DELETE **11.5~15.1 ms**, `/stop` 200(잠시 쉬기 응답은 저장을 기다리는 중), 판정은 이미 새 값 |
| H-R2 전수 | 같은 서버에서 노드 등록(`save_node`)·루틴 저장(`save_routine`)이 멈춘 동안 `/stop` — `…_while_a_node_or_routine_save_waits[node·routine]` / 정적: 아래 표의 라우터가 코루틴이 아님 — `test_routes_doing_blocking_io_do_not_run_on_the_event_loop` | 둘 다 진입 없음 / 27개가 `async def` | 4회: 진입 **21.8~41.5 ms**(노드)·**11.9~12.3 ms**(루틴) / 통과 |
| 완료 기록 | 직접 실행의 완료 기록 DB 저장이 멈춘 동안 제안 승인 게이트(서비스 잠금 안)가 읽는 `contains` — `test_completed_actions_read_does_not_wait_for_a_stuck_save` | 저장이 놓일 때까지 대기 | 50 ms 안 |
| M-R1 | `suggestion_pause` 저장에 `sqlite3.OperationalError` 주입 → `POST /dnd` / 정상 저장 뒤 `DELETE /dnd` 실패 / `PUT /quiet-hours` 실패 → 같은 DB로 재시작 — `test_pause_save_failure_…`·`test_pause_clear_save_failure_…`·`test_quiet_hours_save_failure_…`·`test_memory_only_server_…` | 200 `{"ok": true}`만(실패를 알 수 없음) | 200 `{"ok": true, "persisted": false, "session_only": true}`, 이번 세션은 적용. 재시작 뒤: 켜기 실패 → 잠시 쉬기 없음, 끄기 실패 → 앞서 저장된 끝 시각으로 다시 켜짐, 조용한 시간 → 마지막 저장값. DB 없는 구성은 `persisted: null` |
| 순서 | 조용한 시간 저장이 멈춘 동안 읽기·다음 변경, 실패한 저장 뒤 다음 변경 — `test_quiet_settings_read_does_not_wait_…`·`test_a_failed_save_is_retried_…` | `apply`·`persist` 없음(실패) | 읽기 50 ms 안·이미 새 값, 마지막 DB 값 = 가장 새 메모리 값, 실패 뒤 다음 저장이 가장 새 값을 씀 |
| 폰·키오스크 | 서버가 `persisted: false`를 돌려줌 | 새 상수가 없어 컴파일 실패. 알림 조건을 끈 변형에서 폰 2건·키오스크 1건 실패(확인 뒤 되돌림) | 폰: 잠시 쉬기 시트·조용한 시간 줄에 문장, `true`·`null`·필드 없음은 알리지 않음. 키오스크: 방해 금지 창 '1시간' 뒤 문장 |

수정 전 실패는 새 시험을 먼저 쓰고 구현 파일을 고치기 전 코드에서 돌려 확인했다(전수 점검분은 라우터·노드·완료 기록 파일만 되돌린 상태에서 4건 실패). 기존 H-N1·H-N2·결합 시험
(`test_auto_rule_eval4.py`·`test_quiet_close.py`·`test_pause_persist.py`·`test_quiet_hours.py`)은 고치지 않고 모두 통과했다.

## 3. 설계와 경계

### 판정 사본과 영속 쓰기(H-R1) — `rpi/services/snapshot_setting.py`

- **읽기:** 잠금 없음. 값은 불변 사본(조용한 시간은 읽기 전용 매핑, 잠시 쉬기는 `(끝 시각, 범위, 이어받기 값)` 튜플)이고 통째로 바꿔 끼운다.
  자동 실행 시작 게이트·전송 직전 재판정·전송권 확인·제안 승인 게이트가 이것만 읽는다.
- **바꾸기:** 짧은 메모리 잠금 안에서 지금 사본과 합치고 검사하고 교체한다(입출력 없음). 일부 값만 보낸 두 변경이 동시에 와도 서로를 잃지 않는다. **메모리에 먼저 적용한다** —
  조용한 시간·잠시 쉬기를 켜는 쪽은 응답 전에 이미 자동 실행을 막는다(안전한 쪽).
- **저장:** 별도 저장 잠금 안에서 그때의 **가장 새 사본**을 쓴다. 메모리 잠금은 사본·판 번호를 읽는 순간만 잡는다. 이미 쓴 판이면 쓰지 않는다 — 늦게 끝난 옛 쓰기가 새 값을 덮지 않는다(동시 쓰기 순서 = 메모리에 적용한 순서).
- **실패 정책:** 저장이 실패해도 메모리 값은 그대로(이번 세션만 적용). 다음 변경의 저장이 그때의 가장 새 값을 다시 쓴다. 따로 재시도 스레드는 두지 않았다.
- **재시작 정책:** 마지막으로 저장에 성공한 값으로 시작한다. 켜기 저장이 실패했으면 꺼진 채, 끄기 저장이 실패했으면 앞서 저장된 잠시 쉬기가 그 끝 시각까지 다시 켜진다. 응답의 `session_only`가 이것을 알린다.
- `to_thread`만으로는 안 됐다(보고서 지적 그대로 — `PUT /quiet-hours`는 이미 스레드였다). 문제는 판정이 **DB를 기다리는 잠금**을 읽은 것이었다.

### 이벤트 루프(H-R2)

- `POST`·`DELETE /dnd`·`PUT /quiet-hours`: 메모리 적용(입출력 없음)은 루프에서 바로, 저장은 `asyncio.to_thread`. 응답은 저장 결과를 기다려 싣는다 — 저장이 오래 멈추면 그 요청만 기다리고 `/stop`·`/status`는 돈다.
- 동기 DB·네트워크 입출력을 직접 부르던 async 라우터(아래 표)는 본문에 `await`가 없어 **`def`로 바꿨다**(FastAPI 스레드풀). 본문 동작은 같다.

### 지금 정지 경로가 기다릴 수 있는 것(범위)

- `/stop` → 서비스 잠금 → 로컬 `request_stop`. 서비스 잠금을 잡는 실행 게이트(`_begin_run`의 승인 게이트)가 읽는 것: 자동 실행 규칙(4차 H-N2, 불변 사본)·조용한 시간·잠시 쉬기(이번, 불변 사본)·완료 기록(이번, 불변 사본)·비상정지 세대(메모리 잠금).
  정지 중 노드 목록(`_stoppable_nodes`)은 노드 레지스트리 메모리 잠금만 — 노드 등록·해제의 DB 쓰기는 이제 그 잠금 밖이다.
- **남은 예외(이번 범위 밖, 고치지 않음):**
  - 제안 서비스의 `_state_lock`은 거절·미루기·생성 때 기록(`append_suggestion_event`)·쿨다운 저장·숨김 저장을 잠금 안에서 한다. 제안 승인 게이트의 철회 판정(`_withdrawal_reason`)은
    이 잠금을 잡지 않는다(코드 확인 — 조용한 시간·부재 판정·환경 사본·완료 기록만, 모두 메모리). 그래서 이 잠금은 제안 요청끼리만 줄 세우고, 그 라우터들은 이제 스레드풀이다. 경합 시험은 쓰지 않았다.
  - 가전 목록(`ApplianceRegistry`)은 등록·보정·삭제 때 잠금 안에서 DB에 먼저 쓴다(판 번호 충돌 검사와 묶여 있어 그대로 둠). 정지 경로는 이 잠금을 읽지 않는다. async 라우터 2곳의 읽기는 스레드로 옮겼다.
  - `SimpleLayDb`는 연결 하나·잠금 하나(시간 제한 없음)다. 느린 커밋 하나가 프로세스의 모든 DB 사용을 줄 세운다. `/stop` 자체는 DB를 쓰지 않는다(규칙 끄기 DB 쓰기는 뒤 스레드).
  - `asyncio.to_thread`는 루프의 기본 실행기(작은 스레드 묶음)를 같이 쓴다. DB가 오래 멈춰 그 스레드를 모두 붙잡으면 `/stop`의 스레드 작업도 줄을 선다 — **측정하지 않았다**.
  - `SeenEvents`(처리한 사건 키)는 잠금 안에서 저장하지만 실행 게이트 밖(제출 전)이다.
  - 서버 종료(`lifespan`)의 비상정지·첫 요청의 지연 생성(캐시 빈 상태)은 루프에서 돈다.

## 4. 동기 입출력 라우터 전수 점검(`rpi/api`·`rpi/main.py`)

점검: 모든 `async def` 라우터를 AST로 뽑아 `await` 여부를 보고, 본문이 부르는 동기 함수를 DB·파일·네트워크·잠금까지 따라갔다.

| 고친 것 | 라우터 | 막던 것 |
|---|---|---|
| 메모리 적용 + 저장 스레드 | `POST`·`DELETE /dnd`, `PUT /quiet-hours` | 잠시 쉬기·조용한 시간 DB 쓰기 |
| `def`로 | `POST /demo/care-event` · `POST`·`DELETE /wellness-pause` · `PUT /appliances/{id}` · `PUT …/calibration` · `DELETE /appliances/{id}` · `POST /suggestions/{id}/reject`·`/snooze` · `POST /suppressions/unmute` · `POST /demo/suggest` · `POST`·`DELETE /nodes/{id}` · `POST /routines` · `PUT`·`DELETE /routines/{id}` · `POST /routines/{id}/enable` | DB 쓰기(일부는 저장소 잠금 안) |
| `def`로 | `GET /history`·`/history.csv`·`/suppressions` | DB 읽기(최대 5,000행) |
| `def`로 | `GET /appliances` | ThinQ 가전 준비 상태 — 클라우드 조회·모의 지연을 루프에서 |
| `def`로 | `POST`·`DELETE /demo/inject-failure` | UART 모드에서 같은 루프의 코루틴 결과를 루프 스레드가 최대 5초 기다림 |
| `def`로 | `GET /care-events` · `POST /readiness/{id}` · `GET /routines`·`/routines/next`·`/routines/{id}` | DB 쓰기 동안 잡힌 저장소 잠금을 루프에서 기다림 |
| 읽기만 스레드로 | `GET /readiness/{id}`(thinq_router) · `POST /appliances/{id}/verify-pass` | 가전 목록 잠금(등록·보정 DB 쓰기 동안 잡힘) |
| 잠금 분리 | 노드 레지스트리(`register`·`unregister`) · 완료 기록(`remember`) | 메모리 잠금 안 DB 쓰기 — 정지 경로(노드 목록)·제안 승인 게이트가 읽음 |

그대로 둔 것(정지 경로를 막지 않음): `/status`·SSE(서비스 잠금 — 이제 게이트 안에 DB 대기 없음), `GET /quiet-hours`·`/health/detail`(이제 잠금 없음), 이미 `to_thread`인 라우터들, 원래 `def`인 라우터(`/hub/location`·mapping 일부).

## 5. 검증

- 백엔드+rpi4 전체 **3,081 통과·10 건너뜀**(건너뜀은 matplotlib 없음, 배포 스크립트 시험은 Git의 `sh`를 PATH에 넣고 실행) · 새 시험 15개. 이 기록을 커밋하기 전 실행에서는 새 기록 파일이 아직 추적되지 않아 문서 링크 시험 1건이 실패했고, 커밋 뒤 다시 돌려 통과했다.
- 폰 `--exclude-tags screenshot` **833 통과**(+6), 키오스크 **355 통과**(+6), `analyze` error·warning 0(기존 info 4·1). ASCII 임시 worktree(`C:\sl-test16`, 끝나고 제거).
- 골든: 화면 배치는 바뀌지 않았다(문장은 저장 실패 때만 뜨는 스낵바). 골든은 다시 돌리지 않았다.
- repo guard·문서 링크 시험 통과.

## 6. 남은 것

- **배포:** RPi5 백엔드·폰·키오스크(·RPi4 같은 이미지)를 같은 커밋으로 — [인계](../인계-2026-10-13-데스크톱.md) §8-13. 옛 폰·키오스크는 새 필드를 무시하므로 동작은 같다(저장 실패 알림만 없다).
- §3 '남은 예외' — 기본 실행기 고갈 측정, DB 연결 하나의 줄 세우기, 가전 목록 잠금 안 DB 쓰기.
- 보드에서 같은 경합을 재지 않았다(정상 저장 상태의 실측만 있다). SD 카드에 저장 실패를 일부러 만들지 않는다.
