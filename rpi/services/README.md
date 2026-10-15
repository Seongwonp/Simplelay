# rpi/services — 허브 서비스 색인

> 역할: RPi5 허브의 서비스 모듈(59개 파일, `thinq/`·`weather/` 포함). 대부분 허브 전용이고, `link_auth.py`·`demo_failure.py`·`act_client.py` 일부는 RPi4 실행기도 import한다.

각 파일 머리말(모듈 docstring)에 계약과 근거 날짜가 있다. 전체 구조는 [코드 구조](../../docs/코드-구조.md).

## RPi5↔RPi4 링크

| 파일 | 무엇 |
| --- | --- |
| `act_client.py` | RPi5 쪽 줄 단위 JSON 규약 클라이언트(실행·정지·정지 보고·비상정지 확인·리허설), 재연결 |
| `act_client_controller.py` | 위 비동기 클라이언트를 `SimpleLayService`가 쓰는 동기 컨트롤러로 잇는 다리, 기동 때 링크 키 확인 |
| `link_auth.py` | 링크 인증 — 짝 키 + 프레임마다 HMAC + 재전송 막기(**RPi4도 씀**) |
| `link_tap.py` | 오가는 프레임 탭 — 링 버퍼 + 선택 JSONL 세션 기록(트윈 재생 원본) |
| `event_clock.py` | 다른 장치 단조 시각 → 허브 시계 기준점(사건 신선도 판정) |
| `controller_factory.py` | `SIMPLELAY_ACT_MODE`(local·uart·simulator)로 컨트롤러 고르기 |
| `simulator_controller.py` | 하드웨어 없는 상주 실행기(시뮬레이터 모드) |
| `aggregate_result.py` | 묶음 결과만 받는 컨트롤러의 결과 합성 |

## 정지·제어권·안전

| 파일 | 무엇 |
| --- | --- |
| `stop_confirm.py` | 정지 확인 단계 읽기 규칙과 사람 말 문장(보냄 → 모션 보드 응답 → 멈춤 확인) |
| `stop_park.py` | 정지 대기·보관의 허브 쪽 절반(모의로만 검증) |
| `control_arbiter.py` | 기계 제어권 중재 — 일반 실행과 개발자 세션이 동시에 기계를 잡지 않게 |
| `developer_session.py` | 개발자 모드 세션·구조화 명령·모션 어댑터 계약. 제어권 반환은 `_maybe_release_locked` 한 곳 |
| `dev_real_motion.py` | 개발자 모드 실물 어댑터(RPi4 `dev_motion` 프레임 경유) |
| `rate_limit.py` | 개발자 API 요청 빈도 제한 |
| `demo_failure.py` | 리허설용 실패 주입(**RPi4도 씀**) |
| `readiness.py` | 가전이 지금 조작할 수 있는 상태인가(등록 여부와 별개) |
| `actuator.py` · `dht22.py` | 홈 스위치 GPIO 준비 상태·온습도 센서(GPIO 꺼짐이면 모의) |

## 가전·등록·기록

| 파일 | 무엇 |
| --- | --- |
| `appliance_registry.py` | 가전 정의의 단일 출처 — 내장 가전 + 폰에서 등록한 가전 |
| `panel_mapping.py` · `verify_pass.py` | 가전 추가 5단계 — 사진 → 갠트리 mm 매핑, 확인 주행(실물 미검증) |
| `appliance_done.py` | RPi4 `appliance_done`(CT 전력 + 종료음 융합) 해석·기록 |
| `history.py` · `persistence.py` · `snapshot_setting.py` | 실행 이력, SQLite 영속(`SIMPLELAY_DB_PATH`), 판정용 메모리 사본과 영속 쓰기를 나눈 설정 |
| `care_events.py` · `alert_store.py` | 보호자 알림 기록, 최근 위험 소리 알림 |
| `quiet_hours.py` · `presence.py` · `presence_state.py` | 조용한 시간, 공간 존재 상태(제안 보류 근거) |
| `connections.py` | 키오스크 연결 상태 세 가지(와이파이·누름 장치·콘센트 장치)를 사용자 말로 |
| `twin_view.py` | 디지털 트윈 화면용 읽기 전용 요약 |
| `probe_history.py` | 보드 점검 기록(선택) |

## 제안·시나리오·리허설

| 파일 | 무엇 |
| --- | --- |
| `air_quality.py` | 공기청정기 센서 공기질 → '공기가 나빠요' 제안 판정(10/15) |
| `mock_physical.py` | 시나리오용 모의 물리 가전 |
| `routine_rehearsal.py` · `parking_rehearsal.py` | 시뮬레이터 전용 루틴·정지 대기 리허설(실행기 의존 없음) |

## ThinQ (`thinq/`)

| 파일 | 무엇 |
| --- | --- |
| `controller.py` | ThinQ 실행기 — `Command` → 준비 판정·이미 목표값이면 보내지 않음 → 제어 → 상태 재조회로 확인 → `CommandResult` |
| `client.py` · `sdk_client.py` · `mock_client.py` | 클라이언트 포트, 공식 SDK 클라이언트, 모의 클라이언트 |
| `profile.py` · `profiles_sample.py` | 기기 프로필 판정(읽기·쓰기 가능한 속성과 값), 모의 샘플 |
| `bindings.py` · `discovery.py` | 가전 ID ↔ ThinQ 기기 ID·동작 대응, 계정 기기 발견·추가 보관 |
| `config.py` · `errors.py` · `wording.py` | 설정(env·저장소 밖 파일만, PAT 기록 안 함), 오류 코드 → 사람 말, 결과 문장 |

## 날씨 (`weather/`)

`kma.py`(기상청 단기예보 클라이언트) · `service.py`(캐시, 예외를 올리지 않음) · `ambient.py`(평소 화면 인사말·안내 한 줄) · `grid.py`(위경도 → 격자) · `config.py`.

## 예비 경로(옛 다중 노드 설계)

`esp_node_controller.py` · `espnow_node_controller.py` · `node_registry.py` — 가전별 ESP32 노드로 보내던 옛 경로. 현행 구성(RPi4 실행기)에서는 쓰지 않지만 시험이 남아 있다([`firmware-node/`](../../firmware-node/README.md)).
