# 2026-10-15 ThinQ 외부 검토 반영(서버·배포) — 비상정지 경계, RPi5 SDK·PAT 배포, 실물 추가 확인

외부 검토(커밋 `830d4c5` 기준, 76점)의 HIGH 두 건과, 같은 날 실제 공기청정기로 한 추가 확인. 폰·키오스크 문구 항목(M1~M4·L1~L3)은 따로 기록한다.

## H1. 비상정지 걸림인데 ThinQ 직접 조작이 보내졌다 → 막음

- 원인: 자동 실행 규칙은 걸림을 보고 막았지만(`rpi/routines/auto_rules.py`), 직접 명령(`POST /thinq/command`)과 승인 카드는 ThinQ 경로에서 걸림을 보지 않았다.
- 수리(`rpi/api/service_commands.py`):
  - 받을 때 — `_prepare`의 ThinQ 분기에서 걸림이면 `ApplianceNotReadyError` → **412** "비상정지가 걸려 있어 보내지 않았어요 — …".
  - 보내기 직전 — `_with_estop_guard`가 ThinQ 단계의 `dispatch_guard` 자리(실행기에 넘기기 전·프로필/상태 조회 뒤 전송 직전)에서 다시 본다. 걸리면 `not_dispatched`와 사유. 안쪽 확인(자동 실행 전송권)의 반환값은 그대로 돌려준다.
  - **전원 끄기도 예외로 두지 않는다** — 풀고 정지 해제를 확인한 뒤 보낸다.
- 시험 `rpi/tests/test_thinq_estop_direct.py` 5개: 걸림 중 직접 명령 412·제어 0, 전원 끄기도 412, 받은 뒤 보내기 전에 걸림 → `not_dispatched`·제어 0, 승인 카드 412·제어 0, 걸림 없으면 정상 1회.
  수정 전 코드: **4 실패·1 통과**(마지막은 정상 경로 확인). 첫 수정에서 감싼 확인이 안쪽 반환값을 버려 `test_quiet_close.py` 3개가 실패한 것을 전체 시험에서 잡아 고쳤다.

## H2. RPi5 배포에 SDK·PAT·클라이언트 ID가 없었다 → 배포 파일에 넣음

- `deploy/backend.Dockerfile`: `thinqconnect==1.0.14`(pyproject `[thinq]`와 같은 고정). 이 날짜 전 이미지는 다시 빌드해야 한다.
- `deploy/run_backend.sh`: 데이터 폴더 `thinq/`(컨테이너 `/data/thinq`, 700)를 만들고
  - 클라이언트 ID → `SIMPLELAY_THINQ_CLIENT_ID_FILE=/data/thinq/thinq_client_id`(컨테이너를 다시 만들어도 남는다)
  - `thinq/thinq_pat` 파일이 있으면(600) → `SIMPLELAY_THINQ_PAT_FILE=/data/thinq/thinq_pat`. 값은 출력하지 않고 "ThinQ PAT: 파일 있음/없음/env 파일 설정"만.
  - env 파일에 같은 설정이 있으면 덮어쓰지 않는다. ThinQ 켜기는 env 파일의 `SIMPLELAY_THINQ_MODE`.
- 시험 `rpi/tests/test_deploy_run_backend.py` +4(가짜 docker·sh): 클라이언트 ID 경로, PAT 파일 경로·값 미출력, env 파일 우선, 이미지 SDK 고정. 수정 전 **4 실패**.
- 미검증: 보드에서 이미지 재빌드·기동, RPi5 인터넷 연결 뒤 real 모드(보드에 아직 인터넷 없음). PAT는 데이터 폴더(읽기·쓰기 마운트)에 root 600으로 둔다 — 읽기 전용 별도 마운트는 아니다.

## 실물 추가 확인(10:11, 실제 공기청정기, 허브는 노트북)

| 확인 | 결과 |
|---|---|
| §5-1 이미 목표값 | 강풍(`sent`·`state_confirmed`) → 다시 강풍 = `success`·`state_only`·`already_at_target` "이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요." |
| 전원 꺼짐에서 풍량 변경(검토 M2) | **실제 클라우드가 거절** — 코드 2304 "가전 전원이 꺼져 있어 이 명령을 쓸 수 없어요", `failed`, 상태 변화 없음. 모의 클라우드처럼 '꺼진 채 바꿨어요'가 되지 않는다. 폰은 꺼짐일 때 풍량·운전 모드 조작을 내걸지 않게 따로 고친다 |
| 전원 끄기·켜기 | 둘 다 `state_confirmed`. 켠 직후 미세먼지 값은 한동안 비어 있다 |

## 시험 수

백엔드+rpi4 **3,178 통과**, 10 건너뜀(골든 없음). 같은 작업 트리의 공기질 제안 변경([기록](devlog_2026-10-15-air-suggestion.md)) 포함.
