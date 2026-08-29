# 아키텍처

> Sense · Interpret · Act 3계층 + 라즈베리파이 Brain 레이어.
> 의존성은 한 방향: 앱은 하드웨어 세부를 모르고, 액추에이터 제어기는 의도를 모른다.

---

## 확정 아키텍처 (8/17 정정) — 다중 노드

**RPi5는 중앙 허브 한 대**, **RPi4(+ESP32)는 가전마다 한 세트씩 여러 대**가 각자 다른
위치에 붙는다. 예전에 이 문서에 있던 "RPi5·RPi4가 같은 하우징에 물리적으로 함께 있어
UART로 직결한다"는 전제는 **폐기됨** — RPi4가 여러 대이고 각자 다른 가전 옆에 있는 이상
RPi5와 유선으로 묶을 수가 없다.

- 노드(가전 하나 담당 단위) = **RPi4 + ESP32**, 물리적으로 붙어있음 → 이 둘 사이는
  지금처럼 UART 유선 유지
- **ESP32가 그 노드의 무선 창구** — 개발 중엔 HTTP(RPi5가 클라이언트로 노드의
  `/execute`를 호출), 본선 데모에선 ESP-NOW(공유기 없이 ESP32끼리 직접 통신 —
  시연장 Wi-Fi 혼잡과 무관하다는 게 UART를 처음 골랐던 이유와 같은 동기)로 전환.
- **ESP-NOW에는 게이트웨이가 하나 더 필요하다** — ESP-NOW는 ESP32 라디오끼리만
  통하는데 RPi5에는 그 라디오가 없다. 그래서 이미 UART로 붙어 있는 폰 BLE 폴백
  브릿지 ESP32가 게이트웨이 역할을 겸한다(전용 보드를 추가하지 않는 쪽으로 팀 결정):

  ```
  RPi5 --UART--> 브릿지 ESP32(게이트웨이 겸용) --ESP-NOW--> 노드 ESP32 --UART--> RPi4
  ```

  이 문서는 한동안 "RPi5 ↔ 노드 ESP32"라고만 적고 있었는데, 그건 물리적으로 성립하지
  않는다(8/26 정정). 겸용의 대가로 **같은 UART에 BLE 브릿지 트래픽이 함께 흐르므로**
  게이트웨이 프로토콜은 자기 것이 아닌 줄을 걸러야 한다
- RPi5는 `appliance_id`로 어느 노드에 보낼지 결정 — `NodeRegistry`
  (`rpi/services/node_registry.py`)가 그 매핑을 들고 있음

## 전체 데이터 흐름

```
[사용자 목적]
   │  "우유 데워줘" (음성/터치)
   ▼
[Flutter 앱] ──HTTP(Wi-Fi 직통, 우선)──▶ ┐
   │                                     │
   └──BLE(폴백)──▶ [ESP32 브릿지] ──?──▶ ┴──▶ [RPi5 Interpret: api → intent]  (중앙 허브, 1대)
                                                          │
                                          appliance_id로 노드 라우팅 (NodeRegistry)
                                                          │
                        ┌─────────────────────────────────┼─────────────────────────────────┐
                        ▼                                 ▼                                 ▼
              [노드: 가전 A]                      [노드: 가전 B]                      [노드: 가전 C]
              ESP32 ── UART ── RPi4                ESP32 ── UART ── RPi4                ESP32 ── UART ── RPi4
                        ▲                                 ▲                                 ▲
                        └──── 개발: HTTP(RPi5 직통) / 본선: ESP-NOW(게이트웨이 ESP32 경유) ────┘
                        │
              [RPi4 Act: controller ↔ verifier]  (노드마다 독립적으로 동작)
                        │
            ┌───────────┴───────────┐
            ▼                       ▼
  [Arduino 커스텀 PID, X/Y]   [상용 BLE 버튼 장치, Z]
            │                       │
            └───────────┬───────────┘
                         ▼
                  (물리 버튼 누름)
                         │
                         ▼
            전류·음향 센서 ──▶ verifier (판정·재시도, 노드 로컬)
```

ESP32는 두 가지 역할로 쓰인다 — 혼동하지 않게 구분:
1. **폰 앱 BLE 폴백 브릿지** (기존 역할, 변경 없음): 폰이 Wi-Fi에 못 붙을 때만 쓰는
   BLE↔UART 릴레이. 의도 해석도 모션 제어도 안 함 —
   [esp32-firmware-spec.md](esp32-firmware-spec.md) 참고.
2. **노드의 무선 창구** (신규 역할): 가전마다 붙는 ESP32가 그 옆 RPi4를 대신해서
   RPi5와 무선으로 통신 — 위 "확정 아키텍처" 참고.

같은 종류의 칩이지만 물리적으로 다른 개체이고 역할도 다르다 — 1번은 폰 근처(또는
RPi5 근처)에 한 대, 2번은 가전마다 한 대씩 여러 대.

## 계층 계약

| 계층 | 입력 | 출력 | 모르는 것 |
| --- | --- | --- | --- |
| intent | 사용자 목적, 사용 이력 | 버튼 시퀀스 | 좌표·모터 제어 |
| controller | 버튼 시퀀스 | 실행 명령 + 재시도 판단 | 센서 원신호 처리 |
| verifier | 센서 원신호 | 눌림/안눌림 판정 | 다음에 뭘 누를지 |
| api | 앱 요청, 내부 상태 | 앱 응답, 로그 | 하드웨어 제어 세부, 어느 노드인지(NodeRegistry가 대신 앎) |
| firmware(ESP32, 폰 폴백) | BLE/UART 바이트 | 반대쪽으로 그대로 릴레이 | 의도·검증·모션 제어 (내용을 해석하지 않음) |
| firmware(ESP32, 노드) | RPi5의 HTTP/ESP-NOW 요청 | RPi4로 UART 전달, 결과 회신 | 의도 해석 (버튼 시퀀스를 그대로 전달만 함) |

## 라즈베리파이 Brain 레이어의 보드 분리

"라즈베리파이 Brain"의 RPi5는 한 대, RPi4는 가전 수만큼 여러 대다. 역할은
[프로토콜 명세](protocol.md)의 통신 흐름과 일치시킨다.

| 보드 | 대수 | 역할 | 담당 계층 |
| --- | --- | --- | --- |
| RPi 5 (8GB) | 1 (중앙 허브) | Interpret — 의도 해석은 계산량이 큰 편이라 더 여유 있는 보드에 배치 | intent, api |
| RPi 4 (4GB) | 가전마다 1대 | Act — 폐루프 실행·GPIO는 실시간성이 중요하지 실측 연산량은 크지 않음 | controller, verifier |

## RPi ↔ 하드웨어 연결

- [x] RPi5 ↔ ESP32(폰 폴백 브릿지): **UART로 확정** —
      [protocol.md](protocol.md)에 메시지 포맷까지 명세됨,
      `rpi/services/bridge.py`(UartBridge)로 구현 완료. 위 "확정 아키텍처"의 2번
      역할(노드 무선 창구)과는 별개.
- [x] RPi5 ↔ 노드(ESP32+RPi4): **다중 노드로 확정, 무선.** 개발 중엔 HTTP(RPi5가
      클라이언트) — `NodeRegistry` + `EspNodeController`(`rpi/services/`)로 구현·
      테스트 완료, `/nodes` API로 노드 등록·조회·해제. 본선 데모용 ESP-NOW
      구현체는 아직 없음(ESP32 펌웨어 작업 필요 — 다음 단계).
      과거에 만든 UART 프로토콜(`execute`/`abort` → `result`/`error`,
      `rpi4/services/act_executor.py`)은 폐기하지 않음 — ESP32 노드 안에서
      "ESP32 ↔ RPi4" 로컬 구간에 그대로 재사용(그 구간은 원래도 유선 co-located
      가정이 맞음). `SimpleLayService`가 `appliance_id`로 로컬 기본 컨트롤러
      대신 등록된 노드로 라우팅하도록 배선 완료.
- [ ] ESP32(노드) 펌웨어: RPi5의 HTTP(추후 ESP-NOW) 요청을 받아 RPi4로 UART
      전달하고 결과를 회신 — 아직 구현 안 됨
- [ ] RPi4 ↔ Arduino(X/Y 커스텀 PID): 연결 방식(UART 직결 vs 다른 방식) 미정
- [ ] RPi4 ↔ Z축 BLE 버튼 장치: 연결 방식 미정
- [ ] 센서 → RPi4 입력: GPIO(디지털) vs ADC(아날로그, MCP3008 등) — 센서 종류에 따라
- [ ] 앱의 가전 등록 흐름에 "이 가전의 노드 주소" 입력 추가 (지금은 `/nodes` API만
      있고 앱 UI에서 호출하는 곳이 없음)

## 관련 문서

- [폐루프 설계](closed-loop-design.md)
- [재사용 경계](reuse-boundary.md)
- [구동부 설계](actuator-design.md)
- [로드맵](roadmap.md)
