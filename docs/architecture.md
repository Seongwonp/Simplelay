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

## RPi ↔ 하드웨어 연결 (결정 필요 항목)

- [ ] RPi ↔ ESP32/Uno 연결 방식: UART 직결 vs Wi-Fi(HTTP/WS) vs BLE — M2에서 확정
- [ ] 센서 → RPi 입력: GPIO(디지털) vs ADC(아날로그, MCP3008 등) — 센서 종류에 따라
- [ ] RPi 모델: 보유 중인 라즈베리파이 사양 기입 (___)

## 관련 문서

- [폐루프 설계](closed-loop-design.md)
- [재사용 경계](reuse-boundary.md)
- [로드맵](roadmap.md)
