# 아키텍처

> Sense · Interpret · Act 3계층 + 라즈베리파이 Brain 레이어.
> 의존성은 한 방향: 앱은 하드웨어 세부를 모르고, GRBL은 의도를 모른다.

---

## 전체 데이터 흐름

```
[사용자 목적]
   │  "우유 데워줘" (음성/터치)
   ▼
[Flutter 앱]  ── BLE / Wi-Fi ──▶ [ESP32 브릿지] ── UART ──▶ [Arduino Uno GRBL] ──▶ [TB6600 ×3] ──▶ [NEMA17 XYZ]
   ▲                                    ▲                          │                                    │
   │ 상태·검증 결과                      │ ok/error/alarm            │ G-code 실행                      (버튼 누름)
   │                                    │                          ▼                                    ▼
   └──────────────── [라즈베리파이 Brain] ◀──────────── 전류·음향 센서 (실행 검증) ◀────────────────────┘
                       intent → controller → verifier → api
```

## 계층 계약

| 계층 | 입력 | 출력 | 모르는 것 |
| --- | --- | --- | --- |
| intent | 사용자 목적, 사용 이력 | 버튼 시퀀스 | 좌표·G-code |
| controller | 버튼 시퀀스 | 실행 명령 + 재시도 판단 | 센서 원신호 처리 |
| verifier | 센서 원신호 | 눌림/안눌림 판정 | 다음에 뭘 누를지 |
| api | 앱 요청, 내부 상태 | 앱 응답, 로그 | 하드웨어 제어 세부 |
| firmware(ESP32) | 앱/RPi 명령 | GRBL G-code, 상태 | 의도·검증 |

## 라즈베리파이 Brain 레이어의 보드 분리

"라즈베리파이 Brain"은 실제로는 두 대다. 역할은 [프로토콜 명세](protocol.md)의 통신 흐름과
일치시킨다.

| 보드 | 역할 | 담당 계층 |
| --- | --- | --- |
| RPi 5 (8GB) | Interpret — 의도 해석은 계산량이 큰 편이라 더 여유 있는 보드에 배치 | intent, api |
| RPi 4 (4GB) | Act — 폐루프 실행·GPIO는 실시간성이 중요하지 실측 연산량은 크지 않음 | controller, verifier |

## RPi ↔ 하드웨어 연결 (결정 필요 항목)

- [ ] RPi ↔ ESP32/Uno 연결 방식: UART 직결 vs Wi-Fi(HTTP/WS) vs BLE — M2에서 확정
- [ ] 센서 → RPi 입력: GPIO(디지털) vs ADC(아날로그, MCP3008 등) — 센서 종류에 따라
- [x] RPi5(intent/api) ↔ RPi4(controller/verifier) 간 IPC: **UART로 방향 확정.** 두 보드가
      물리적으로 같은 하우징에 있어 네트워크 의존성 없이 배선 가능하고, 폐루프 제어의
      레이턴시가 결정론적이며, 시연장 네트워크 상태와 무관하게 동작한다는 게 근거.
      protocol.md의 UART 프로토콜(`execute`/`abort` → `result`/`error`) 기준으로 RPi4 쪽
      실행기(`rpi4/act_executor.py`) 구현 완료. 예솔님과는 아직 이 얘기를 안 했으므로
      물리 배선(GPIO UART 핀 가용성)만 확인 필요 — 프로토콜 자체는 팀 내부적으로 확정.
      `rpi/api/service.py`가 실제로 `ActExecutor`를 호출하도록 연결하는 배선은 아직 남은 작업.

## 관련 문서

- [폐루프 설계](closed-loop-design.md)
- [재사용 경계](reuse-boundary.md)
- [로드맵](roadmap.md)
