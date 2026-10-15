# 2026-10-15 안전 빈칸 수리 — G2(보내기 전 정지) · G1(링크 끊김 무결과) · G11(죽은 엔코더 '멈춤 확인')

근거: [안전 계약 적용 보고](../안전계약-적용-보고-2026-10-15.md) §1~§2(코드·재현 기준 판정). 원칙은 **확인한 만큼만 말한다**
(정지: 보냄 `sent` < 모션 보드 응답 `mcu_ack` < 멈춤 확인 `verified`, 실행: 수신 receipt와 확인 confirmation을 가른다).
세 빈칸 모두 **고치기 전 회귀 시험이 실패하는 것을 먼저 확인**했다(수정 전 파일은 저장소 밖에 복사해 두고 되돌림, `git stash` 쓰지 않음).
작업은 브랜치 `fix/g2-g1-g11`(시작 `55d2a06`), 빈칸마다 커밋 하나. **보드에는 아직 배포하지 않았다** — 아래 '실물 미검증' 참고.

## 1. G2 — 접수 뒤·보내기 전에 온 정지가 사라짐 (높음, 커밋 `01590aa`·`fdf0272`)

- **증상(보고서 재현):** UART 직접 실행 경로에서 정지가 실행 접수 뒤·execute 전송 전에 오면, RPi5는 abort를 보내고 실행별 정지
  기록만 세웠다. 실행 스레드(`_run_buttons` → `ActClientController.execute`)는 그 기록을 보지 않고 execute를 보냈고, RPi4는 아직
  쉬는 중이라 abort를 'idle'로 버렸다(`act_executor.py` `_abort`) → **정지 뒤 버튼을 전부 누르고 '성공'.**
- **재현 시험(결정적):** 실제 `ActClient`(RPi5)와 실제 `ActExecutor`(RPi4)를 메모리 파이프로 잇고(모션은 모의), 실행 대상 훅에서
  정지를 부른다 — ① 서비스가 실행 대상을 고른 직후(서비스 확인 전), ② 서비스가 실행 대상에 넘긴 직후·줄을 쓰기 전(서비스 확인 뒤의 창).
  승인 카드(명령 경로)도 같은 실행 함수를 지나므로 같이 본다. 기존 `test_stop_immediately_after_submit_is_not_lost`는 로컬 폐루프만 봤다.
- **수리:**
  1. RPi5 `_run_buttons`가 실행 대상에 넘기기 **직전** 이번 실행의 정지 기록(`_stop_requested_this_run`·`_stop_sticky`)을 본다.
     있으면 보내지 않고 `stopped_before_dispatch()` — 결과 `stopped`, 수신 `not_dispatched`, 문장 "정지 요청으로 누름 장치에
     보내지 않았어요 — 누른 버튼은 없어요". 이력(`stopped_by_user`)·보호자 알림(긴급 정지)·완료 이벤트는 다른 정지된 실행과 같다.
  2. 그 확인 뒤·줄을 쓰기 전의 창은 RPi4 링크가 닫는다: `ActClientController.reset_stop()`(서비스 `_begin_run`이 잠금 안에서 부름)이
     정지 표시를 지우고, `request_stop()`이 표시를 **먼저** 세운 뒤 abort를 이벤트 루프에 올린다. `execute()`는 이벤트 루프 안에서
     줄을 쓰기 직전에 표시를 본다 — 확인과 줄 쓰기 사이에 await가 없어서, 표시가 없으면 abort는 반드시 execute 뒤에 나간다(RPi4가
     실행 중에 받아 멈춘다). 표시가 있으면 보내지 않는다.
  3. **이중 방어(RPi4, 하위 호환 규약 확장):** RPi5가 실행마다 표지 `run_ref`를 정해 abort·execute에 함께 싣는다. RPi4는 쉬는 중에
     `run_ref` 달린 abort를 받으면 기억하고, 같은 `run_ref`의 execute는 누르지 않고 `result {success:false, outcome:"stopped",
     button_results:[]}`로 답한다(한 번 쓰면 지움). `run_ref`가 없는 옛 RPi5 프레임은 종전 그대로, 옛 RPi4는 모르는 키를 무시한다.
     `act_info`에 새 값은 없다. 규약 설명은 [protocol.md](../protocol.md) '실행 표지 `run_ref`'.
- **시험:** `rpi/tests/test_safety_g2_stop_before_dispatch.py` 4건(UART 직접 ①②·승인 카드·쉬는 중 정지가 다음 실행을 막지 않음),
  `rpi4/tests/test_act_abort_before_execute.py` 5건(같은 표지 거절·다른 표지 실행·한 번만·옛 프레임 호환·정지 보고 idle 유지).
  - 수정 전 코드: **RPi5 3 실패 / 1 통과**(통과 1건은 쉬는 중 정지 회귀 지킴), **RPi4 2 실패 / 3 통과**(통과 3건은 호환 지킴).
  - 층 확인: RPi4 링크의 루프 안 확인만 꺼 보면 ② 경우 1 실패 — execute 줄이 나가고 RPi4가 `run_ref`로 거절한다(이중 방어가 받는다).
  - **후속 수리 `fdf0272`:** 처음 판(`01590aa`)의 링크 정지 표시는 서비스 실행 시작(`reset_stop`)이 지울 때까지 남아, 서비스를 거치지 않고
    링크를 직접 쓰는 시뮬레이터 시험(`test_simulator_controller.py::test_stop_crosses_protocol_and_prevents_second_button`)에서 정지 뒤
    다음 실행을 '보내지 않음'으로 끝냈다(전체 시험에서 발견). 정지 표시를 그 실행의 표지(`run_ref`)에 묶어 고쳤다 — 쉬는 중 정지는 옛 표지라
    다음 실행을 막지 않고, 표지가 없는 직접 호출은 종전 그대로. 고친 뒤에도 루프 안 확인을 끄면 ② 1 실패를 다시 확인했다.
- **화면:** 물리 `stopped` + `not_dispatched`. 폰 확인 칩 '누르지 않음', 결과 문장은 정지 단계 문장(쉬는 중이던 RPi4라 단계 없음 →
  "정지 요청으로 실행이 끝났어요. 누름 장치와 가전이 멈췄는지 직접 봐 주세요."). 거짓 문장이 아니라 클라이언트는 고치지 않았다.

## 2. G1 — 승인 카드·루틴·시나리오의 물리 단계 링크 끊김이 결과 없이 끝남 (높음, 커밋 `fbb8ea9`)

- **증상(보고서 재현):** `_run_physical_step`이 실행 대상 예외(RPi4 응답 없음·링크 오류)를 잡지 않아 `_run_plan_job`이 로그만
  남겼다 — RunRecord·이력·보호자 알림·완료 이벤트가 없고, `/status`에는 이 job 번호에 **직전 실행의 결과**(`last_result`·
  `last_receipt`·`last_confirmation`)가 붙었다. 시연의 '첫 조리 승인'이 이 경로다. 직접 경로(`/execute`)는 같은 끊김을
  '연결이 끊겨 완료하지 못했어요'·재시도 소진으로 적었다(G5 문구) — RPi4가 이미 다 눌렀을 수 있다.
- **수리:** 끊김은 '눌렸는지 모름'이다.
  - `_record_unconfirmed_physical`(직접·명령 경로 공용): `/status` last_* 를 **이 job의 것**으로 — 수신 `unknown`·확인 `none`·
    명령 상태 `unconfirmed`·문장 "연결이 끊겨 눌렸는지 확인하지 못했어요 — 가전을 직접 봐 주세요(자동으로 다시 누르지 않아요)".
    이력은 `outcome: unconfirmed`·`receipt: unknown`·`termination: unknown`(사용자 정지 뒤면 `stopped_by_user`, 종전 규칙 유지)·같은 문장.
    보호자 알림 `execution_failed` "'…' 실행 중 가전과 연결이 끊겨 눌렸는지 확인하지 못했어요. 가전을 직접 확인해 주세요(자동으로 다시 누르지 않아요)."
  - 명령 경로 `_run_physical_step`이 예외를 잡아 `CommandResult(unconfirmed, unknown, none)`을 돌려주고 완료 이벤트(`status: unconfirmed`)를
    보낸다. 남은 단계는 `_run_plan`이 '앞 단계가 확인되지 않아 보내지 않았어요'로 보내지 않는다. 루틴은 `unconfirmed`로 멈춘다.
  - 직접 경로는 **동작 그대로**(예외 → 이력·보호자 알림, 완료 이벤트 없음) 분류·문장만 바꿨다.
  - `/status`·SSE(`command_status_fields`): 물리 실행의 `unconfirmed`도 `last_status`·`last_outcome`에 올린다 — `failed`로 두면 폰은
    "끝까지 실행하지 못했어요", 키오스크는 "실행을 시작하지 못했어요 … 다시 시도해 주세요"로 읽는다(이미 다 눌렀을 수 있다).
    이제 폰·키오스크는 기존 `unconfirmed`+`receipt unknown` 문장("가전이 명령을 받았는지 알 수 없어요. 다시 보내기 전에 가전을 직접
    확인해 주세요")을 쓴다 — **클라이언트 수정 없음.** 키오스크 대기 화면 안내도 물리 끊김이면 "가전 — 눌렸는지 확인하지 못했어요 · 가전을 봐 주세요".
- **시험:** `rpi/tests/test_safety_g1_link_drop.py` 4건 — 승인 카드(직전 성공 실행 뒤 끊김: status·RunRecord·이력·보호자 알림·완료 이벤트,
  다시 누르지 않음), 루틴(전자레인지 → 인덕션 구간에서 첫 단계 끊김: 루틴 `unconfirmed`, 인덕션 미전송), 직접 경로 문구·분류,
  대기 화면 안내. 수정 전 코드: **4 실패**(앞 3건은 수정 전 전체 코드에서, 대기 화면 1건은 그 파일만 되돌려 확인).
- 기존 시험 그대로 통과: `test_care_events.py::test_controller_exception_records_care_event`("연결이 끊겨" 포함·내부 문구 비노출),
  `test_experiment_record.py::test_a_stopped_run_that_then_crashed_is_still_a_user_stop`.

## 3. G11 — 엔코더가 죽어도 '멈춤 확인(verified)' (중상, 커밋 `5777350`)

- **증상:** 정지 뒤 status 두 번의 엔코더 a·b가 같기만 하면 `verified`였다(`serial_motion.py` `_verify_still`). 10/13 보드 날 엔코더
  선 접촉 불량으로 0만 읽는 상태에서도 "멈춘 것을 확인했어요"가 떴다 — 같은 값은 멈춤과 죽은 엔코더를 가르지 못한다.
- **결정·수리:** `verified`는 **이번 실행(어댑터 `reset_stop` 뒤 — 일반 실행·개발자 조작마다 새로 셈)에 이동을 명령한 축마다 엔코더
  값이 실제로 바뀐 것을 본 경우**에만. 근거가 없으면 `mcu_ack`에 머물고 `stop_detail` "엔코더 움직임을 확인할 수 없어 멈춤은
  확인하지 못했어요"(`ENCODER_UNPROVEN_DETAIL`).
  - 근거 = 위치 보고(`position` 사건·status·응답의 a·b)가 기준값에서 바뀐 축. 정지 뒤 관성으로 바뀐 것도 근거다.
  - 필요한 축 = 이번 실행에 보낸 `move`의 목표 카운트가 마지막으로 본 값과 다른 축(마지막 값을 모르면 두 축). **한 축만 죽어도** 그 축이
    움직여야 했으면 `verified`가 아니다(10/14 엔코더 A 단자 빠짐 사례). 대각 이동처럼 한 모터만 도는 이동은 그 축만 본다.
  - 기준값: 새 실행은 마지막으로 본 값(쉬는 사이 카운트는 그대로). **원점 복귀·MCU 재시작(`ready`)·포트 잃음은 기준을 버린다** —
    카운트가 0으로 돌아가는 것은 엔코더가 살아 있다는 근거가 아니다.
  - **쉬는 중 정지(이번 실행에 이동 명령 없음):** 확인할 움직임이 없다 → `mcu_ack`(종전은 정적인 두 값으로 `verified`). 정적인 읽기만으로는
    `verified`를 내지 않는다. **버튼 사이 대기 중 정지**는 이번 실행에 이동하며 엔코더가 바뀌는 것을 봤으므로 종전처럼 `verified`.
    원점 복귀 중 정지는 이동 명령 전이라 `mcu_ack`(펌웨어는 원점 복귀 중 위치 사건을 보내지 않는다).
- **시험:** `rpi/tests/test_safety_g11_encoder_alive.py` 8건 — 두 축 죽음·한 축 죽음(→ `mcu_ack`+문장), 살아 있는 엔코더 버튼 사이 정지·
  이동 중 정지(→ `verified`), 쉬는 중 정지(→ `mcu_ack`, 고정), 앞 실행 근거가 다음 실행으로 넘어가지 않음, 원점 복귀 카운트 초기화는
  근거 아님, 문장 상수. 수정 전 코드: **6 실패 / 2 통과**(통과 2건은 살아 있는 엔코더 지킴).
- **기존 시험 수정(의도된 동작 변경):** 이동 없이 정지해 `verified`를 기대하던 4건 — `test_stop_confirm.py` 3건(같은 값 두 번·관성 뒤 멈춤·
  정지 id 결속)은 앞에 이동 두 번을 넣었다(가짜 MCU는 이동마다 위치를 한 번만 알린다 — 실물은 이동 중 주기적으로 알린다),
  `rpi4/tests/test_dev_motion.py`는 조그 두 번 뒤 정지 `verified`로 바꾸고, 조그 없는 정지는 `mcu_ack`+문장으로 새로 고정했다.
- **화면:** 정지 단계가 더 자주 `mcu_ack`로 온다 — 폰 "모션 보드가 정지를 확인했어요", 키오스크 "작은 팔이 정지 신호를 받았어요 —
  멈췄는지는 확인 못 했어요"(10/15 키오스크 문구). 새 값은 없다 — 클라이언트 수정 없음.

## 4. 규약 변경

- `run_ref`(선택 문자열 1~64자)를 RPi5→RPi4 `abort`·`execute`에 추가. 하위 호환(옛 RPi5 프레임 = 종전 동작, 옛 RPi4는 무시).
  RPi4의 새 답은 기존 `result` 모양(`success:false`·`outcome:"stopped"`·`button_results:[]`). [protocol.md](../protocol.md)에 기록.
- `/status`·SSE: 물리 실행이 예외로 끝난 경우 `last_status`·`last_outcome` = `unconfirmed`(G1). 정지 단계 `verified`의 정의 보강(G11).
  [protocol.md](../protocol.md) '마지막 한 칸' 절과 정지 단계 표.

## 5. 시험 수

- 새 회귀 시험 21건(G2 RPi5 4·RPi4 5, G1 4, G11 8), 기존 시험 4건 수정·1건 추가(`test_dev_stop_with_no_motion_stays_at_mcu_ack`).
- 백엔드+rpi4 전체(`pytest -q`, 골든 없음): **3,211 통과 · 10 건너뜀**(시작 판 약 3,189 + 이번 22건 순증).
  두 번 돌렸다. 1차는 위 시뮬레이터 1건 실패(→ `fdf0272`), 2차는 `test_act_client_reconnect.py::test_write_only_failure_reconnects_without_eof[drain]`
  1건이 타이밍(0.0776 s < 0.08 s)으로 실패 — 따로 세 번 돌리면 1회 실패·2회 통과이고, **시작 판(`55d2a06`)을 저장소 밖에 풀어 같은 시험을 여섯 번
  돌려도 두 번 실패**해 이번 수리와 무관한 기존 불안정 시험이다(Windows 타이머 해상도 추정).
- `rpi/tests/test_repo_guard.py`·`rpi/tests/test_doc_links.py` 통과.

## 6. 실물 미검증 · 남은 위험

- **보드 배포 전이다.** RPi5·RPi4를 **같은 커밋**으로 다시 빌드·배포해야 한다(같은 커밋 규칙). RPi5만 새 판이면 G2 1차 방어(RPi5)는
  동작하지만 RPi4 이중 방어(`run_ref`)는 없다. RPi4만 새 판이면 G2는 고쳐지지 않는다(RPi5가 표지를 보내지 않는다). G11은 RPi4 판에 있다.
- G2: 메모리 파이프·모의 모션에서만 확인. 실물 Wi-Fi 링크(소켓)에서 '승인 → 0.2 s 안 정지'(PS-1 S4)를 다시 재야 한다.
- G1: 링크 끊김은 예외 주입으로만 확인. 실물 Wi-Fi 끊김(PS-1 S5)에서 폰·키오스크 화면 문장을 봐야 한다. **G5의 나머지**(조용한 끊김에
  RPi4가 남은 버튼을 계속 누르는 문제 — 실행 중 생존 신호)는 고치지 않았다.
- G11: 가짜 MCU로만 확인. 실물에서 ① 엔코더 선을 뺀 채 이동·정지 → `mcu_ack`+문장, ② 정상 엔코더 이동 중 정지 → `verified`(10/14의
  18 ms 사례 재확인)를 봐야 한다. 실물 펌웨어는 원점 복귀 응답에 카운트를 싣지 않으므로 원점 복귀 직후 첫 이동은 이동 중 위치 사건
  (주기 `POSITION_EVENT_MS`)이 둘 이상 와야 근거가 생긴다 — 아주 짧은 이동 하나뿐인 실행은 `mcu_ack`에 머물 수 있다(보수 쪽).
- 남은 빈칸(이번에 안 함): G3(루틴 구간 사이 정지)·G4(어댑터 잠금 대기 뒤 재확인)·G7(텍스트 "멈춰" → '취소' 누름)·R1.
- 작업 규칙 파일의 '열린 안전 문제' 줄은 이 브랜치를 합칠 때 함께 고친다(이번 커밋에서는 건드리지 않음).
