# 로컬 보드 점검

`docs/board-probe-example.json`을 저장소 밖으로 복사하고 자리표시자를 채운다.
`SIMPLELAY_PROBE_CONFIG`는 그 JSON/TOML 파일, `SIMPLELAY_PROBE_OUT`은 저장소 밖 결과 디렉터리다
(기본 `~/simplelay-probe/`). **앱과 같은 계정·컨테이너·그룹·버스 환경**에서
`python -m rpi.tools.board_probe`를 실행한다. root 실행 성공은 앱 권한으로 인정하지 않는다.
`app_account`가 실제 실행 계정과 일치해야 앱 권한 성공으로 표시된다. 계정 전환·sudo는 도구가 하지 않는다.
POSIX에서는 환경변수 대신 유효 UID의 계정명을 비교하고 root 여부를 판정한다.
유효·실제 UID와 계정명을 함께 기록하며, Windows UID는 `unsupported`로 남기고 앱 권한 성공을 인정하지 않는다.

설정은 신뢰하는 로컬 운영자가 작성한다. `safe_read_only: true`는 호출의 부작용을 검토했다는 선언이며,
임의 D-Bus 메서드·실행 파일·파이썬 import·장치 open의 부작용을 코드로 판별하는 샌드박스가 아니다.
기본 모드에는 쓰기 명령·모션·재시작을 넣지 않는다. HTTP는 GET만 사용한다.
실행 도구는 `args`, 모듈은 `call: "import"`, 장치는 선택적으로 `call: "open_read"`를 쓴다.
최소 호출이 없으면 존재만 기록하며 호출·권한은 미측정이다. UART는 기본 모드에서 열지 않는다(DTR 리셋 방지).
D-Bus는 실행 중인 이름만 확인하고 자동 서비스 기동을 막는다. `bus`는 `system`(기본) 또는 `session`.
`dbus_service`와 `dbus_method` 모두 `path`를 지정하며, `call`은 예제의 interface/member/signature/args 구조다.
introspection 원문(XML의 실제 메서드 서명), 응답, 오류, 계정, 보드·이미지 정보는 원시 JSON에만 남긴다.
원시 응답의 Variant는 `__dbus__: "variant"`, `signature`, `value`로 보존한다.
바이트·튜플·문자열 이외 키의 딕셔너리도 타입 태그를 쓰며, 변환 불가 값은 타입과 repr로 기록한다.
배열·중첩 구조체를 재귀 변환하고, 경로·서명 등 기본 Python 값의 D-Bus 타입은 `reply_signature`와 Variant 서명으로 보존한다.
필드의 `null`은 미측정/해당 없음이다. 최소 호출 실패만으로 권한 거부 원인을 단정하지 말고 로컬 오류를 확인한다.

능동 실행은 `--active --i-understand-active`를 모두 붙인다. 설정의 `status_url`은 실행 관리 서버의 `/status`다.
`SIMPLELAY_API_KEY`를 HTTP 헤더로 전달한다. `active` 배열에는 다음 중 필요한 작업만 로컬에서 선언한다.

- `{"kind":"jog","port":"/dev/SERIAL_PLACEHOLDER","baud":115200,"dx_mm":0.2,"dy_mm":0}`
- `{"kind":"restart","unit":"SERVICE_PLACEHOLDER.service","check_id":"TARGET_CHECK_ID","recovery_timeout_s":30}`

실행 직전마다 `/status`가 명시적으로 `running=false`여야 한다. 조회 실패·필드 누락은 거절한다.
운영자는 다른 실행 주체를 멈추고 시리얼 단독 소유를 확보한 정비 시간에 실행한다(상태 조회는 실행 락이 아니다).
조그는 `SIMPLELAY_MOTION_*` 실측 설정을 그대로 사용하며 자동 홈은 하지 않는다.
재시작의 `check_id`는 재시작 대상 자체의 최소 호출을 정의한 `checks` 항목 ID여야 한다.
호출 없는 항목은 재시작 전에 거절한다. 기존 `reconnect_status_url`은 복구 판정에 사용하지 않는다.
왕복 후 status 확인까지의 시간, 재시작 요청부터 대상의 최소 호출 성공까지의 시간을 `recovery_ms`로 기록한다.
대상 호출은 제한 시간 내 재시도하며 서버 `/status`의 유휴 상태만으로 복구를 인정하지 않는다.
재시작 복구 실패는 `recovery_failed: true`와 마지막 오류를 기록한다.
실패 시 복구 성공 시간은 null이며 `elapsed_ms`와 오류를 남긴다. 조그 종료 시 stop을 보내므로 재홈이 필요할 수 있다.

결과 파일 권한은 POSIX에서 0600, 새 디렉터리는 0700이다. Windows에서는 저장 위치의 사용자 ACL을 따른다.
원시 JSON은 비공개로 보관한다. 생성된 한국어 Markdown만 공유한다. 요약은 코드의 일반 명칭과
불리언 결과·측정 시각만 투영하므로 로컬 ID·대상·오류·서명이 섞이지 않는다.
실물 기능·가산점 인정·현재 실행 readiness는 이 도구의 저장 기록만으로 판정하지 않는다.
