# SimpleLay — 작업 규칙 (Claude Code용)

제24회 임베디드SW경진대회 결선 프로젝트. 팀 자비스(박성원 SW / 서예솔 HW).
**현재 시작점:** [교차 평가·후속 개발 계획·데스크탑 인계 (2026-09-09)](docs/교차평가-후속개발계획-2026-09-09.md)

기존 일정: [결선로드맵](docs/결선로드맵.md) · 현황: [개발현황](docs/개발현황.md) · 화면별 상세: [앱 개선 백로그](docs/앱-개선-백로그.md) · 작업 기록: `docs/devlog_YYYY-MM-DD.md`

## 🔴 최우선 규칙 — 비공개 자료 보호

- **비공개 제공 자료·코드·문서·실행 출력은 git에 커밋하거나 외부에 전송하지 않는다.** 공개 작업을 이유로 해당 자료를 자동 탐색하지 않는다.
- 로컬 전용 경로와 접근 범위는 사용자가 별도로 지정한다. 지정받지 않았으면 열지 말고 확인한다. PDF·PPTX 및 비공개 자료는 이번 공개 인계 범위 밖이다.
- 별도 허가된 기술 작업도 로컬에서만 수행한다. `.gitignore`는 보조 장치이며 이미 추적되는 파일과 커밋 이력까지 보호하지 않는다.
- 커밋 전 파일 목록과 실제 diff를 확인한다. 공개 문서·로그·주석·커밋 메시지에는 비공개 경로, 내부 API, 원문 출력과 연동 세부를 넣지 않는다.

## 데스크탑에서 이어서 작업할 때 (2026-09-09 인계)

1. **작업 폴더·브랜치·HEAD·로컬 변경부터 확인한다.** 변경을 보존하며 최신 main을 받는다. 강제 reset/덮어쓰기하지 않는다.
2. 위의 **최신 인계 문서**를 먼저 읽고, 개발현황 → 결선로드맵 → 앱 개선 백로그 순으로 확인한다. 평가는 `810c8c0` 기준이므로 더 최신 코드에서 이미 해결됐는지 대조한다.
3. 다음 순서: **R1 실행 대상 검증 통합 → R2 실제/모의 실행 분리 → R3 다중 폰 동기화 삭제 안전성 → R4 알림 조회 상태 → D1/D2 홈·제안 동선**. 실기기를 사용할 수 있으면 H1 물리 폐루프 통합을 병행한다.
4. 평가 문서 작성은 결함 수정 완료가 아니다. 각 항목은 재현·회귀 테스트·사용자 행동 확인·devlog·커밋을 근거로 체크한다. 다음 작업 ID를 로그 끝에 남긴다.
5. 디자인은 현재 팔레트를 유지하고 정보 구조부터 정리한다. R1~R3를 끝내기 전에 대규모 UI 개편이나 추가 AI 기능으로 범위를 넓히지 않는다. 화면 전후 캡처를 남기고, 팀 미결인 설정 발견성은 인계 문서의 권고안으로 협의한다.
6. 공개 코드 인계가 비공개 자료 탐색·반출 허용을 의미하지 않는다. 이번 교차 리뷰에서는 비공개 자료·PDF·PPTX를 열지 않았다. 별도 허가된 작업의 원문·로그도 로컬에만 둔다.

### 최신 검증 기록을 해석하는 법

- **2026-09-09 R1~R5 반영 후 이 기기에서 직접 확인:** 백엔드 668 · 폰 226(골든 12 포함) · 키오스크 52 통과. 폰 `flutter analyze` 경고 0.
- 테스트 개수를 적을 때는 **골든 포함 여부를 명시**한다. `--exclude-tags screenshot`이면 폰은 214다.
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

## 방향 원칙

- AI 고도화 금지(지도교수 방침) — 기존 모듈을 배선만. HW 완성도가 차별점
- 심사 키워드: 공감지능(패턴) · 공간 이해/초개인화 · 온디바이스/클라우드 추론 경계(docs/inference-boundary.md가 답)
- 접근성: docs/사용자편의-가이드-체크리스트.md 기준(국가표준 매핑) 준수
