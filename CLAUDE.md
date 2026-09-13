# SimpleLay — 작업 규칙 (Claude Code용)

제24회 임베디드SW경진대회 결선 프로젝트. 팀 자비스(박성원 SW / 서예솔 HW).
**현재 시작점:** [교차 평가·후속 개발 계획 (2026-09-09)](docs/교차평가-후속개발계획-2026-09-09.md)
— R1~R5([b](docs/devlog_2026-09-09b.md)) · F4·F1([c](docs/devlog_2026-09-09c.md)) ·
F2([d](docs/devlog_2026-09-09d.md)) · F5·파형([e](docs/devlog_2026-09-09e.md)) ·
다중 가전 계약·시작 화면([f](docs/devlog_2026-09-10f.md)) ·
폰 화면 마감 D1~D3([g](docs/devlog_2026-09-12g.md)) ·
D6 설정 화면 분할([h](docs/devlog_2026-09-13h.md)) ·
D4 키오스크 5상태·D5 감사·개발자 모드 Phase 0([i](docs/devlog_2026-09-13i.md)) ·
개발자 모드 Phase 1(ControlArbiter·정지 경로·env 게이트)+B10·B11([j](docs/devlog_2026-09-13j.md)) ·
Phase 1.1 안전 경합 마감(stopping 상태·예외 settle·start/close 원자화)([k](docs/devlog_2026-09-13k.md)) ·
Phase 1.2 settle×정지 경합(정리 완료까지 점유·세대 확인·fault 보존)([l](docs/devlog_2026-09-13l.md)) ·
Phase 1.3 반납 판정 단일화(_maybe_release_locked 4조건·fault_seq 세대 제한)([m](docs/devlog_2026-09-13m.md)) ·
Phase 1.4 판정 경계 원자화(clear_fault_if_matches·정지 예약)([n](docs/devlog_2026-09-13n.md)) ·
Phase 1.5 반환의 원자화(판정·갱신·release 한 임계구역)([o](docs/devlog_2026-09-13o.md)) ·
Phase 2 개발자 API 계약·통합 테스트·최소 폰 화면(mock 전용)([p](docs/devlog_2026-09-13p.md))
반영 완료. **다음: 하드웨어가 오면 H0~H1(실제 한 가전 폐루프)이 먼저다. 개발자 도구를 실물에 여는 일(`allow_real_adapter`)은 H3·H4 실측 뒤 교차 확인을 거쳐 별도 단계로. B12(키오스크 STT)는 보류 확정.**

기존 일정: [결선로드맵](docs/결선로드맵.md) · 현황: [개발현황](docs/개발현황.md) · 화면별 상세: [앱 개선 백로그](docs/앱-개선-백로그.md) · 작업 기록: `docs/devlog_YYYY-MM-DD.md`

## 🔴 최우선 규칙 — 비공개 자료 보호

- **비공개 제공 자료·코드·문서·실행 출력은 git에 커밋하거나 외부에 전송하지 않는다.** 공개 작업을 이유로 해당 자료를 자동 탐색하지 않는다.
- 로컬 전용 경로와 접근 범위는 사용자가 별도로 지정한다. 지정받지 않았으면 열지 말고 확인한다. PDF·PPTX 및 비공개 자료는 이번 공개 인계 범위 밖이다.
- 별도 허가된 기술 작업도 로컬에서만 수행한다. `.gitignore`는 보조 장치이며 이미 추적되는 파일과 커밋 이력까지 보호하지 않는다.
- 커밋 전 파일 목록과 실제 diff를 확인한다. 공개 문서·로그·주석·커밋 메시지에는 비공개 경로, 내부 API, 원문 출력과 연동 세부를 넣지 않는다.
- `rpi/tests/test_repo_guard.py`가 **추적 중인 파일**을 기준으로 벤더 명칭(내용·파일 이름)과 문서·비밀 파일(`.pptx`·`.pdf`·`.env`·키 등)을 막는다. **이미 추적 중인 파일 하나는 규칙보다 먼저 들어와 있어 목록에 예외로 적혀 있다 — 다시 stage 하거나 갱신하지 않는다.** 가드는 새로 늘어나는 것을 막을 뿐, 이미 커밋된 이력을 되돌리지는 못한다.

## 다음 작업 순서 (2026-09-09 갱신)

1. **작업 폴더·브랜치·HEAD·로컬 변경부터 확인한다.** 변경을 보존하며 최신 main을 받는다. 강제 reset/덮어쓰기하지 않는다.
2. 위의 **최신 인계 문서**를 먼저 읽고, 개발현황 → 결선로드맵 → 앱 개선 백로그 순으로 확인한다. 평가는 `810c8c0` 기준이므로 더 최신 코드에서 이미 해결됐는지 대조한다.
3. **R1~R5 · F4 · F1 · F2 · F5는 반영 완료**(`5f02c6a`~`674362f`). 다음은:
   - **H1 실제 probe·모션 통합** — `rpi4/act_main.py`가 아직 `MockGrblClient`다.
     **하드웨어 도착이 선행 조건**이라 그전까지는 못 닫는다.
   - D1~D6(화면 정보 구조)은 취향 판단이 섞여 있어 스크린샷을 놓고 팀과 함께
     정한다. A2의 음성 파형은 정직함 문제라 먼저 처리했다(`ab31bc7`).
   - 남은 F: F3 가전 상세(D4·백로그 B2와 겹친다).
4. 평가 문서 작성은 결함 수정 완료가 아니다. 각 항목은 재현·회귀 테스트·사용자 행동 확인·devlog·커밋을 근거로 체크한다. 다음 작업 ID를 로그 끝에 남긴다.
5. 디자인은 현재 팔레트를 유지하고 정보 구조부터 정리한다. 화면 전후 캡처를 남기고, 팀 미결인 설정 발견성은 인계 문서의 권고안으로 협의한다.
6. **완료의 경계를 흐리지 않는다.** F1·F2·F5는 소프트웨어 계약까지다 — F1의 실제 readiness probe, F2의 폰 2대 편집 충돌 검증, F5의 날짜 경계 실기기 확인은 기기·시간 대기. F4의 원격 실행 모드는 노드가 보고하기 전까지 `unknown`이다. 음성 파형의 음량 정규화 상수는 안드로이드 실기기에서 확인해야 한다. H1은 미착수다.
7. 공개 코드 인계가 비공개 자료 탐색·반출 허용을 의미하지 않는다. 비공개 자료·PDF·PPTX는 열지도 커밋하지도 않는다. 별도 허가된 작업의 원문·로그도 로컬에만 둔다.

### 최신 검증 기록을 해석하는 법

- **2026-09-13 Phase 2 세션 종료 시점에 노트북에서 직접 확인(`0ecc36f`):** 백엔드 **912** · 폰 **325**(골든 51장 별도 — 이번에 재실행하지 않았다. 진입 타일이 고급 설정 안이라 골든 구획 밖) 통과. 폰 `flutter analyze` error·warning 0(info 5건 전부 기존 파일). 키오스크는 이 세션에서 건드리지 않았다(직전 확인 **90**, 골든 20장 별도). 키오스크 `flutter analyze` error·warning 0 — 기존 info가 있어 exit code는 1이 정상이다.
- **시계를 쥐지 않은 테스트는 날짜가 넘어가면 깨진다.** 판정 시각을 고정했다면 레지스트리·서비스의 시계도 고정한다(`bb713b3`에서 같은 결함을 두 번째로 고쳤다).
- **커밋 게이트:** 셸 체인에서 `flutter analyze | tail -1`처럼 출력을 자르면 오류가 있어도 `&&`가 통과한다(실제로 `3f67318`이 빨간 채로 올라갔다). analyze 오류·경고 개수가 0이고 테스트 출력에 `All tests passed`가 있을 때만 커밋한다.
- 테스트 개수를 적을 때는 **골든 포함 여부를 명시**한다.
- 위젯 테스트에서 기기 저장소 같은 **진짜 비동기**를 그냥 await 하면 가짜 시계 위라 영원히 멈춘다 — `tester.runAsync`로 감싼다.
- 교차 평가 시점에 "시스템 Python에 pytest 없음"으로 백엔드를 못 돌린 기록이 있는데, 리포 루트 `.venv`를 다시 만들어 해소됐다(`pip install -e .` 자체가 깨져 있던 것은 `2eb5207`에서 수정). 위 개발 환경 절의 설치 명령을 쓴다.
- 골든 이미지의 네모 아이콘은 테스트 폰트 로딩 제한이다. `docs/screenshots/`는 개편 전 화면이므로 최신 디자인 근거로 사용하지 않는다.

## 커밋 규칙

- 작업 단계마다 1커밋, 한국어 conventional commit (`fix(app): …`, `feat(rpi): …`)
- **Claude 관련 문구(Co-Authored-By 등) 절대 금지**
- 커밋 후 `git push origin main`. 작업 세션마다 devlog에 기록.

## 개발 환경 (Windows 노트북 기준 — 새 기기는 유사하게 구성)

- 한글 경로에서 Dart analysis server 문제가 발생한 이력이 있어 ASCII 정션 경유를 권장:
  먼저 `C:\dev-simplelay`의 대상이 현재 저장소인지 확인한다. 없으면 `New-Item -ItemType Junction -Path C:\dev-simplelay -Target <리포경로>` 후 그 경로에서 flutter 실행. 기존 정션을 무작정 덮어쓰지 않는다.
- 백엔드: 리포 루트 `.venv` (fastapi·uvicorn·pydantic·numpy·pytest·httpx·dbus-fast)
  없으면 `py -m venv .venv` 후 `.\.venv\Scripts\python.exe -m pip install -e ".[test]"`
- 테스트는 줄 단위로 실행하고 각 종료 코드를 확인한다(PowerShell 5.1에서는 `&&` 사용 불가):
  - 백엔드: 확인된 Python 환경에서 `python -m pytest` 또는 기존 `.\.venv\Scripts\python.exe -m pytest`
  - 폰 `app/`: `flutter analyze`, `flutter test --exclude-tags screenshot`
  - 키오스크 `rpi5-touchscreen-app/`: `flutter test --exclude-tags screenshot`
  - 골든은 생성 환경에서 별도로 검증한다. 테스트 개수에 골든 포함 여부를 명시하고, 실제 실행 결과로 수치를 갱신한다.
- 릴리즈 APK: `flutter build apk --release` (JDK17 + Android SDK 필요)

## 아키텍처 요점 (자세히는 docs/개발현황.md)

- 실행은 **비동기 job 모델**: POST /execute → 즉시 job_id, 완료는 /status의 last_job_id 대조
- 오프라인 우선: 모든 실기기 의존은 env 게이트(`SIMPLELAY_*`), 기본은 mock — 개발 PC에서 전 기능 동작
- 클라이언트: 폰(app/), 키오스크(rpi5-touchscreen-app/, flutter-platform 구조) — 서비스는 생성자 주입으로 테스트
- 리허설 API: `POST /demo/suggest`(제안 강제 생성), `POST /demo/inject-failure`(검증 실패 주입)
- 개발자 API(`/dev/*`): `SIMPLELAY_DEV_MODE` + `SIMPLELAY_DEV_TOKEN`(일반 API 키와 별개), **mock 전용**. 계약은 `rpi/api/dev_router.py` 머리말, 제어권 반환 규칙은 `rpi/services/developer_session.py`의 `_maybe_release_locked`가 유일한 반환 지점

## 방향 원칙

- AI 고도화 금지(지도교수 방침) — 기존 모듈을 배선만. HW 완성도가 차별점
- 심사 키워드: 공감지능(패턴) · 공간 이해/초개인화 · 온디바이스/클라우드 추론 경계(docs/inference-boundary.md가 답)
- 접근성: docs/사용자편의-가이드-체크리스트.md 기준(국가표준 매핑) 준수
