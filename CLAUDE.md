# SimpleLay — 작업 규칙 (Claude Code용)

제24회 임베디드SW경진대회 결선 프로젝트. 팀 자비스(박성원 SW / 서예솔 HW).
실행 계획·체크리스트: [docs/결선로드맵.md](docs/결선로드맵.md) · 현황: [docs/개발현황.md](docs/개발현황.md) · 작업 기록: docs/devlog_YYYY-MM-DD.md

## 🔴 최우선 규칙 — LG 기술 자료

- **LG(대회 플랫폼) 관련 자료·코드·문서는 절대 git에 커밋/푸시 금지.** NDA 대상.
- 분석·작업은 반드시 `.gitignore`에 등록된 로컬 전용 경로에서만:
  `dev-docs/`, `AI-Native-OS-Samples/`, `platform_docker_env/` (이 폴더들은 기기 간 git으로 이동하지 않음 — 필요 시 수동 복사)
- 커밋 전 `git status`로 기밀 파일 미포함 확인. 커밋 메시지·코드 주석에도 플랫폼 내부 세부(NDA)를 쓰지 않는다.
- 코드상 플랫폼 연동 지점: `rpi/intent/dbus_internal_ai.py`, `rpi/intent/dbus_vectordb.py` (출력 파싱은 실기기 검증 대기)

## 커밋 규칙

- 작업 단계마다 1커밋, 한국어 conventional commit (`fix(app): …`, `feat(rpi): …`)
- **Claude 관련 문구(Co-Authored-By 등) 절대 금지**
- 커밋 후 `git push origin main`. 작업 세션마다 devlog에 기록.

## 개발 환경 (Windows 노트북 기준 — 새 기기는 유사하게 구성)

- 리포 경로에 한글이 있으면 **Dart analysis server가 크래시** → ASCII 정션 경유:
  `New-Item -ItemType Junction -Path C:\dev-simplelay -Target <리포경로>` 후 그 경로에서 flutter 실행
- 백엔드: 리포 루트 `.venv` (fastapi·uvicorn·pydantic·numpy·pytest·httpx)
- 테스트 (PowerShell 5.1은 `&&` 불가, `;` 사용):
  - `.\.venv\Scripts\python.exe -m pytest` (백엔드 464개)
  - `cd C:\dev-simplelay\app; flutter analyze; flutter test` (폰 125개)
  - `cd C:\dev-simplelay\rpi5-touchscreen-app; flutter test` (키오스크 33개)
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
