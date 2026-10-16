# R1 자동 재누름 정책·제출 초안 현행화 (2026-10-16)

기준: `main` `16ea5ac` 위 미커밋 작업 트리. 커밋·push·브랜치·stash 없음. CLAUDE.md와 폰·키오스크 코드는 변경하지 않았다.
**검증 수준: 메모리 링크·모의 모션·합성 L1/L2 판정 시험만. 보드 미배포, 실물 버튼·센서 검증 아님. RPi4·RPi5 같은 커밋 배포 필수.**

## 1. 정책과 적용 경로

- 버튼 정의 `behavior`: toggle / idempotent / unknown. 누락·잘못된 값은 unknown, 이름으로 추측하지 않는다.
- 내장 전자레인지: 시작·취소 toggle, 10초·30초·1분·5분 idempotent, 라면·해동·즉석밥·냉동식품 unknown. 인덕션 전원·시작·취소 toggle, 나머지 unknown. 커스텀 기존 데이터는 unknown.
- idempotent는 사용자 결정의 '자동 재누름 허용' 분류다. 시간 누적 동작은 수학적 멱등이 아니며 첫 누름을 놓친 경우 시간이 더해질 수 있다. 무해함이나 가열 안전을 보장하는 이름으로 쓰지 않는다.
- 공유 `ClosedLoopController`에서 L1 보정과 L2 재입력 양쪽을 제한한다. toggle·unknown은 첫 미확인 뒤 두 번째 누름 0회, 뒤 단계도 중단. idempotent는 기존 상한·보정·재입력 유지. 센서 예외도 미확인, 정지가 같이 들어오면 기존 정지 처리를 우선한다.
- 버튼 격자/내장·커스텀 레지스트리/API 모델/SQLite → 서비스의 대상별 실행 스냅샷 → 동기 브리지 → `execute.button_behaviors` → RPi4 실행기 → 공유 폐루프. 실행마다 새로 받아 이전 실행의 허용을 물려주지 않는다.
- `abort_reason=press_unconfirmed`를 RPi5까지 통과시켜 명령 결과·상태·이력·완료 이벤트·보호자 안내에 미확인으로 남긴다. 처음 통합 시험에서 원인 필터 누락 4건을 잡아 수정했다.
- L2 운영 센서 연결을 새로 한 것은 아니다. 모의 L2 판정기로 재입력 경계를 시험했다. MCU가 누름 전에 거절한 냉각 대기 재전송·명시적 hold 취소 누름 횟수는 변경하지 않는다.
- 옛 RPi4는 새 필드를 무시해 재누를 수 있다. 옛 RPi5는 새 원인을 무시할 수 있다. 혼합 배포를 안전 호환으로 주장하지 않는다([규약](../protocol.md)).

## 2. 실패 확인과 시험

초기 시험 8건을 먼저 작성하고 수정 전 실행: **8 실패, 종료 1**. 필드 없는 L1/L2 2건은 시작 버튼을 두 번 누르고 다음 버튼까지 가는 실제 반복(총 3회)을 잡았다. 명시적 분류 6건은 새 인자 미지원(TypeError)으로 실패했다. 이 둘을 모두 동작 재현으로 부풀리지 않는다. 공유 폐루프 수리 후 8 통과.

추가 연결 검증에서 실제 서비스→ActClientController→ActClient→ActExecutor→폐루프→기록 경로의 미확인 원인 필터 누락 **4 실패**, 수정 후 통과.
추가 경계: 판정 중 정지가 미확인으로 덮이는 경우 2 실패, 센서 예외/관측 창 정리 2 실패, 승인 계획 완료 이벤트 분류 1 실패를 각각 확인하고 수정했다. 공개 상태·이력 API에서 새 원인을 기존 화면이 누름 전 중단으로 오해하는 경계도 2 실패 뒤 수리했다. 공개 모션 중단 원인 필드만 null로 두고 unconfirmed·상세 문구와 내부 이력 원인은 보존한다. 시험 작성 중 입력·import 오류는 결함 재현 수에 포함하지 않는다.

기존 시험은 실제 정책에 맞춰 재시도 허용 입력을 명시했다. 서비스/API 경로의 재시도 예시는 내장 10초 버튼으로 바꿨다. 임의 라벨을 쓰는 단위 시험의 idempotent는 시험 입력이며 실물 시작 버튼의 분류가 아니다. 리허설도 시간 버튼을 사용한다.

최종 시험 결과: **진행 중 — 완료 뒤 수·종료 코드를 기록한다.**

## 3. 사람이 다시 실행하는 경로(변경하지 않음)

- 폰 '다시 시도'는 시작 화면으로 돌아간다(`app/lib/screens/status_screen.dart`), 버튼을 즉시 다시 보내는 콜백이 아니다.
- 키오스크 제안 재시도는 같은 제안 ID 승인을 다시 요청한다. 서버의 승인권 획득은 이미 승인한 카드에 409/없는 카드에 404를 반환하므로, 그 콜백만으로 전체 순서를 다시 실행한다고 단정하지 않는다.
- 그러나 사용자가 새 승인 카드로 루틴 전체를 다시 실행하거나 같은 버튼 순서를 새 요청하면 앞서 성공했던 토글도 처음부터 다시 누른다. `test_explicit_whole_sequence_rerun_repeats_successful_prefix_report_only`로 두 요청에서 시작 버튼 2회를 확인했다. 자동 재누름 차단과 다른 **잔존 위험**이며 사용자 지시에 따라 수정하지 않았다. UI 확인 창의 실제 낭독·클릭은 이번에 시험하지 않았다.

## 4. 서류 현행화

[보고서](../submission/개발완료보고서-초안.md) §6-1a에 날짜·main 근거 커밋·문서 링크와 검증 범위를 모았다. 소개서·그림 대응표·피드백 전후·README도 같은 범위로 맞췄다.
ThinQ 실물은 기존 개발자 보고 인용: 노트북의 풍량 `state_confirmed`, 이미 목표값, 꺼짐 거절 2304, 꺼짐+종합 BAD→켜기 카드→API 승인까지. RPi5·폰/패널 켜기 승인·실제 CT 공조 확인으로 확대하지 않았다.
안전 수리는 시험 조건만·보드 미배포, 키오스크는 위젯·골든 확인·실패널 미설치. 이미지 자체는 변경·새 열람하지 않았고 골든을 패널 사진처럼 쓰지 않았다. 상용품은 설계 차이만 비교한다.

**【기입】 유지:** 캐리지 이동·원점 오차, 버튼별 누름 성공률(첫 시도/재시도 포함), CT 시작·종료 지연/오판, 정지 거리·시간(중앙/최대), RPi5 ThinQ 제어·상태 확인 지연, 비교 실험, 초기 사용성, BOM 원가·설치 시간, 실측 실행/배포 SHA, 최신 실물 사진·v4 그림. 기록 커밋과 실측 실행 SHA가 다른 경우 실행 SHA를 임의로 채우지 않았다.


## 5. 적용 지점과 변경 파일

| 지점 | 코드 근거 | 내용 |
|---|---|---|
| L1·L2 공통 실행 | `rpi/controller/closed_loop.py:342`, `:450`, `:497` | 기본 unknown, 재시도 허용 여부 판정, 보정·재입력 전 차단 |
| 버튼 정의·격자 | `rpi/services/appliance_registry.py:292`, `rpi/intent/appliance.py:85`, `docs/button-maps/microwave.json` | 내장 분류와 격자 읽기 |
| 등록·저장 | `rpi/api/schemas.py:165`, `rpi/services/persistence.py:352`, `:448` | 선택 필드와 재시작 복원 |
| 대상 결속 | `rpi/api/service.py:1042`, `rpi/api/service_commands.py:290` | 대상 가전별 스냅샷, 직접 실행·승인 계획 모두 전달 |
| 두 보드 연결 | `rpi/services/act_client.py:530`, `rpi4/models/act_messages.py:290`, `rpi4/services/act_executor.py:744` | 실제 메시지 인코딩·수신·실행기 전달 |
| 결과·기록 | `rpi/api/service.py:792`, `rpi/api/service_commands.py:585`, `rpi/api/router.py:156`, `:1304` | 미확인 분류, 기존 화면의 모션 중단 오해 방지 |
| 회귀 시험 | `rpi/tests/test_button_retry_safety.py` | 33개 매개변수 포함 사례; 메모리 링크는 실제 수신 루프 사용 |

`git status --short` 결과(신규 2개는 `git add -N`만 적용, 커밋용 스테이징 없음):

```text
 M README.md
 M docs/button-maps/microwave.json
 A docs/devlog/devlog_2026-10-16-r1-docs.md
 M docs/protocol.md
 M docs/submission/개발완료보고서-초안.md
 M docs/submission/그림-대응표.md
 M docs/submission/작품소개서-초안.md
 M docs/submission/피드백-전후.md
 M docs/안전계약-적용-보고-2026-10-15.md
 M docs/코드-구조.md
 M docs/키오스크-문구-개선-계획-2026-10-15.md
 M rpi/api/router.py
 M rpi/api/schemas.py
 M rpi/api/service.py
 M rpi/api/service_commands.py
 M rpi/commands/physical.py
 M rpi/controller/closed_loop.py
 M rpi/controller/models.py
 M rpi/intent/appliance.py
 M rpi/services/act_client.py
 M rpi/services/act_client_controller.py
 M rpi/services/appliance_registry.py
 M rpi/services/persistence.py
 M rpi/services/simulator_controller.py
 A rpi/tests/test_button_retry_safety.py
 M rpi/tests/test_closed_loop.py
 M rpi/tests/test_demo_failure.py
 M rpi/tests/test_experiment_record.py
 M rpi/tests/test_history.py
 M rpi/tests/test_layered_verification.py
 M rpi/tests/test_motion_abort.py
 M rpi/tests/test_power_operation_verifier.py
 M rpi/tests/test_press_coordinates.py
 M rpi/tests/test_router.py
 M rpi/tests/test_safety_g2_stop_before_dispatch.py
 M rpi/tests/test_sensor_window.py
 M rpi/tests/test_simulator_controller.py
 M rpi/tests/test_twin_real_mode.py
 M rpi/tests/test_twin_view.py
 M rpi4/models/act_messages.py
 M rpi4/services/act_executor.py
 M rpi4/simulator.py
 M rpi4/tests/test_act_executor.py
 M rpi4/tests/test_act_link_integration.py
 M rpi4/tests/test_act_link_retry_l3.py
 M rpi4/tests/test_act_progress.py
 M rpi4/tests/test_simulator.py
```
