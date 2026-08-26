# 로드맵

> RPi 레이어(SimpleLay 신규 핵심) 중심. 구동부(CoreXY 갠트리)도 자체 설계로 바뀌어서
> 재사용 비중이 낮아졌다 — 자세한 내용은 [reuse-boundary.md](reuse-boundary.md) 참고.

> **지도교수 미팅(8/18) 방향 확정**: 이 프로젝트의 차별점은 하드웨어다 — AI 고도화에
> 더 투자하지 말고 지금 수준(규칙기반→유사도매칭→온디바이스 대화형AI)을 "그대로 쓰는
> 모듈"로 고정, 남은 역량은 전부 하드웨어 완성도(M1/M3, CoreXY 제작, Z축 통합)에 투입.
> **다음 미팅: 10/2(금) 12시** — 그때까지 하드웨어 프로토타입 실동작이 목표.
> 최종 제출은 10/30. 발표 자료에는 완성도뿐 아니라 실사용자 검증(다양한 사용자
> 시나리오로 테스트해본 사진·피드백)을 통한 "여기까지 고민했다"는 스토리도 필요.

---

## 마일스톤

### M1 — 센서 읽기
- [ ] 보유 라즈베리파이에서 전류 센서 값 읽기 (ACS712 등 + ADC)
- [ ] 마이크로 버튼 클릭음/비프음 감지 (임계 또는 간단 FFT)
- [ ] "눌림 vs 안눌림"을 구분하는 최소 신호 확정 (실측 기반)
- [x] 마이크로 화재·가스 경보음(위험소리) 감지 1차 구현 — `DangerSoundDetector`
      (대역 에너지 + 온셋 주기성, 완료음 같은 유한 반복과 구분). 실제 마이크
      결선은 위 항목들과 함께 아직 남음 — 알고리즘·UART 알림 경로만 선행 완료

### M2 — RPi ↔ 액추에이터 통신

> **확정 아키텍처(8/17)**: RPi5는 중앙 허브 하나, RPi4(+ESP32)는 가전마다 여러 대가
> 각자 다른 위치에 붙는다 — RPi5↔RPi4가 같은 하우징에 유선 직결된다는 초기 가정은
> 폐기됨. 아래 UART 항목들은 그 가정 하에 만든 첫 구현이라 메시지 설계·검증 로직은
> 계속 재사용하되, 실제 전송은 가전 옆 ESP32를 거친 무선(개발 중 HTTP, 본선 데모
> ESP-NOW)으로 이어간다 — 지금 만든 `NodeRegistry`/`EspNodeController`가 그 전환의
> 첫 단계.

- [x] RPi5 ↔ ESP32 UART 확정 및 구현 (`rpi/services/bridge.py`)
- [x] RPi5 ↔ RPi4 UART 방향 확정, RPi4 쪽 실행기 구현 (`rpi4/act_executor.py`)
- [x] RPi4 → RPi5 자체발신 알림 채널 추가 (`alert`/`alert_cleared`) — 위험소리
      감지 결과를 RPi5가 요청하지 않아도 즉시 푸시
- [x] RPi5 → RPi4 UART 클라이언트 구현 (`rpi/services/act_client.py`) —
      `execute`/`abort` 송신, `result`/`error`/`alert`/`alert_cleared` 수신까지
      프로토콜 레벨로 완결(ActExecutor의 정확한 미러). `rpi4/tests/
      test_act_link_integration.py`에서 진짜 `ActClient`↔`ActExecutor`를
      메모리 파이프로 직접 연결해 상호운용까지 검증함(양쪽 다 fixture가 아닌
      서로에게 실제로 응답)
- [x] `SimpleLayService`가 실제로 RPi4에 연결되도록 배선 — `ActClientController`
      (`rpi/services/act_client_controller.py`)가 동기↔비동기 다리 역할:
      전용 이벤트루프 스레드를 띄우고 `run_coroutine_threadsafe`로 `ActClient`를
      부름. `SIMPLELAY_ACT_MODE=uart` 환경변수로 켬(기본은 여전히 로컬 mock,
      오프라인 우선 원칙 유지). **의도적으로 집계 결과(success/retry)만
      받음** — 버튼별 실시간 진행상황(`/status`의 current_button 등)은 이
      모드에서 계속 비어 있음(사용자 확인 후 결정한 범위)
- [x] alert 표면화 — `GET /alerts` 엔드포인트(`DangerAlertStore`, `rpi/services/
      alert_store.py`)가 RPi4의 자체발신 alert/alert_cleared 최신 상태를 노출.
      env var 선택 로직은 `_build_controller`를 `rpi/services/controller_factory.py`
      의 공유 `build_controller()`로 옮겨서 정리(중복 제거)
      - `UartBridge`(ESP32 경로, `rpi4/services/bridge.py`)는 **의도적으로 아직
        이 배선을 안 씀** — 조사해보니 "값싼 후속 작업"이 아니었음: `rpi4/main.py`
        (ESP32 브릿지)와 `rpi/main.py`(FastAPI 앱)는 RPi5에서 각각 별도 프로세스로
        떠서, 둘 다 `SIMPLELAY_ACT_MODE=uart`를 켜면 같은 RPi5→RPi4 물리 UART
        포트를 서로 다른 프로세스가 동시에 열려고 시도하게 됨(포트 하나를 두
        프로세스가 나눠 쓸 방법이 지금 없음). 두 경로를 정말 동시에 UART로
        RPi4에 연결하려면 (a) 두 프로세스를 하나로 합치거나 (b) RPi4 포트를
        중개하는 공유 프로세스를 새로 만들어야 함 — 결정 필요, 사용자와 상의 후
        진행
- [ ] RPi4 ↔ Arduino(X/Y)·BLE 버튼 장치(Z) 연결 방식 확정 및 응답 파싱
- [x] 다중 노드 라우팅 계층 — `NodeRegistry`(`rpi/services/node_registry.py`)가
      appliance_id → 노드 컨트롤러를 관리, `SimpleLayService`가 요청에 실린
      appliance_id로 로컬 기본 컨트롤러 대신 등록된 노드로 라우팅
      (`/execute`, `/execute-buttons`, `/execute-for-appliance` 전부 지원,
      appliance_id 없거나 미등록이면 기존처럼 로컬 실행 — 완전히 하위호환).
      노드 등록·조회·해제용 `POST/GET/DELETE /nodes` 엔드포인트 추가.
      개발용 전송 구현체로 `EspNodeController`(HTTP, RPi5가 클라이언트) 완성 —
      ESP-NOW 구현체는 아직(별도 하드웨어·펌웨어 작업 필요, 인터페이스만 맞으면
      `NodeRegistry`의 `controller_factory`만 바꿔서 교체 가능하게 설계함)
- [x] ESP32 노드 펌웨어 스캐폴딩 — `firmware-node/`(신규 PlatformIO 프로젝트,
      `firmware/`의 폰 폴백 브릿지와는 별개). WiFi + HTTP 서버로 `POST /execute`
      받아서 UART로 RPi4에 `execute` 전달, `result`/`error` 기다렸다가 집계
      결과(success/retry)로 HTTP 응답 — `EspNodeController`가 기대하는 그
      모양 그대로. RPi4가 자체발신하는 alert/alert_cleared도 상시 흡수해서
      `GET /alerts`로 노출(Python 쪽 `EspNodeController`는 아직 이 엔드포인트를
      안 씀 — 후속 작업). **미검증**: 이 환경에 PlatformIO 툴체인이 없어서
      실제 컴파일/빌드/플래시 확인을 못 함 — 다음에 실기기로 확인 필요
- [ ] ESP-NOW 전송 구현체 (본선 데모용, Wi-Fi 혼잡 무관) — `firmware-node/`에
      HTTP 서버 옆에 추가할 예정, 인터페이스(ExecuteHandler/AlertsHandler)는
      이미 전송 방식과 무관하게 고정해둠
- [x] 앱의 가전 등록 흐름에 "이 가전을 담당하는 노드 주소" 입력 추가 — 커스텀 가전
      등록 화면(`appliance_editor_screen.dart`)에 노드 주소(선택) 입력 필드,
      저장 시 `POST /nodes/{appliance_id}`로 등록. `execute`/`execute-buttons`/
      `execute-for-appliance` 호출부(`manual_control_screen.dart`,
      `voice_screen.dart`)에도 `appliance_id` 실어 보내도록 배선 완료.
      자동 검색(노드가 스스로 광고하는 방식)은 아직 — 지금은 수동 입력만
- [x] `docs/architecture.md`의 "확정된 아키텍처" 절 정정 완료

### M3 — 폐루프 ★ (결선 데모 핵심)
- [ ] 명령 → 센서 검증 → 실패 시 좌표 보정 후 재시도 (1회)
- [ ] 버튼 시퀀스 전체에 폐루프 적용
- [ ] **실패 유발 → 자동 복구 시연** 성공

### M4 — 공감지능
- [x] 사용 로그 적재 (시간대·목적·결과) — `UsageLog` + 인메모리 구현
- [x] 반복 패턴 감지 → 다음 동작 선제 제안 — 임계값·시간대 설정 주입
- [x] 제안 → 사용자 1회 승인 → 기존 intent→controller 폐루프 실행
- [x] 앱 화면에 실제 제안 표시·승인 연결 — HTTP `/suggestions` 폴링을 폰 앱에 연결 완료
      (BLE로 온 제안과 출처를 구분해서 합침, 승인/거부도 출처에 맞는 채널로)

> 현재 사용 로그는 프로세스 메모리에만 저장된다 — 실제 DB 구현은 아직 남은 작업.
> 시간대 구간과 반복 임계값은 실측값으로 간주하지 않고 기기/사용자 정책 설정으로 주입한다.

### M5 — 앱 연동 + 로그
- [x] 앱에 검증 결과/재시도 상태 표시 — `/status`가 현재 버튼·시도 횟수·검증 신뢰도를
      실시간 노출, 상태 화면에서 확인 가능
- [ ] 실행 이력·성공률 로그 조회 (DB 영속화 이후)

### M6 — 범용 가전 대응
- [x] 앱 내 가전 등록(그리드 에디터) + 버튼 직접 실행 (`/execute-buttons`, 의도 해석 우회)
- [x] 등록한 가전도 음성 명령으로 조작 가능하게 확장 — `/execute-for-appliance`,
      요청에 실린 버튼 라벨 어휘로 LLM이 그 자리에서 해석 (서버 고정 규칙 없이도 동작).
      LLM 미설정 시 503으로 명확히 거부 — 서버는 기본적으로 오프라인 동작
- [x] 위 기능의 온디바이스 LLM 백엔드 구현 — `Dbusinternal_aiLlmClient`
      (`SIMPLELAY_LLM_MODE=dbus`). 실기기 검증까지 완료: 온보드 에이전트
      서비스에 요청을 보내고 비동기 응답 스트림을 받아 조립하는 전체 경로가
      실제로 동작함을 확인. 클라우드 API 경로(`SIMPLELAY_LLM_BASE_URL`)는
      데모 시 대체 수단으로 계속 유지 — 운영자가 환경변수로 명시적으로 선택
- [x] 사진 기반 버튼 위치 등록 — 컴퓨터비전 없이 순수 기하학으로: 가전 사진을
      찍으면 기존 수동 그리드 에디터를 그 위에 반투명으로 겹쳐서, 실제 버튼
      위치를 보며 이름을 붙일 수 있음. 새 하드웨어·백엔드 연동 불필요(100% 앱)
- [x] 온디바이스 벡터DB 유사도 매칭 — `VectordbIntentResolver`
      (`rpi/intent/dbus_vectordb.py`). 규칙기반
      (정확일치) → 벡터DB(빠른 유사도 매칭) → LLM(유연한 대화형 해석, 가장 느림)
      순으로 `TieredIntentResolver`에 계층화하는 용도 — 온디바이스 LLM 클라이언트와
      역할 분담. **CAUTION: 검색·등록 호출의 정확한 출력 텍스트 포맷은
      아직 실기기 미검증** — 파싱 로직은
      `rpi/intent/dbus_vectordb.py` 모듈 docstring에 명시된 대로 최선의 추정이며
      독립적으로 교체 가능하게 분리해둠. 리졸버 자체 로직(임계값 판정, 메타데이터
      파싱, 티어 조합)은 fake client로 완전히 검증됨
- [x] 위 두 계층의 응답 처리 결함 수리(8/26) — 인터페이스 대조로 확인. 검색 결과에서
      metadata를 버려 유사도 계층이 항상 폴스루하던 문제, 필드 순서 오독, 도구 호출
      진행 알림이 답변에 섞이던 문제, 대기 포기 시 상대에게 중단을 안 알리던 문제.
      파서→리졸버 이음매 테스트 추가 (백엔드 464 → 475)

---

## 예선 심사평 대응 (결선 개발 항목)

| 심사평 지적 | 대응 | 담당 계층 |
| --- | --- | --- |
| 구동 전력·전원 관리 | 12V 별도 전원·퓨즈, 전력 버짓 문서화 (**미완 — 우선순위 높음**) | 하드웨어 |
| 가전별 버튼 맵 일반화 | ✅ 앱 내 그리드 에디터로 좌표 프로필 등록·기기별 저장 완료(사진 매핑은 아직 — 수동 배치만) | app / intent |
| 액추에이터 장착 안정성 | 3D 프레임 + 수직 마운트 + 스프링 완충 | 하드웨어 |
| 다이얼/누름 오차 보정 | **폐루프 재시도(검증 실패 시 보정)** | verifier / controller |

> "다이얼 오차 보정"은 폐루프(closed-loop-design.md)로 자연스럽게 커버된다.

---

## 리스크 / 결정 대기

- [ ] 전력 버짓 문서 (심사평 유일한 미답 항목 — 결선 전 필수)
- [x] RPi4 ↔ Z축(스위치봇 모터) 연결 방식 — **결정됨(8/18 지도교수 미팅)**: 스위치봇의
      블루투스 제어보드는 쓰지 않음(중앙 RPi4 제어와 분리된 별도 제어계가 되고, OEM
      펌웨어라 커스텀 제어 불가). 모터만 재사용하고 별도의 소형 MCU + 모터드라이버로
      직접 구동 — 배터리 제거, 앞쪽 하우징 구조는 그대로 재사용하고 드라이버 보드는
      뒤쪽으로 옮겨 선을 길게 연결. 아직 실제 부품 조달·제작은 안 됨(다음 단계)
- [ ] 검증 센서 최종 선택 (전류/음향/접점 조합)
- [ ] 액추에이터 프레임 강성 실측 (가운데 개방형 설계 — [actuator-design.md](actuator-design.md) 참고)
