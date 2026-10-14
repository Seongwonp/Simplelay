# 2026-10-14 밤 — 재확인 3차(외부) 남은 위험: 재시작 직후 최초 초기화가 이벤트 루프를 막아 정지가 들어오지 못하던 것 (데스크톱)

외부 3차 재확인 보고서(저장소 밖 로컬 작업 기록 폴더, `3e08d8f` 기준)는 2차의 네 건(H-RR1·H-RR2·M-RR1·M-RR2)을 모두 **닫힘**으로 판정하고,
남은 우선 위험으로 **재시작 직후 동기 DB 초기화가 서버 이벤트 루프를 막아 `/stop`이 진입하지 못하는 조건**을 들었다(보고서 부록 C 재현: 800 ms 동안 `request_stop` 미진입).
이 결함만 고쳤다. 새 기능·화면 변경은 없다(폰·키오스크 코드는 바꾸지 않았다).

> **검증 수준: 시험까지.** Uvicorn 서버 하나(이벤트 루프 하나)·요청마다 따로 연 httpx 클라이언트·임시 SQLite·모의 실행 경로로만 확인했다.
> 보드·전체 부팅·실가전·실패널·실폰은 쓰지 않았다. DB 대기는 시험이 실제 `load_setting` 경계(`suggestion_cooldowns`)에 건 문이다.
> 정지 지연 값은 **Windows 개발 PC에서 HTTP 요청 시작부터 Python `request_stop` 진입까지**다 — 모터 정지 시간·보드 성능이 아니다.
> **물리 비상정지(E-STOP)가 최종 권한이다.** 아래 표의 **시험한 조건에서만** 상한(0.5초) 안을 확인했다. 어떤 상태에서도 정지가 늦지 않는다는 뜻이 아니다.

## 1. 커밋

| 커밋 | 내용 |
|---|---|
| `9449792` | 최초 생성을 이벤트 루프 밖으로 — 제안 갱신·안부 루프의 생성을 스레드 안으로, async 라우터의 첫 생성을 `build_off_loop`로, 실행·제안 서비스·DB 싱글턴의 겹친 최초 생성을 하나로(`_built_once`), 시험 11개 |
| (이 기록) | 이 기록, 런북 §5-2·§3-8 시연 전 점검 순서, 인계 §8-15, CLAUDE.md 한 줄 |

## 2. 원인

- `rpi/main.py` 제안 갱신 루프: `await asyncio.to_thread(get_suggestion_service().create_suggestions)` — `get_suggestion_service()`는 **스레드에 넘기기 전에 루프에서** 불린다.
  lifespan을 켠 기동 직후 이 첫 호출이 제안 서비스를 만들며 DB를 읽는다(쿨다운·잠시 쉬기·조용한 시간). 그 읽기가 멈추면 Uvicorn이 연결 받기를 시작하지 못하거나(소켓 열기 전) `/stop`이 처리되지 않는다.
  안부 확인(`get_wellness_checker().check`)도 같은 모양이었다.
- async 라우터가 제안 서비스를 처음 만드는 경로: `GET /routines/runs` → `get_routine_engine()` → `get_suggestion_service()`(보고서가 짚은 경로)와 같은 모양이 루틴·시나리오·조용한 시간·자동 허용에 더 있었다(§4 표).
- 정지 전용 줄(2차 수리)은 정지 작업을 공유 풀 밖으로 뺐지만, **이벤트 루프 자체가 막히면** 정지 요청을 읽지도 못한다.

## 3. 고친 것

- **`rpi/main.py`:** 제안 갱신·안부 루프를 `asyncio.to_thread(lambda: get_…().…())`로 — 최초 생성까지 스레드 안에서. 루틴 주기 루프(`routine_tick_loop`)는 원래 lambda였다.
- **`rpi/api/deps.py` `build_off_loop(*getters)`:** 아직 없는 싱글턴만 기본 실행기에서 만든다. 이미 있으면 캐시 확인(메모리)뿐 — 평소 요청은 종전과 같고, DB가 멈춘 동안에도 이미 초기화된 서버의 루프 경로가 공유 풀을 기다리지 않는다.
  루틴 실행 기록·트리거 기록·실행 정지·지금 실행(`_routine_engine`), 시나리오 목록·시연 시나리오, `GET`·`PUT /quiet-hours`, 자동 허용(`approve-and-allow`)이 이것을 거친다.
- **`rpi/api/deps.py` `_built_once`(`get_db`·`get_service`·`get_suggestion_service`):** 최초 생성이 루프 밖 여러 스레드(제안 갱신 루프·루틴 주기·첫 요청·`def` 의존성·정지 전용 줄)에서 겹치면
  `lru_cache`는 호출마다 따로 만들어 컨트롤러·DB 연결·시나리오/루틴 배선이 둘로 갈라질 수 있었다(시험으로 재현 — §5). 함수마다 잠금 하나로 나중 호출은 먼저 시작한 생성을 기다린다.
  이미 만들어졌으면 잠금 없이 돌려준다(정지 경로의 캐시 읽기 그대로). `cache_clear`·`cache_info().currsize`는 `lru_cache`와 같은 모양이라 시험·정지 전용 줄 코드가 그대로다.
  잠금은 함수마다 따로다 — 제안 서비스가 DB 읽기에서 멈춘 동안에도 실행 서비스 생성(정지가 쓰는 것)은 기다리지 않는다(시험으로 확인).
- **`rpi/api/mapping_router.py`:** 확인 주행 시작의 `get_verify_runner()`를 lambda 안으로(지금은 메모리뿐 — 같은 모양을 남기지 않으려고).

## 4. 전수 점검 — async 경로에서 처음 불릴 수 있는 지연 생성 getter

점검: `rpi/`(시험·도구 제외)의 모든 `async def`를 AST로 뽑아, `await` 밖(lambda·안쪽 함수 제외 — `to_thread`의 **인자 안 호출은 루프에서 평가되므로 포함**)의 호출이
`lru_cache` 싱글턴 또는 지연 생성 함수(`get_routine_engine`·`get_scenario_engine`·`get_auto_rule_engine`·`get_routine_candidates`·`get_verify_runner`·`get_event_clock`·`get_link_tap`·`wire_*`)에
모듈 함수 호출로 닿는지 따라갔다. 객체 메서드 호출은 이름으로 따라가지 않았다(근사). `def` 의존성(`Depends`)은 FastAPI가 스레드에서 푼다.

| 위치 | 루프에서 처음 불릴 수 있던 것 | 판정 |
|---|---|---|
| `main.py` 제안 갱신 루프 | `get_suggestion_service`·`get_wellness_checker` | **고침**(lambda 안) |
| `GET /routines/runs`·`/routines/runs/{id}`·`POST /routines/runs/{id}/stop`·`GET /routines/log`·`POST /routines/{id}/trigger` | `get_routine_engine` → 제안 서비스 | **고침**(`build_off_loop`) |
| `GET /scenarios`·`POST /demo/scenario/{id}` | `get_scenario_engine` → 제안 서비스 | **고침** |
| `GET /quiet-hours`·`PUT /quiet-hours` | `quiet_status`·`get_quiet_hours` → 제안 서비스·조용한 시간 설정 | **고침** |
| `POST /suggestions/{id}/approve-and-allow` | `get_suggestion_service` | **고침**(자동 규칙 엔진은 원래 `to_thread`) |
| `POST /appliances/{id}/verify-pass` | `get_verify_runner`(인자 안 호출, 메모리뿐) | **고침**(lambda 안) |
| 실행·제안 서비스·DB 싱글턴의 겹친 최초 생성 | `lru_cache` 겹친 생성 | **고침**(`_built_once`) |
| `GET /health/detail` | `quiet_status` | 그대로 — `Depends(get_suggestion_service)`가 스레드에서 먼저 만든다 |
| `POST /routines/candidates/{key}/save` | `_names` → `get_routine_store` | 그대로 — 앞선 `to_thread`(초안 저장)가 먼저 만든다 |
| `GET /connections` | `_press_link` → `get_link_tap` | 그대로 — lifespan 기동 전에 만든다(파일 열기뿐) |
| `/dev/stop` 접근 검사 | `get_dev_api_state` | 그대로 — 메모리 객체 |
| `POST /stop`·`/dev/stop` 서비스 의존성 | `get_service`(없으면) | 그대로 — 2차 수리의 정지 전용 줄에서 만든다 |
| lifespan 기동 전(`yield` 앞) | `get_thinq_client`·`get_link_tap`·`get_event_clock` | 그대로 — Uvicorn이 **연결을 받기 전**이라 정지 요청이 올 수 없다(늦으면 '서버 준비 지연'으로 보인다) |
| lifespan 종료(`_shutdown_cleanup`) | `get_service`·`get_db`·개발자 세션 | 그대로 — 연결 받기를 닫은 뒤 |

## 5. 시험 — `rpi/tests/test_startup_init_stop.py`(11개)

상한 `STOP_CALL_BOUND_S` = 0.5초(2차와 같다). 수정 전 실패는 새 시험을 먼저 쓰고 구현 전 코드에서 돌려 확인했다.

| # | 재현(시험) | 수정 전 | 고친 뒤(개발 PC) |
|---|---|---|---|
| (a) | 실행 서비스만 먼저 만들고 제안 서비스 캐시는 빈 채, 위 §4의 async 라우터 8갈래 **첫 요청** → 최초 DB 읽기(`suggestion_cooldowns`) 멈춤 → 다른 클라이언트 `POST /stop` — `test_first_request_that_builds_the_suggestion_service_does_not_block_stop[8]` | 8갈래 모두 정지 진입 없음·응답 없음 | 7회: 정지 진입 **10.5~39.8 ms**, 응답 200, 읽기를 풀면 첫 요청도 4xx 이하로 끝남 |
| (b) | **lifespan을 켠** Uvicorn 기동 — 제안 갱신 루프가 제안 서비스를 처음 만들며 같은 DB 읽기에서 멈춤 → 기동 직후 `POST /stop`. 실행 서비스를 먼저 만든 경우·아직 없는 경우 — `test_stop_right_after_a_lifespan_start_…[service_built·service_cold]` | 둘 다 **연결 받기를 시작하지 못함**(연결 거부), 정지 진입 없음 | 7회: 정지 진입 **10.9~37.0 ms**, 응답 200, 읽기를 풀면 제안 서비스가 하나만 생김 |
| 겹친 생성 | 제안 서비스 생성이 DB 읽기에서 멈춘 동안 다른 스레드가 제안 서비스·실행 서비스를 요청 — `test_overlapping_first_builds_make_one_suggestion_service` | (`lru_cache`로 되돌린 변형) 제안 서비스가 **둘** 생김 | 하나, 최초 DB 읽기 한 번, 실행 서비스 생성은 기다리지 않음 |

기존 재확인 시험(`test_eval_recheck_stop.py`·`test_eval_recheck2_stop.py`·`test_auto_rule_eval4.py`·`test_quiet_close.py`·`test_pause_persist.py`·`test_quiet_hours.py`)은 고치지 않고 모두 통과했다.

## 6. 운영 절차

- [결선 운영 런북](../결선-운영-런북.md) §5-2: 시연 전 점검 순서 **허브 재시작 → 준비 확인 → 실행·정지 확인**. 준비 확인은 `/health/detail`(키 필요)이 응답하고 `ok: true`, 실물 등급이면 `actuator_ready: true`.
  `/health/detail`은 제안·실행 서비스를 의존성으로 받으므로 최초 초기화가 끝나야 응답한다(코드 확인). `/health` 200은 생존만이라 준비 판정으로 쓰지 않는다.
  **초기화가 끝나기 전에는 실행을 시작하지 않는다.** §3-8 직전 확인에도 한 줄.
- [인계](../인계-2026-10-13-데스크톱.md) §8-15.

## 7. 문서 표현 점검

발표·제출·런북·README·하드웨어 설계·protocol 문서에서 '정지는 어떤 상태에서도 지연되지 않는다'류(어떤/모든 상태·부하·경우 + 정지, 정지 + 지연 없음·늦지 않음·보장·즉시)를 grep했다.
그런 단정은 없었다(정지 보장 범위를 좁혀 쓰는 문장만 있음). 인계 §8-13의 '저장이 DB에서 멈춰도 정지가 막히지 않음'에 '개발 PC 시험 조건'을 붙였다.

## 8. 남은 위험(고치지 않음·측정하지 않음)

- **보드에서 재지 않았다.** 실제 RPi5 전원 투입·컨테이너 재시작 뒤 최초 초기화 시간과 그동안의 `/stop`은 런북 §5-2 순서로 다음 보드 날 한 번 기록한다.
- **실행 서비스 자체의 최초 생성이 DB에서 멈추면** 정지도 그 생성을 기다린다(정지할 대상이 아직 없다). 시험은 제안 서비스의 읽기만 막았다.
- lifespan 기동 전 코드(`yield` 앞)가 늦으면 서버가 연결을 늦게 받는다 — 정지 요청이 아니라 '서버 준비 지연'으로 보인다.
- AST 점검은 모듈 함수 호출만 따라갔다(객체 메서드 안의 지연 생성은 이름으로 추적하지 않음).
- SQLite 연결 하나·잠금 하나(시간 제한 없음), 일반 요청의 DB 대기, 자동 실행 '대상 무효 → 끄기' 덮기는 2차 기록 §5 그대로다.

## 9. 검증

- 백엔드+rpi4 전체 **3,108 통과·10 건너뜀·1 실패**(건너뜀은 matplotlib 없음) · 새 시험 11개. 1 실패는 문서 링크 시험 — 이 기록이 아직 추적되지 않아서다(2차 때와 같다). 문서 커밋 뒤 링크 시험을 다시 돌려 통과했다.
- 새 시험 파일은 7번 돌려 모두 통과(위 표의 범위).
- 배포 스크립트 시험은 Git 설치 폴더의 `usr/bin/sh`를 PATH에 넣고 실행했다.
- 폰·키오스크 코드는 바꾸지 않아 Flutter 시험·analyze는 돌리지 않았다.
- repo guard·문서 링크 시험 통과(커밋 전).
