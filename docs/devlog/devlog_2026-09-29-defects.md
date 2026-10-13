# 2026-09-29 — 본선 준비 결함 4건 수리(웹 키오스크·배포 base href·무키 인증·정지/실패 구분)

[본선 준비 평가(9/21)](../archive/본선-준비-평가-2026-09-21.md)와 [9/21 로그](devlog_2026-09-21.md)에 남은 결함 중
P0 2건·P1 2건을 고쳤다. 9/21에 이미 고친 것(키오스크 연결 유실을 정지로 단정하던 화면)은 다시 손대지 않았다.
**실제 RPi5·Chromium·터치 패널·RPi4 UART로는 확인하지 않았다.** 아래 "확인하지 못한 것"을 먼저 본다.

## 1. P0 — 웹 키오스크가 dart:io(File·Process)를 직접 씀

9/27 브라우저 시뮬레이터 작업에서 설정 저장은 `kIsWeb` 분기로 우회돼 있었지만, 두 서비스 파일이 여전히
`dart:io`를 직접 import했고 음성 안내는 웹에서 `Process.run`이 조용히 실패하는 구조였다.

- 플랫폼 입출력을 `*_io.dart` / `*_web.dart` 쌍으로 분리하고 조건부 import(`if (dart.library.html)`)로만 닿게 했다.
  - 설정: `kiosk_settings_backend_io.dart`(JSON 파일, 원자적 저장·`.bak` 복구 — 종전 로직 그대로 이동) /
    `kiosk_settings_backend_web.dart`(localStorage). 옛 `browser_settings_stub/web.dart`는 삭제.
  - 음성: `kiosk_tts_runner_io.dart`(espeak-ng 프로세스) / `kiosk_tts_runner_web.dart`(브라우저 `speechSynthesis`, ko-KR).
  - `KioskSettingsStore`·`KioskTtsService`는 이제 `dart:io`를 모른다. 저장 매체 생성도 `load()/save()`의 예외 처리 안으로 미뤘다.
- 회귀 테스트 `test/web_platform_boundary_test.dart`: `lib/`에서 `dart:io`는 `*_io.dart`만, `dart:html`은 `*_web.dart`만
  import하고, `*_io.dart`는 웹 짝이 있는 조건부 import로만 쓰이는지 검사한다. **수정 전 `kiosk_tts_service.dart`로
  되돌리면 실패함을 확인**했다.
- 웹 설정은 브라우저 저장소라 Chromium `--incognito`면 재시작마다 사라진다 → `scripts/simplelay-kiosk.service`에서
  `--incognito`를 빼고 전용 `--user-data-dir=/home/pi/SimpleLay/data/chromium-kiosk`, `--hide-crash-restore-bubble`을 넣었다.
- 확인 중 발견해 함께 고침: 웹에서 SSE(`KioskEventStream`)만 `http://localhost:8000` 고정이라 다른 포트로 띄운 서버에서는
  `/events`가 연결 거부되고 폴링으로만 돌았다. `KioskApiService`와 같이 웹이면 같은 오리진을 쓴다.

## 2. P0 — 배포 스크립트의 base href 누락

- `scripts/deploy_kiosk.ps1`: `flutter build web --release --base-href /kiosk/`로 빌드하고, 복사 전에 `index.html`의
  `<base href="/kiosk/">`를 확인해 아니면 멈춘다(`-SkipBuild`로 옛 산출물을 복사하는 경우 포함).
- 이 스크립트는 **BOM 없는 UTF-8이라 Windows PowerShell 5.1에서 파싱 오류**(한글 문자열이 깨져 따옴표가 어긋남)가 났다.
  수정 전 파일도 오류 2건 — UTF-8 BOM으로 저장해 파서 오류 0건을 확인했다.
- 다른 빌드·배포 스크립트: `setup_rpi.sh`는 웹 빌드를 하지 않는다. 문서(`브라우저-시뮬레이터-실행.md`, 9/27 로그)는
  이미 `--base-href /kiosk/`를 쓴다. 누락은 이 스크립트 한 곳이었다.

## 3. P1 — API 키 미설정이면 LAN 전체 개방

`rpi/api/auth.py`가 `SIMPLELAY_API_KEY`가 없으면 모든 요청을 통과시켰다(서버는 `0.0.0.0` 바인딩).

- 새 규칙: 키 미설정 ⇒ **루프백(127.0.0.0/8·::1·IPv4-mapped)만 허용**, LAN 요청은 401과 함께 무엇을 설정할지
  알려주는 문구. 예전처럼 열려면 `SIMPLELAY_ALLOW_UNAUTHENTICATED=1`을 명시해야 하고, 기동 시 경고 로그가 남는다
  (`log_auth_mode()` — 키 없음·루프백 전용 상태도 경고로 남긴다). 키가 설정돼 있으면 개방 플래그와 무관하게 키를 요구한다.
- 같은 보드의 키오스크(Chromium → localhost)와 `/health`는 종전대로 키 없이 동작한다.
- 테스트: TestClient의 피어는 `testclient`(루프백 아님)라, 인증과 무관한 기존 라우터 테스트가 전부 401이 된다.
  `rpi/tests/conftest.py`가 개방 플래그를 기본으로 켜고, `test_auth.py`는 플래그를 지우고 새 규칙을 검증한다
  (LAN 거절·루프백 허용·명시적 개방·잘못된 플래그 값·키 우선·주소 판정·기동 로그). **수정 전 auth 로직에서
  LAN 거절 테스트가 실패함을 확인**했다.
- `setup_rpi.sh`의 환경 템플릿에 새 규칙과 개방 플래그 주석을 더했다.
- **운영 영향:** 키를 설정하지 않은 기기·개발 PC에 폰이 LAN으로 붙으면 이제 401이다. 시연 전 키를 설정하고 앱 설정에
  같은 키를 넣는다. 폰 앱은 바꾸지 않았다.

## 4. P1 — UART 결과가 안전 정지와 일반 실패를 같은 값으로 보냄

RPi4 → RPi5 `result`는 `success=false` 하나라, 정지 요청(abort)으로 멈춘 것과 재시도 소진으로 스스로 안전 정지한
것을 RPi5가 가를 수 없었다. 이력·`/status`·SSE는 둘 다 `safety_stopped`였다.

- `rpi.controller.ExecutionOutcome`(`success`·`failed`·`stopped`·`safety_stop`)과 `outcome_of(result)` 추가.
  로컬 폐루프는 실패 버튼·실패 층이 있으면 `safety_stop`, 없으면(정지 요청) `stopped`로 유도한다.
- RPi4 `ActExecutor`가 `result`에 `outcome`을 싣는다. `success`는 옛 RPi5 호환을 위해 그대로 보낸다.
- RPi5 `ActClient`가 `outcome`을 읽는다. 없거나(옛 RPi4) 모르는 값·`success`와 모순이면 버리고, 합성 결과는 `failed`로
  적는다 — **근거 없이 정지로 추측하지 않는다**(ESP 노드 경로도 같다).
- 명령 계약(`rpi/commands/physical.py`): 원격이 `stopped`를 보고한 집계 결과만 `CommandStatus.STOPPED`,
  `safety_stop`·`failed`는 계속 실패. 문구도 "정지 요청으로 멈췄다고 보고" / "확인 실패로 안전 정지했다고 보고"로 나눴다.
- 노출: `/status`·SSE `status` 이벤트에 `last_outcome`, `/history`·CSV에 `outcome`. `last_status`는 옛 클라이언트용으로
  종전 값 유지. 이력 SQLite는 `outcome` 열을 ALTER로 더하고(기존 DB 보존), 옛 행은 `status`·`termination`에서 보수적으로
  유도한다(사용자 정지로 기록된 것만 `stopped`, 재시도 소진은 `safety_stop`, 그 밖은 `failed`).
- 문서: [protocol.md](../protocol.md) RPi4 → RPi5 절에 표와 호환 규칙.
- 테스트: `rpi/tests/test_result_outcome.py`(유도·파싱·합성·명령 상태·서비스 이력·/status·SSE·/history·CSV·SQLite 이전),
  메모리 파이프 통합(`rpi4/tests/test_act_link_integration.py`)에 abort → `stopped`, 재시도 소진 → `safety_stop`,
  성공 → `success`, outcome을 빼는 옛 RPi4 흉내 → `failed` 4건. 기존 `test_act_executor.py`의 프레임 기대값에 `outcome`
  추가. **수정 전 `act_executor.py`/`physical.py`로 되돌리면 새 테스트가 실패함을 확인**했다.
- **화면은 아직 이 값을 읽지 않는다.** 폰 앱은 지시대로 바꾸지 않았고, 키오스크도 이번에는 손대지 않았다.
  원격(UART) 실행의 실패가 여전히 `last_status=safety_stopped`로 오므로, 키오스크의 정지 안내 문구는 `last_outcome`을
  읽도록 후속 수정이 필요하다.

## 검증

- 백엔드 전체(`--basetemp` 스크래치 경로): **1,779 통과**, 실패 2 — 기존 `test_dbus_native` 1건과, 같은 작업 트리에서
  다른 세션이 진행 중인 승인 계약 변경(`rpi/api/service.py` 등, 이번 커밋에 포함하지 않음)으로 인한
  `test_sequence_limit_gate` 1건. **이 커밋만** 따로 꺼낸 작업 트리에서 다시 돌린 결과는 **1,780 통과, 실패 1**
  (기존 `test_dbus_native`)이다. `tmp_path` 권한 오류는 스크래치 `--basetemp`로 피했다.
- 키오스크: `flutter analyze` error·warning 0(기존 info 1), 비골든 테스트 **145 통과**(`--exclude-tags screenshot`, 골든 미실행),
  `flutter build web --release --base-href /kiosk/` 성공(`index.html`에 `<base href="/kiosk/">`).
- 브라우저 확인(이 PC, 브라우저 시뮬레이터 서버 `127.0.0.1:8791`에 새 빌드를 붙임): `/kiosk/` 첫 화면 표시, 자산 404 없음,
  가전 선택이 localStorage에 저장되고 새로고침 뒤 복원, `speechSynthesis` 존재, 수정 후 SSE `/events`가 같은 오리진으로
  200, 콘솔 오류 없음. 시험 뒤 저장값은 지웠다.
- 서버 기동 로그에 키 미설정 경고가 찍히는 것 확인.

## 확인하지 못한 것

- **실제 RPi5 배포**: `deploy_kiosk.ps1` 전체 실행(ssh/scp), 기기에서 `/kiosk/` 새로고침, cage+Chromium 재시작 뒤
  설정 복원(`--user-data-dir` 변경), `--hide-crash-restore-bubble`이 설치된 Chromium 버전에서 먹는지.
- **RPi Chromium에서 실제 한국어 발화** — 리눅스 Chromium의 `speechSynthesis`는 speech-dispatcher 등 음성 엔진이 없으면
  소리가 나지 않는다. 필요하면 서버 쪽 espeak 경로를 따로 검토한다.
- 네이티브(elinux) 키오스크 빌드는 이 PC에서 만들 수 없어 VM 테스트(dart:io 경로)로만 확인.
- 실제 UART(RPi4 ↔ RPi5)와 실제 모터 — 메모리 파이프·mock 폐루프까지만.
- 폰 앱으로 LAN 401 문구가 어떻게 보이는지.

## 다음

1. 키오스크가 `last_outcome`을 읽어 원격 실패를 "정지"로 안내하지 않게 한다(폰 앱은 팀 결정 뒤).
2. 하드웨어 도착 시 RPi5에서 배포 스크립트·설정 복원·음성 확인.
