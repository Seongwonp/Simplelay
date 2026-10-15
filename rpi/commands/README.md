# rpi/commands — 명령·결과·승인 계약

> 역할: 실행 경로와 분리된 **값 객체**만 둔다 — 명령(`Command`)·결과(`CommandResult`)·승인(`ApprovedCommand`). 근거 계약은 [U1-a 명령·결과·승인 계약](../../docs/ThinQ-U1a-명령-결과-승인-계약-2026-09-22.md).

| 파일 | 무엇 |
| --- | --- |
| `models.py` | 값 객체. 세 축이 독립이다 — 실행 환경(real·mock), 제어 경로(`ControlRoute`: physical·thinq), 확인 수준(`Confirmation`). `ApprovedCommand.matches`는 지금 실행하려는 명령이 승인한 명령과 **내용이 같은가**를 본다 |
| `args.py` | 인자 검증·정규화와 명령 지문 `fingerprint_of` — 승인이 묶이는 값 |
| `approval.py` | 승인 재검사 실패 예외(내용 불일치·만료·무효). HTTP에서는 409, 실행하지 않고 카드를 내리거나 다시 승인받는다 |
| `physical.py` | 물리 실행 결과 → `CommandResult` 순수 변환. `receipt_of`(받았나)와 `confirmation_of`(무슨 근거로 확인했나)를 따로 읽는다 |

## 지켜야 할 것

- **받음과 확인은 다른 필드다.** `receipt`(not_dispatched · unknown · accepted)와 `confirmation`(none · reported · press_confirmed ·
  state_confirmed · state_confirmed_unknown_before · operation_confirmed). 상태를 관측했다고 "명령을 받았다"로 올리지 않는다.
- 물리 경로의 L1 눌림은 `press_confirmed`까지만이다(가전 동작 확인이 아님). `operation_confirmed`는 **실물** 전력 판정(L3)일 때만 — 모의 전력의 통과는 근거가 아니다.
- 승인 뒤 목적을 다시 해석하지 않는다. 재검사로 만든 명령의 지문이 승인과 다르면 실행하지 않는다(대조는 `rpi/api/service.py` `_check_approved`, `service_commands.py` `submit_approved`).
- 정지 확인 단계(보냄 → 모션 보드 응답 → 멈춤 확인)는 여기가 아니라 `rpi/services/stop_confirm.py`에 있다 — [코드 구조](../../docs/코드-구조.md) §2.
