# 로드맵

> RPi 레이어(SimpleLay 신규 핵심) 중심. 구동부(CoreXY 갠트리)도 자체 설계로 바뀌어서
> 재사용 비중이 낮아졌다 — 자세한 내용은 [reuse-boundary.md](reuse-boundary.md) 참고.

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
      (`rpi/intent/dbus_vectordb.py`, `com.platform.internal_aiVectordb1`). 규칙기반
      (정확일치) → 벡터DB(빠른 유사도 매칭) → LLM(유연한 대화형 해석, 가장 느림)
      순으로 `TieredIntentResolver`에 계층화하는 용도 — Dbusinternal_aiLlmClient와
      역할 분담. **CAUTION: AddText/SearchText의 정확한 internal_gpio 출력 포맷은
      아직 실기기 미검증**(RPi5 오프라인 상태에서 작업) — 파싱 로직은
      `rpi/intent/dbus_vectordb.py` 모듈 docstring에 명시된 대로 최선의 추정이며
      독립적으로 교체 가능하게 분리해둠. 리졸버 자체 로직(임계값 판정, 메타데이터
      파싱, 티어 조합)은 fake client로 완전히 검증됨(테스트 26개)

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
- [ ] RPi4 ↔ Arduino/BLE 버튼 장치 연결 방식
- [ ] 검증 센서 최종 선택 (전류/음향/접점 조합)
- [ ] 액추에이터 프레임 강성 실측 (가운데 개방형 설계 — [actuator-design.md](actuator-design.md) 참고)
