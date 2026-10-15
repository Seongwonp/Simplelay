# api — 허브 HTTP 경로와 서비스

> 역할: RPi5 허브의 FastAPI 경로(라우터)와 그 뒤의 실행 서비스(`SimpleLayService`). 앱 조립은 [`../main.py`](../main.py).

| 파일 | 무엇 |
| --- | --- |
| [`router.py`](router.py) | 주 라우터 — 실행(`/execute*`)·상태(`/status`·SSE)·정지(`/stop`·`/stop/ack`)·제안·가전·설정·데모 경로. ThinQ·루틴 라우터를 안에 포함 |
| [`thinq_router.py`](thinq_router.py) · [`routines_router.py`](routines_router.py) | ThinQ 기기 찾기·추가·상태·명령, 루틴·자동 실행 허용 규칙 |
| [`mapping_router.py`](mapping_router.py) · [`ambient_router.py`](ambient_router.py) | 가전 추가 5단계(사진 매핑·확인 주행), 키오스크 평소 화면(인사말·날씨·연결 상태) |
| [`dev_router.py`](dev_router.py) | 개발자 API `/dev/*` — 일반 키 위에 별도 개발자 토큰. 계약은 파일 머리말 |
| [`simulator_router.py`](simulator_router.py) · [`twin_router.py`](twin_router.py) | 시뮬레이터 조작 패널, 디지털 트윈(화면 파일만 키 없이) |
| [`pairing.py`](pairing.py) | 폰 연결 5분 창 — 창 열기·승인은 같은 허브 화면(루프백)에서만 |
| [`auth.py`](auth.py) | API 키 검사(`require_api_key`) — 루프백 면제와 출처 확인. 경로 전체 적용 여부는 `rpi/tests/test_route_auth_coverage.py`가 본다 |
| [`deps.py`](deps.py) | 싱글턴 조립(서비스·제안·저장소·ThinQ·자동 실행 엔진), RPi4 사건 수신(`receive_appliance_done`) |
| [`service.py`](service.py) · [`service_commands.py`](service_commands.py) | `SimpleLayService` — job 실행·승인 대조(`_check_approved`·`submit_approved`)·정지·준비 판정. 명령 경로는 mixin으로 나뉘어 있다 |
| [`stop_lane.py`](stop_lane.py) | 정지 전용 실행 줄 — 공유 스레드 풀이 막혀도 `/stop`이 들어간다 |
| [`readiness_view.py`](readiness_view.py) | 가전 준비 상태 → 화면 표시 판정 |
| [`thinq_wiring.py`](thinq_wiring.py) · [`air_quality_wiring.py`](air_quality_wiring.py) | ThinQ 클라이언트 고르기(off·mock·fake_cloud·real), 공기질 판독 데몬 스레드 |
| [`schemas.py`](schemas.py) · [`config.py`](config.py) | 요청·응답 모델, GPIO 핀 설정 |

## 지켜야 할 것

- **실행은 job 모델:** `POST /execute`·승인은 즉시 `job_id`를 돌려주고, 완료는 `/status`의 `last_job_id`로 대조한다.
- **준비와 종료:** `SimpleLayService`는 "프로세스가 시작됨"과 "명령을 받을 준비가 됨"을 구분한다. `request_shutdown()` 뒤에는 새 실행을 거절하고, 이미 시작된 실행은 정지 요청으로 멈춘다(`main.py` `_shutdown_cleanup`).
- **새 경로:** 라우터를 붙일 때 `dependencies=[Depends(require_api_key)]`를 건다. 일부러 연 경로는 인증 범위 시험의 허용 목록에 이유와 함께 적는다.
- **이벤트 루프를 막지 않는다:** 정지·인증 경로에 동기 입출력을 넣지 않는다(정지 전용 줄·`async` 인증 — 이유는 각 파일 머리말).
