# 2026-09-30 — 정지 버튼 대기·보관 · 사진 매핑(사진 → mm) · 확인 주행

[본선 실행 계획](본선-실행계획-2026-09-30.md) §3-1(정지 버튼 대기와 보관 위치)·§3-2(카메라 매핑)와
[UI 확정](UI-확정-2026-09-30.md) §2 가전 추가 5단계·§3-3 동작 중 화면의 서버 쪽을 넣었다.

> **모의까지다.** 모터·스위치봇 Z 모듈·CT 전력 리더 없이 모의 모션과 모의 가전으로만 돌렸다. 사진 매핑은
> 원근 왜곡을 넣은 합성 점으로만 확인했고 실제 사진·렌즈로는 해 보지 않았다. 실제 모션 어댑터 경로
> (`SerialMotionClient.move_to`·`press`)는 코드만 있고 실물로 움직여 본 적이 없다. 폰·키오스크 화면은 바꾸지
> 않았다(Flutter 제외).

## 1. 원칙

- **가전 정지 ≠ 구동부 비상정지.** `/stop`(폰·키오스크·음성 모두 같은 경로)은 정지 버튼 위에서 대기 중이면
  **정지 버튼을 등록한 횟수만큼 누른다**. 구동부 정지(`abort scope:"drive"`)는 모션만 멈추고 누르지 않는다.
  구동부가 잠겼거나 누르다 실패하면 결과는 `drive_fault` — "구동부 이상으로 정지 버튼을 누르지 못했어요 — 가전
  전원을 직접 꺼 주세요". 최후 수단은 여전히 전원 차단(물리 E-STOP)이다.
- **정지됨은 전력이 떨어져야 말한다.** 누름이 끝났다는 것과 가전이 멈췄다는 것은 다르다. 확인 시간(기본 5초,
  설계 초기값) 안에 전력 하강이 없으면 "정지 요청함·미확인"이고, **다시 누르지 않는다**(전자레인지의 시작/일시정지
  같은 토글 버튼을 두 번 누르면 다시 켜질 수 있다). 확인 시간을 넘겨 떨어지면 "스스로 끝났을 수도 있어요"를 붙인다.
- **상태 기계는 새로 만들지 않았다.** 9/27 모의 모델 `rpi4/parking_simulator.ParkingSimulator`를 그대로 쓴다.
  바꾼 것은 mm 좌표(`MmPoint`)와 보관 모서리 `free` 두 가지뿐이다. Z 복귀 근거 없이 XY 이동 안 함, 중복 누름 없음,
  실패·구동부 정지는 잠금(자동 재가동·자동 보관 없음) 규칙이 실행기에서도 그대로 산다.
- **사진 파일은 서버에 올리지 않는다.** 사진 크기와 짚은 좌표(px)만 받아 기록한다.

## 2. 등록 필드 (가전 레지스트리)

| 필드 | 뜻 | 검증 |
|---|---|---|
| `stop_button` | 정지(취소) 버튼 **id** | 이 가전의 누름 버튼이어야 한다(다이얼 거절) |
| `stop_presses` | 정지까지 누를 횟수 1~3 (전자레인지 1=일시정지·2=취소) | 범위 밖 422 |
| `park_xy` | 보관 위치 [x, y] mm | 0~600mm, 보정된 버튼 중심과 15mm 이상(설계 초기값), 정지 위치와 달라야 함 |
| `panel_mapping` | 사진 크기·모서리·버튼 px 기록 | 매핑 저장으로만 채움 |

- 소프트 리밋(`SIMPLELAY_MOTION_X_MIN_MM` 등 4개)이 설정돼 있으면 정지 위치·보관 위치가 그 안인지 보고 밖이면
  422. 없으면 받아 두되 `stop_park_check.status = "unverified"`("범위 미확인")로 응답에 싣는다. 정지 버튼 mm나
  보관 위치가 없으면 `incomplete` — 대기를 하지 않는다. RPi4 모션 어댑터는 움직이기 전에 한 번 더 리밋을 본다.
- 옛 폰 편집기가 `PUT /appliances/{id}`로 이름만 바꿔 저장해도 정지·보관은 이어받는다(버튼이 사라지면 정지 버튼만
  비운다). 내장 가전(전자레인지)도 사진 매핑으로 정지·보관을 가질 수 있다(설정 키 `stop_park:<id>`).

## 3. API (폰 가전 추가 마법사용)

모두 기존 API와 같은 `X-API-Key`를 탄다. 사진 좌표는 왼쪽 위 원점, 아래로 +y(px).

| 단계 | 호출 | 내용 |
|---|---|---|
| 준비 | `GET /mapping/frame` | 서버 설정 프레임 치수(`SIMPLELAY_FRAME_W_MM`·`_H_MM`, 없으면 null)·원점 오프셋·소프트 리밋·모서리 순서 |
| ②~④ 미리보기 | `POST /appliances/{id}/mapping/preview` | 계산만, 저장 안 함 |
| ④ 저장 | `PUT /appliances/{id}/mapping` | 버튼 mm·정지 버튼·횟수·보관 위치·사진 기록을 한 판으로 저장(`expected_revision` 충돌 409) |
| ⑤ 확인 주행 | `POST /appliances/{id}/verify-pass` (202) | 선택 `{"button_ids": [...]}`. 없으면 보정된 버튼 전부 → 보관 위치 |
| ⑤ 상태 | `GET /appliances/{id}/verify-pass` | `state` running·done·failed, 버튼별 `status` pending·moving·reached·failed·skipped |

매핑 요청(수치는 형식 예시, 실물 값 아님):

```json
{ "photo_width": 1200, "photo_height": 900,
  "corners_px": [[150,90],[696,107],[677,484],[187,509]],
  "frame_w_mm": 300, "frame_h_mm": 200,
  "buttons_px": {"BT-08": [320,210], "BT-05": [600,420]},
  "stop_button": "BT-06", "stop_px": [540,420], "stop_presses": 2,
  "park_px": [210,480], "extra_points": [], "expected_revision": 3 }
```

응답: `saved`, `version`(12자), `quality`(모서리 각도·넓이 비율·비율 배수, `residual_check` none|extra_points),
`buttons_mm`, `stop_button`, `stop_presses`, `park_xy`, `stop_park_check`, `unmapped_buttons`, `appliance`(저장 시).

**거절(422, 그대로 화면에 보일 문장):** 모서리 순서가 꼬임(자기 교차) · 반대 방향 · 첫 점이 왼쪽 위가 아님 ·
볼록하지 않음 · 모서리 각도 25° 미만/155° 초과 · 사진 대비 넓이 2% 미만 · 사진 속 비율과 프레임 비율 2.5배 넘게
다름 · 모서리·버튼이 사진 밖 · 짚은 점이 프레임 밖(여유 5mm) · 프레임 치수 없음 · 정지 버튼 위치를 짚지 않음 ·
보관 위치가 버튼과 너무 가까움 · 소프트 리밋 밖. 임계값은 전부 설계 초기값이다.

**잔차.** 모서리 네 점만으로는 잔차가 늘 0이라 검증력이 없다(`transform.py` 머리말). 그래서 응답에
`residual_check:"none"`과 "확인 주행으로 확인해 주세요"를 싣는다. `extra_points`(사진 px ↔ mm 기준점)를 더
주면 기존 `calibrate`로 실제 잔차 검증(RMS 1mm·한 점 2mm)을 한다.

**동작 중 상태:** `GET /status`에 `hold_state`(hovering_stop·stopping·parking·parked·fault·released·null),
`hold_stop_outcome`(stopped·requested_unconfirmed·drive_fault·null), `hold_detail`(화면 문장),
`hold_appliance_id`, `hold_stop_button`, `hold_execution_mode`. `POST /stop` 응답에
`appliance_stop_requested`(대기 중이었나 = 정지 버튼 누름으로 전달됨)·`hold_state_at_request`. 결과는 뒤따르는
`/status`로 본다. 가전 응답(`GET /appliances`)에 `stop_button`·`stop_presses`·`park_xy`·`stop_park_check`·
`panel_mapping`이 붙는다.

## 4. 실행 흐름 (RPi5 → RPi4)

1. 서비스가 실행 직전 레지스트리에서 계획을 만든다(`stop_park.hold_plan_for`) — 정지 버튼 mm와 보관 위치가 다 있을
   때만. `ActClientController.arm_stop_hold`가 다음 `execute` 한 번에 `hold`로 싣는다(docs/protocol.md).
2. RPi4 `ActExecutor`는 시퀀스가 성공하고 가전 동작이 확인되면(L3 `operation_confirmed=true`, 또는 모의) 결과를
   보내기 **전에** 대기를 연다(결과를 본 RPi5가 곧바로 보낸 정지가 대기를 놓치지 않게). 확인이 없으면 대기하지
   않고 그 사실만 보고한다.
3. 대기(`rpi4/services/stop_hold.py` `StopHoldSession`, 배경 스레드 하나가 상태 기계를 혼자 움직임): Z 복귀 확인 →
   정지 버튼 위로 이동 → 기다림. `abort` → 정지 버튼 N번 누름(간격 0.6초, 설계 초기값) → 전력 확인 → 정지됨이면
   보관 위치로. 가전이 끝나면(전력 대기) 보관 위치로. 최대 대기 30분(설계 초기값)이 지나면 보관 위치로 가며
   "가전 종료는 미확인"으로 적는다.
4. 보고는 `progress` 프레임(phase `hold`)으로 RPi5에 가고, RPi5 `ActClient.last_hold` → `/status`, 프레임 탭 →
   `/twin`(빨간 점선 원 = 정지 대기, 점선 사각형 = 보관)으로 옮긴다. 판정을 RPi5에서 지어내지 않는다.

환경 변수(RPi4·시뮬레이터): `SIMPLELAY_HOLD_STOP_CONFIRM_S`(5) · `SIMPLELAY_HOLD_MAX_S`(1800) ·
`SIMPLELAY_HOLD_PRESS_GAP_S`(0.6) · 모의 가전 `SIMPLELAY_HOLD_MOCK_RUN_S`(30) · `SIMPLELAY_HOLD_MOCK_STOP`
(honor | ignore). RPi5: `SIMPLELAY_FRAME_W_MM`·`_H_MM`·`SIMPLELAY_FRAME_ORIGIN_X_MM`·`_Y_MM`(기본 0).

## 5. 무엇이 모의·미검증인가

| 항목 | 지금 | 하드웨어가 있어야 하는 것 |
|---|---|---|
| 정지 대기·보관 상태 기계 | 모의 모션·모의 가전으로 끝단까지(API → ActClient ↔ ActExecutor) | 실제 이동 시간·정지 거리·스위치봇 누름 시간 |
| 정지됨 판정 | 모의 가전이 꺼질 때만 "정지됨" | **CT 전력 리더** — 없으면 실기기 판정은 늘 "정지 요청함·미확인"(`NoRunProbe`) |
| 가전 종료 → 보관 | 모의 가전 시간 경과 | CT 대기 전력 복귀 판정, 없으면 최대 대기 시간 뒤 보관 |
| 확인 주행 | 모의 모션(기록만), 실제 어댑터는 `move_to`만 쓰는 코드 | 실제 이동, 조그 미세 조정 화면(남음) |
| 사진 매핑 | 합성 원근 점 | 실제 사진(렌즈 왜곡은 흡수 안 됨), 프레임 모서리 가림 시 스티커 |
| 로컬 모드(`SIMPLELAY_ACT_MODE` 없음) | 확인 주행만 로컬 모의로 됨, **정지 대기 없음** | — (시뮬레이터·UART 모드에서만 대기) |

그 밖에 고친 것: 시뮬레이터 모드에서 보정된 가전을 실행하면 좌표(`targets`)를 받지 못해 `TypeError` →
`actuator_fail`이 되던 결함(`SimulatorController.execute`·내부 `RecordedController.execute`)을 고쳤다. 끝단 시험이
고치기 전 코드에서 실패하는 것을 확인했다.

## 6. 검증

- 새 시험 49건: `rpi4/tests/test_stop_hold.py` 11(대기→정지→정지됨→보관, 무반응 가전 미확인·재누름 없음, 늦은
  하강, 자연 종료 보관, 구동부 이상 `drive_fault`, 구동부 정지는 누르지 않음, 이동 중 구동부 정지, 전력 리더 없음 →
  미확인·시간 초과 보관, mm 모델 재사용, 확인 주행 이동만·실패 뒤 건너뜀, 메시지 엄격 파싱) ·
  `rpi4/tests/test_act_hold.py` 6(링크 끝단 대기·정지·보관, drive 범위, 실물+L3 미확인이면 대기 안 함, 새 실행이
  대기 해제·대기 중 확인 주행 거절, 확인 주행 링크, 부품 없으면 무시·거절) · `rpi/tests/test_panel_mapping.py` 16
  (원근 왜곡 합성 점 복원 ±0.01mm, 기준점 잔차, 원점 오프셋, 모서리 거절 7종, 프레임 밖·치수 없음, API 미리보기·저장·
  이어받기·거절·리밋·등록 검증·로컬 확인 주행) · `rpi/tests/test_stop_park.py` 12(검증·계획·재시작 영속·내장 가전·
  이어받기·/status·트윈 요약) · `rpi/tests/test_stop_hold_e2e.py` 4(시뮬레이터 API 끝단: 매핑 → 확인 주행 → 실행 →
  /stop → 정지됨·보관, 무반응 미확인, 자연 종료 보관, 등록 없으면 대기 없음).
- `/twin` 정지 대기·보관 표시는 상태 값(`twin.hold`)을 시험했고, 화면 스크립트는 구문 검사와 기존 JS 시험 23건
  통과까지다 — 브라우저로 그림을 보지는 않았다.
- 기존 `test_router.py::test_emergency_stop_returns_ok`는 `/stop` 응답 필드 두 개가 늘어 기대값을 고쳤다.
- 백엔드 전체(`rpi/tests`·`rpi4/tests`): **2,141 통과, 1 실패** — 실패는 `test_dbus_native`의 `dbus_fast` 미설치
  (이 작업과 무관한 환경 문제).

## 다음

- 폰 가전 추가 5단계 화면(사진 위 모서리·버튼 짚기, 미리보기 응답의 `quality`·거절 문장 표시, 확인 주행 진행)과
  키오스크 동작 중 화면(`hold_*` 표시, "보관 위치로 이동했어요") — 데스크톱 Flutter 작업.
- 확인 주행에서 틀린 버튼을 조그로 고치는 경로(`python -m rpi.tools.jog`와 저장 연결).
- CT 리더가 생기면 `NoRunProbe` 대신 전력 기반 probe를 꽂고 확인 시간·대기 전력 문턱을 실측한다.
- 전력 이상(과전류)을 정지 경로에 잇는 일은 이번 범위 밖이다.
