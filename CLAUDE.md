# SimpleLay — 작업 규칙 (Claude Code용)

제24회 임베디드SW경진대회 결선 프로젝트. 팀 자비스(박성원 SW / 서예솔 HW).
이 파일은 **지금 작업할 때 필요한 지침과 현재 상태**만 둔다. 날짜별 지난 기록(옛 인계 요약·외부 평가 점수·과거 시험 수·9/13~9/17 동결 문단)은
지우지 않고 [작업 규칙 지난 기록](docs/archive/작업규칙-지난-기록-2026-10-14.md)으로 옮겼다(2026-10-14, [정리 devlog](docs/devlog/devlog_2026-10-14-public-docs.md)).

## 현재 상태 (2026-10-19 — 새 세션은 여기부터)

- **작업 장소·네트워크(10/15~):** 하드웨어는 학교와 집을 오가며 노트북·데스크톱 둘 다에서 다룬다(10/16~18은 집·데스크톱, 같은 날 노트북 세션도 작업 — 동시 작업 때는 `git pull --rebase` 먼저). 학교망(유선·802.1X Wi-Fi)은 기기끼리 서로 보이지 않아 **RPi5·RPi4는 팀 폰 핫스팟**에 붙인다(두 보드 모두 등록돼 핫스팟을 켜면 자동 접속, 인터넷 됨). 핫스팟은 주소 예약이 안 되므로 주소가 바뀌면 RPi4 env `SIMPLELAY_LINK_ALLOW_FROM`(RPi5 주소)과 RPi5 env `SIMPLELAY_UART_PORT=socket://<RPi4 주소>:7000`을 고친다(바꾸기 전 env는 `env.bak-날짜-이유`로 백업). 랜선을 노트북↔보드에 직결하면 IPv6 링크 로컬로 비상 접속할 수 있다. RPi5는 RTC 배터리가 없어 인터넷 없이 켜면 시각이 멈춰 있다 — 핫스팟에 붙으면 맞고, 아니면 노트북 시각으로 맞춘다. 결선은 여행용 공유기(주소 예약) 권장.
- **배포(보드에서 빌드):** RPi5에서 `git archive HEAD rpi rpi4 deploy .dockerignore`를 `/mnt/rawdata/simplelay-build/`에 풀고 `sh deploy/build_on_device.sh`(AppArmor 때문에 `docker build` 불가) → `deploy/run_backend.sh`(보드에 상주하지 않음 — 매번 복사해 실행). 같은 이미지를 RPi4로 `docker save | gzip` → `gunzip | docker load`로 옮긴다(Windows에서는 **Windows OpenSSH**로 파이프 — PowerShell 5.1 파이프는 바이너리를 깨뜨린다) → RPi4 `sh /mnt/rawdata/run_act.sh`. 되돌리기용으로 직전 이미지에 날짜 태그(`simplelay-backend:1014`). 키오스크 ipk는 **저장소 밖 로컬 전용 플랫폼 빌드 환경**이 필요하다(커밋·외부 전송 금지).
- **10/19 (집·데스크톱):** 새 기능 금지, 처음 쓰는 사람 기준 다듬기만(사용자 결정). 타일 밝기=켜짐, 음성 규칙 계층·'혹시 이것?' 후보, `/acks`(확인을 본체에 저장, 화면에 보인 데까지만), 검토 결함 높음 2·중간 2 수리 → RPi5·RPi4·키오스크·폰 **`d23506da`** 배포(되돌리기 `simplelay-backend:1019b`). 시연 정리로 미설정 세탁기·인터폰 삭제(DB 백업 `simplelay-backup-2026-10-19-before-demo-cleanup.db`). 냉정 평가 HW 가정 78·실물 60. **개발자 모드를 끄면 내장 전자레인지가 목록에서 숨는다 — 결선 전 결정 필요.** [10/19 devlog](docs/devlog/devlog_2026-10-19-first-user.md).
- **보드 배포 상태(10/18 밤 집·데스크톱):** RPi5·RPi4 백엔드 = `2c364a5a` 이후(누름 장치 이름·인덕션 판정·연습 세탁기, 되돌리기 `simplelay-backend:1018c`), 키오스크·폰 APK = `4813ac78`/`ecddfc36` 이후. RPi5 env `SIMPLELAY_THINQ_PRACTICE_DEVICES=washer`(연습 세탁기, 백업 `env.bak-20261018-practice-washer`). 밤 평가·수리는 [밤 devlog](docs/devlog/devlog_2026-10-18-night-eval.md). 10/17~18 교수 의견 대응 UI 개편과 반복 평가(58→92.25, 97 미달에서 멈춤 — UI 동결)는 [10/18 devlog](docs/devlog/devlog_2026-10-18-professor-ui.md), 방향 조정은 [노트북 검토 인계](docs/인계-2026-10-18-노트북-검토.md), 남은 손볼 점은 [목록](docs/UI-남은-손볼점-2026-10-18.md). **컨테이너 재시작 정책은 `always`**(10/18 — 손으로 `docker stop` 해 둔 컨테이너가 재부팅 뒤 안 떠 키오스크가 안 나왔다). **보드를 끌 때 컨테이너를 멈추지 말고 `sync; poweroff`만.** RPi4는 시스템 영역이 읽기 전용이라 도커가 부팅 때 자동으로 안 켜진다 — 재부팅 뒤 `systemctl start docker`. 배포 때 이름 없는 옛 이미지를 `docker image prune -f`로 정리(10/18 RPi5 저장 공간 100%로 빌드 실패). 키오스크 설치 도구는 TTY가 있어야 한다(`docker exec -t …`, 설치 응답 'Success' 확인). **자동 실행 규칙(실제 공기청정기):** '저녁 공기청정기 켜기' 매일 22:00 · '아침 공기청정기 끄기' 매일 07:00 켜짐(22:00 카드 없이 켜기 실물 `state_confirmed`), '가열 종료 → 공기청정기' 꺼짐. 시연 데이터 정리(시험 가전·'시험 저녁 끄기' 삭제, DB 백업 `simplelay-backup-2026-10-16-before-cleanup.db`). 집 주소로 되돌림(집 공유기 고정 주소 — 실제 값은 저장소 밖 메모) — 학교 핫스팟으로 가면 env 두 줄을 다시 고친다(위 줄). **ESP32 모션 보드는 HW 담당이 솔레노이드·레일 작업으로 가져가 RPi4는 모의 모션**(`SIMPLELAY_MOTION_MODE=mock`, `SIMPLELAY_MOTION_PORT` 줄 주석, 백업 `env.bak-20261016-no-esp32`) — 돌아오면 두 줄을 되돌리고 RPi4에서 esptool로 시험대 펌웨어를 다시 올린다(10/15 HW 시험용 펌웨어가 올라가 있다). **RPi5 ThinQ 실제 모드 켜짐**(PAT 파일 사용자 직접, `SIMPLELAY_THINQ_MODE=real`): 공기청정기 발견·추가·상태 읽기·전원 켜기 `state_confirmed` 실물 확인 — [devlog](docs/devlog/devlog_2026-10-16-desktop-home.md).
- **최신 인계:** [인계 2026-10-13 데스크톱](docs/인계-2026-10-13-데스크톱.md)(§8 다음 보드 날). 문서 입구는 [docs/README.md](docs/README.md), 심사위원용 입구는 [README](README.md).
- **결선 전 SW·보안·UI 보완 기준:** 새 작업을 시작하기 전에 [결선 전 SW 보완 피드백](docs/결선전-SW-보완-피드백.md)과 [UI 제품 앱·공개 레퍼런스](docs/ui-product-app-references.md)를 읽는다. 결선 직전에는 새 기능보다 실물 통합 실행 기록, 실패 시 안전 전환·정확한 문구·복구 안내, 결선망 통신 보안, 조용한 시간·자동 실행 상태·큰 글씨·접근성의 일관성을 우선한다. 레퍼런스는 복사하지 않고 정보 우선순위·상태 표현·자동화 흐름만 SimpleLay 안전 계약에 맞게 적용한다.
- **결선 일정(사무국 2026-09-30):** 서류 제출 **10/28(수) 14:00** 구글폼 — 개발완료보고서(PDF)·작품소개서(한글/워드)·시연 영상 URL·공개 GitHub URL, 책자로 사전 배포·수정 불가. 발표 **11/6(금)** DMC타워, 자비스 B조 설치 14:50~15:20·**평가 15:40~16:00**(시연·발표 10분+질의 10분, 시연 중심). 책상 150×55cm ×2.
- **시연 기준:** [본선 시연 계획 v4](docs/본선-시연-계획-v4.md) — 제안 거절 → 첫 조리 승인(CoreXY 실제 누름·CT 가열 시작 확인·가열 종료 감지) → 공기청정기 강풍 + '다음부터도 자동으로' 허용 → 같은 조건 재실행 → 기록·자동 실행 끄기 → 일부 실패. CT 끝은 '가열 종료 감지(조리 완료가 아닐 수 있음)'로만 말한다. **장면 단위 실물 성공은 아직 없다.**
- **하드웨어 구성:** RPi5 허브(백엔드·15.8형 터치 키오스크) · RPi4 실행기(Wi-Fi, 페어링 키 `SIMPLELAY_LINK_KEY`) · **ESP32 모션**(CoreXY 엔코더 모터 2개, Z는 **솔레노이드**, [`firmware-motion-corexy/`](firmware-motion-corexy/README.md)) · **ESP32 콘센트 모듈**(CT 전력 L3·릴레이·비상정지 래치). 갠트리·모터·드라이버·엔코더는 같은 팀 HW 담당이 한이음 **Touch Bridge**(2026, 10월 말까지 진행)용으로 만든 **같은 기계 1대**를 함께 쓰고, **ESP32 모션 보드만 프로젝트별로 따로**다(사용자 확인 10/15). 펌웨어 제어 핵심은 Touch Bridge 원작 기반에 SimpleLay가 규약·안전 계층을 더했다 — [재사용 경계](docs/reuse-boundary.md)(문장 정정 제안은 [안전 계약 적용 보고](docs/안전계약-적용-보고-2026-10-15.md) §4, 미적용).
- **검증 수준(10/14):** 실물로 확인한 것은 **모터 축 구동·엔코더 계수, 정지 확인 단계(보냄 → 모션 보드 응답 → 멈춤 확인), 걸림(스톨) 알람 뒤 재시도 없이 멈춤, 모션 USB 재열거 뒤 다시 열기, 누름 제어 신호**(벨트·솔레노이드 없이, 10/12~14), 폰(에뮬레이터)→RPi5→RPi4(Wi-Fi)→ESP32 경로, 15.8형 실패널 키오스크·부팅 자동 실행, 기상청 날씨 실호출,
  **ThinQ 실제 공기청정기**(10/15~17 — 실제 클라우드 기기 찾기·추가·상태·풍량 변경 `state_confirmed`, RPi5에서 22:00 켜기·다음 날 07:00 끄기 시각 자동 루틴과 자동 실행을 실제 확인).
  ThinQ 이미 목표값(제어 0회)·꺼진 상태 풍량 변경은 클라우드가 거절(2304)도 실물 확인(10/15). 꺼진 공기청정기 종합 공기질 '나쁨' → 켜기 카드 → 승인 → 실제 켜짐 `state_confirmed`도 확인했다([devlog](docs/devlog/devlog_2026-10-15-air-off-power.md) §0).
  **⚠ 노트북 에뮬레이터(10/15 밤~):** 부팅 중 가상화 준비 직후 멈춤(재부팅·Docker/WSL 종료·콜드 부트·GPU 변경 모두 같음) — 원인 미확정.
  **미검증:** 캐리지 이동·원점, **실제 버튼 누름**, **CT 가열 판정**(콘센트 모듈 회로 미제작), 음성 경로, 공기질 제안을 폰·키오스크 화면에서 승인, 키오스크 새 문구의 실패널 표시, 실폰. 화면·문서에서 모의·컴파일·설계 수준을 "완료"로 쓰지 않는다. 기준 표는 [README](README.md) 검증 수준 표.
- **동결:** 신규 기능은 사용자 요청 건만. **UI 동결은 10/15 사용자 결정으로 해제** — 사용자 편의를 위한 화면·문구 수정은 연다(처음 쓰는 사람이 오해하는 문구·잘림·다음 행동 안내 우선). 10/15에 연 기능: 폰 ThinQ '지금 상태' 카드·직접 조작, 공기질(공기청정기 센서) 제안, 루틴의 ThinQ 단계.
- **ThinQ 연결 방식:** 계정 연결은 설치 때 허브에 PAT 한 번(`SIMPLELAY_THINQ_PAT_FILE`, 저장소 밖). 앱에 토큰 입력 화면은 두지 않는다(사용자 결정 10/15). 공기청정기 미세먼지 값은 ThinQ 앱 공기질 센서 설정이 '항상'일 때만 꺼진 상태에서도 온다('운전 중에만'이면 꺼지면 비어 옴, 켠 직후도 잠시 비어 있을 수 있음 — 10/15 실물에서 '항상'으로 바꿈). 공기질 제안은 켜져 있으면 강풍(`air_quality_high`), 꺼져 있으면 켜기(`air_quality_power_on`, 전원만) — 둘이 재알림 기억을 함께 써서 켜기 승인 직후 강풍 카드가 바로 이어지지 않는다.
- **다음 보드 날:** 10/14 저녁 실물(모터 축·누름 신호까지): 루틴 실제 경로 `success`·이동 중 정지 `verified` 18 ms·실패 화면 '닫기' 뒤 대기 승인 카드 전환 확인([devlog 10/14 데스크톱 마감](docs/devlog/devlog_2026-10-14-desktop-close.md) '보드' 절). 남은 것: 벨트·솔레노이드 장착 뒤 캐리지 이동·실제 버튼 누름·mm 환산(기어비) 실측, 모터 배선 고정(10/14 B 드라이버 전원·엔코더 A 단자가 빠졌었다). **평가 전에 끌 것:** RPi5 env의 개발자 실물 조작(`SIMPLELAY_DEV_MODE`·`SIMPLELAY_DEV_REAL_MOTION`), **FastAPI 기본 API 문서 페이지**(`/docs`·`/openapi.json`·`/redoc` — 키 없이 열려 API 목록이 보인다. 개발 중에는 열어 두고 결선 전에 닫기로 결정 10/15, `rpi/tests/test_route_auth_coverage.py`의 `FRAMEWORK_DOC_PATHS`), 공유기에서 RPi5 주소 예약(7000 제한이 RPi5 주소에 묶임).
- **배포:** RPi4·RPi5(·폰·키오스크)는 **같은 커밋**으로 배포한다 — 옛 RPi4면 자동 실행이 늘 보류되고 정지 보고가 '보냄'에 머문다. 비정상 종료 뒤 자동 실행은 다시 허용해야 한다.
- **현재 시험 수(10/19, 골든 제외):** 백엔드+rpi4 **3,689**(부하 때 흔들리는 타이밍 시험 몇 건 — `rpi/tests/README.md` 목록, 따로 다시 돌리면 통과) · 폰 **1,266** · 키오스크 **1,164**(골든 폰 69·키오스크 83 — 골든 아이콘 글꼴은 `FLUTTER_ROOT` 기준, 키오스크 `test/support/golden_fonts.dart`).
- **안전 빈칸(10/15):** [안전 계약 적용 보고](docs/안전계약-적용-보고-2026-10-15.md) §2. **수리(시험 조건 통과, 10/16 밤 `845569e`로 RPi4·RPi5 배포 — 실물 PS-1은 ESP32 복귀 뒤):** G2 보내기 전 정지(RPi5 직전 확인 + 링크 직전 확인 + RPi4 `run_ref` 거절), G1 승인·루틴 링크 끊김 → '눌렸는지 모름' 기록, G11 엔코더 움직임을 본 실행에서만 `verified`(쉬는 중 정지는 `mcu_ack`) — [devlog](docs/devlog/devlog_2026-10-15-safety-g2-g1-g11.md). **규약에 선택 필드 `run_ref` 추가 — RPi4·RPi5 같은 커밋 배포 필수.** 10/16: G3 루틴 구간 사이 정지(`/stop`이 루틴 먼저 멈춤·대기 뒤 재확인·다음 구간 시작 관문), G7 정지어("멈춰"·"그만"·"정지", 발화 전체 일치 — '취소'는 버튼 그대로)는 `/execute`에서 `/stop`과 같은 뜻, 폰 홈 음성도 정지로 — [devlog](docs/devlog/devlog_2026-10-16-safety-g3-g7.md)(시험 조건만, 새 APK 설치 전 폰은 옛 동작). G5 실행 중 생존 신호(RPi5 1 s·RPi4 3 s 없으면 스스로 정지 `motion_link_lost` → '미확인', 값은 추측 — [devlog](docs/devlog/devlog_2026-10-16-safety-g5.md), RPi4 socat이 죽은 연결을 늦게 알아 재접속이 몇 분 걸릴 수 있음은 남음). G4 쓰기 직전 정지 재확인·G9 정지 대기 해제가 abort 수신을 막지 않게·G10 정지 의미 표 고정 — [devlog](docs/devlog/devlog_2026-10-16-safety-g4-g9-g10.md)(RPi4 포함). [솔레노이드 안전 전달표](docs/솔레노이드-안전-전달표-2026-10-16.md)(HW 담당용). **남음:** G6·G8, **R1**(방향 미정 — 토글 버튼만 자동 재누름 금지 안이 유력, 폐루프 재시도 전체를 끄지 않기) 같은 버튼 두 번 누름(재시도) — [키오스크 계획](docs/키오스크-문구-개선-계획-2026-10-15.md) §5-1. 실물 확인은 PS-1(보고 §3) S4·S5·엔코더 뽑기.
- **git 주의(10/15 사고):** 여러 worktree·에이전트가 동시에 일할 때 `git stash`를 쓰지 않는다(stash는 worktree끼리 공유돼 서로 뒤바뀐다). 수정 전 실패 확인은 파일을 저장소 밖에 복사해 두고 되돌린다.
- **최근 작업 기록(10/10~10/15):** [키오스크 문구·화면 개선](docs/devlog/devlog_2026-10-15-kiosk-wording.md)([계획](docs/키오스크-문구-개선-계획-2026-10-15.md)) · [서버·RPi4 문구 통일·B11](docs/devlog/devlog_2026-10-15-server-wording.md) · [ThinQ 실물 첫 연동·폰 상태 카드](docs/devlog/devlog_2026-10-15-thinq-real.md) · [공기질 제안](docs/devlog/devlog_2026-10-15-air-suggestion.md) · [루틴 ThinQ 단계](docs/devlog/devlog_2026-10-15-routine-thinq-step.md) · [검토 반영 서버·배포](docs/devlog/devlog_2026-10-15-thinq-review-server.md) · [검토 반영 폰·키오스크](docs/devlog/devlog_2026-10-15-thinq-review-fix.md) · [모션 펌웨어 수령](docs/devlog/devlog_2026-10-10-motion-firmware-merge.md) · [모션 실물 첫 시험](docs/devlog/devlog_2026-10-12-motion-bringup.md) · [정지 확인 단계](docs/devlog/devlog_2026-10-13-stop-confirm.md) · [폰 UI B안](docs/devlog/devlog_2026-10-13-phone-ui.md) · [10/13 보드 날](docs/devlog/devlog_2026-10-13-desktop-board.md) · [ThinQ 공식 SDK](docs/devlog/devlog_2026-10-13-thinq-sdk.md) · [ThinQ 발견·추가](docs/devlog/devlog_2026-10-13-thinq-discovery.md) · [자동 실행 허용 규칙](docs/devlog/devlog_2026-10-13-auto-rule.md) · [보드 날 발견 수리](docs/devlog/devlog_2026-10-14-fixes.md) · [10/14 보드 날](docs/devlog/devlog_2026-10-14-desktop-board.md) · [외부 평가 3차 수리](docs/devlog/devlog_2026-10-14-eval3-fix.md) · [4차 수리](docs/devlog/devlog_2026-10-14-eval4-fix.md) · [재평가 수리 마무리](docs/devlog/devlog_2026-10-14-codex-fix.md) · [ThinQ 이미 목표값](docs/devlog/devlog_2026-10-14-already-at-target.md) · [공개 문서 정리](docs/devlog/devlog_2026-10-14-public-docs.md) · [노트북 인계 1~6·보드 실물](docs/devlog/devlog_2026-10-14-desktop-close.md) · [HIGH 재확인 수리](docs/devlog/devlog_2026-10-14-eval-recheck-fix.md)(설정 저장 대기·이벤트 루프 동기 입출력이 정지를 막던 것, `/dnd`·`PUT /quiet-hours` 응답 `persisted`·`session_only` — 다음 배포에 포함) · [재확인 2차 수리](docs/devlog/devlog_2026-10-14-eval-recheck2-fix.md)(정지 전용 줄 — 공유 스레드 풀 고갈과 분리, 저장소 읽기의 DB 대기 분리, 루틴 변경 원자화, 설정 응답 판 결속 — 시험 조건에서만 확인, 다음 배포에 포함) · [재시작 직후 초기화](docs/devlog/devlog_2026-10-14-startup-init.md)(제안 서비스 최초 생성을 이벤트 루프 밖으로 — 그동안에도 `/stop` 진입, 시험 조건에서만 확인. 시연 전 점검: 허브 재시작 → `/health/detail` 준비 확인 → 실행·정지 확인, 준비 전에는 실행하지 않는다 — 런북 §5-2). 그 전 기록은 [docs/devlog/](docs/devlog/)와 [지난 기록](docs/archive/작업규칙-지난-기록-2026-10-14.md).
- **참고 문서:** [하드웨어 연결 설계](docs/하드웨어-연결-설계.md) · [실측 기록표](docs/실측-기록표.md) · [결선 운영 런북](docs/결선-운영-런북.md) · [ThinQ 실물 확인 절차](docs/ThinQ-실물-확인-절차.md) · [전문가 의견 대응표](docs/전문가의견-대응-2026-09-29.md)(본문은 9/29 기록, 머리의 현재 기준 표를 따른다) · [UI 확정](docs/UI-확정-2026-09-30.md) · [개발현황](docs/개발현황.md) · [제출 서류 초안](docs/submission/제출-체크리스트.md).

## 🔴 최우선 규칙 — 비공개 자료 보호

- **비공개 제공 자료·코드·문서·실행 출력은 git에 커밋하거나 외부에 전송하지 않는다.** 공개 작업을 이유로 해당 자료를 자동 탐색하지 않는다.
- 로컬 전용 경로와 접근 범위는 사용자가 별도로 지정한다. 지정받지 않았으면 열지 말고 확인한다. PDF·PPTX·HWP·DOCX 및 비공개 자료는 공개 작업 범위 밖이다.
- 별도 허가된 기술 작업도 로컬에서만 수행한다. `.gitignore`는 보조 장치이며 이미 추적되는 파일과 커밋 이력까지 보호하지 않는다.
- 커밋 전 파일 목록과 실제 diff를 확인한다. 공개 문서·로그·주석·커밋 메시지에는 비공개 경로, 플랫폼 고유 명칭, 내부 API, 원문 출력과 연동 세부, **개인 PC의 로컬 경로**를 넣지 않는다(저장소 밖 자료는 "저장소 밖 로컬 작업 기록 폴더"처럼 일반 표현으로).
- `rpi/tests/test_repo_guard.py`가 **추적 중인 파일**(이 CLAUDE.md 포함, 2026-10-14부터 예외 아님)의 플랫폼 고유 명칭(내용·파일 이름)과 문서·비밀 파일(`.pptx`·`.pdf`·`.env`·키 등)을 막는다. 가드는 새로 늘어나는 것만 막고 이미 커밋된 이력은 되돌리지 못한다.
- **이력:** 10/7 발표 자료(pptx)를 git 이력에서 지우고 강제 푸시했다. 남은 이력(옛 커밋 속 플랫폼 명칭·로컬 경로, PR 참조, 로컬 백업 브랜치) 점검 결과는 [공개 문서 정리 devlog](docs/devlog/devlog_2026-10-14-public-docs.md) §2. **이력 재작성·강제 푸시는 사용자 승인 없이 하지 않는다.**

## 커밋 규칙

- 작업 단계마다 1커밋, 한국어 conventional commit (`fix(app): …`, `feat(rpi): …`). 다른 작업과 겹칠 때는 `git commit -- <경로>`로 내 파일만 커밋한다.
- **커밋 표기 정책:** 커밋 메시지에 도구 이름·공동 작성자(Co-Authored-By) 줄을 넣지 않는다. 이것은 **커밋 메시지 표기 방식만** 정한 규칙이다 — 대회 개발 도구(AI) 사용 고지와는 별개이며, 사용 사실은 [개발 도구 사용 고지 초안](docs/submission/개발도구-사용-고지-초안.md)에 따라 서류·README에 사실대로 적는다.
- push 전 `git pull --rebase`, 그다음 `git push origin main`. 강제 푸시 금지(사용자 승인 건 제외). 작업 세션마다 devlog(`docs/devlog/devlog_YYYY-MM-DD*.md`)에 기록.

## 시험·커밋 게이트

- **자주 쓰는 명령:** 백엔드 `.\.venv\Scripts\python.exe -m pytest -q` (Windows는 `$env:PYTHONUTF8=1`, `--basetemp <ASCII 고유 경로>`) ·
  폰 `cd app; flutter test --exclude-tags screenshot` · 키오스크 `cd rpi5-touchscreen-app; flutter test --exclude-tags screenshot` ·
  골든은 `--tags screenshot`(갱신 없이 비교). 커밋 전 `rpi/tests/test_repo_guard.py`·`rpi/tests/test_doc_links.py`.
- **실패 확인도 게이트 조건이다.** 회귀 테스트는 수정 전 코드(또는 결함을 되살린 변형)에서 실패하는 것을 확인한 뒤에만 커밋한다.
- **analyze 게이트:** `flutter analyze | tail -1`처럼 출력을 자르면 오류가 있어도 체인이 통과한다. analyze error·warning 0이고 테스트 출력에 `All tests passed`가 있을 때만 커밋한다.
- 테스트 개수를 적을 때는 **골든 포함 여부를 명시**한다. 골든은 생성 환경에서 별도로 검증한다.
- 판정 시각을 고정한 테스트는 레지스트리·서비스의 시계도 고정한다(날짜가 넘어가면 깨진다).
- 위젯 테스트에서 기기 저장소 같은 **진짜 비동기**는 `tester.runAsync`로 감싼다(가짜 시계 위에서 영원히 멈춘다).
- 골든 이미지의 네모 아이콘은 테스트 폰트 로딩 제한이다. `docs/archive/screenshots-2026-08/`는 개편 전 화면이라 최신 디자인 근거로 쓰지 않는다.
- 링크는 `rpi/tests/test_doc_links.py`가 지킨다(추적 md의 상대 링크, 허용 목록 없음). 문서를 옮길 때는 `git mv`로 이력을 잇는다.

## 개발 환경 (Windows 기준 — 새 기기는 유사하게 구성)

- 한글 경로에서 Dart analysis server 문제가 발생한 이력이 있어 ASCII 정션 경유를 권장:
  먼저 `C:\dev-simplelay`의 대상이 현재 저장소인지 확인한다. 없으면 `New-Item -ItemType Junction -Path C:\dev-simplelay -Target <리포경로>` 후 그 경로에서 flutter 실행. 기존 정션을 무작정 덮어쓰지 않는다.
- 에이전트 셸에 `flutter`가 PATH에 없을 수 있다 — 기기마다 설치 위치를 먼저 확인하고 전체 경로(`<Flutter 설치 폴더>\bin\flutter.bat`)로 실행한다.
- 백엔드: 리포 루트 `.venv` (fastapi·uvicorn·pydantic·numpy·pytest·httpx·dbus-fast)
  없으면 `py -m venv .venv` 후 `.\.venv\Scripts\python.exe -m pip install -e ".[test]"`
- 테스트는 줄 단위로 실행하고 각 종료 코드를 확인한다(PowerShell 5.1에서는 `&&` 사용 불가).
- 릴리즈 APK: `flutter build apk --release` (JDK17 + Android SDK 필요). 에뮬레이터 설치 APK는 `--split-per-abi`로 빌드해야 덮어쓰기된다.
- **운영 주의:** API 키 없으면 LAN 401(`SIMPLELAY_ALLOW_UNAUTHENTICATED=1`은 개발용) · **링크 키 `SIMPLELAY_LINK_KEY`가 없으면 RPi4 실행기·RPi5(`SIMPLELAY_ACT_MODE=uart`)가 시작 거절**(무인증은 `SIMPLELAY_LINK_AUTH=off_for_mock` + 모의 구성 전용, [보안 수리](docs/devlog/devlog_2026-10-14-security-fix.md)) · `SIMPLELAY_THINQ_MODE` 기본 off · `SIMPLELAY_L3_MODE=real`은 RPi4에 콘센트 모듈 연결이 있어야 하고 없으면 기동 거절 · RPi4 재부팅 뒤엔 `systemctl start docker` 필요 · 펌웨어 비밀값은 `firmware-node/secrets.ini`(untracked) · 인식 서비스 키 등 비밀은 환경 변수로만, 채팅·코드·커밋·로그에 넣지 않는다 · 데스크톱 앱(Docker Desktop 등)은 켜기 전에 사용자에게 말한다.

## 아키텍처 요점 (자세히는 docs/개발현황.md)

- 실행은 **비동기 job 모델**: POST /execute → 즉시 job_id, 완료는 /status의 last_job_id 대조
- 오프라인 우선: 모든 실기기 의존은 env 게이트(`SIMPLELAY_*`), 기본은 mock — 개발 PC에서 전 기능 동작
- 클라이언트: 폰(app/), 키오스크(rpi5-touchscreen-app/, 임베디드 리눅스용 Flutter 크로스빌드 구조) — 서비스는 생성자 주입으로 테스트
- 리허설 API: `POST /demo/suggest`(제안 강제 생성), `POST /demo/inject-failure`(검증 실패 주입)
- 개발자 API(`/dev/*`): `SIMPLELAY_DEV_MODE` + `SIMPLELAY_DEV_TOKEN`(일반 API 키와 별개), **기본 모의, 실물은 env 두 개(`SIMPLELAY_DEV_MODE`·`SIMPLELAY_DEV_REAL_MOTION`) + RPi4 실물 링크(`act_info.motion=serial`·`dev_motion_protocol`)일 때만**(원점 필수·이동량 상한·정지 우선 — [devlog](docs/devlog/devlog_2026-10-10-dev-real-motion.md)). 계약은 `rpi/api/dev_router.py` 머리말, 제어권 반환 규칙은 `rpi/services/developer_session.py`의 `_maybe_release_locked`가 유일한 반환 지점
- 개발자 API 유지 규칙: 시작→소유권 게시는 직렬화하되 정지는 기다리지 않는다.
  요청 ID는 세션 수명 동안 보존(4096건 상한에서 거절). 폰의 정지/이탈/연결 변경은
  응답 세대를 무효화한다. `confirmed=true`라도 `phase=stopping`이면 완료가 아니다.
  heartbeat 첫 확인 실패 시 세션을 닫는 보수적 정책이며 실측 없이 기한을 늘리지 않는다.
- 실측 전 센서 잡음·임계값은 사실로 쓰지 않고 `추측/측정 필요`로 표시한다.

## 방향 원칙

- AI 고도화 금지(지도교수 방침) — 기존 모듈을 배선만. HW 완성도가 차별점
- 심사 키워드: 공감지능(패턴) · 공간 이해/초개인화 · 온디바이스/클라우드 추론 경계(docs/inference-boundary.md가 답)
- 접근성: docs/사용자편의-가이드-체크리스트.md 기준(국가표준 매핑) 준수
- 상용 제품과는 **설계 차이**로만 비교하고 성능 우위를 주장하지 않는다(상용품 기능은 공개 사양·출처·확인 날짜로만).
