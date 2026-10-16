# 2026-10-16 안전 빈칸 수리 — G5(조용한 Wi-Fi 끊김: 실행 중 생존 신호)

근거: [안전 계약 적용 보고](../안전계약-적용-보고-2026-10-15.md) §2 G5·§3 PS-1 S5. 앞 수리([G2·G1·G11](devlog_2026-10-15-safety-g2-g1-g11.md),
[G3·G7](devlog_2026-10-16-safety-g3-g7.md))와 같은 원칙 — **정지 뒤에는 아무것도 더 보내지 않고, 확인한 만큼만 말한다.**
**고치기 전 회귀 시험이 실패하는 것을 먼저 확인**했다(수정 전 파일은 저장소 밖에 복사해 두고 되돌림, `git stash` 쓰지 않음).
작업은 브랜치 `fix/g5`(시작 `eee9933`). **검증 수준: 시험 조건만(가짜 전송·가짜 모션·가짜 시계). 보드에는 배포하지 않았다.**
**RPi4·RPi5를 같은 커밋으로 배포해야 한다**(규약 확장 — `run_ref`와 같은 규칙).

## 1. 증상(보고서, 코드 기준 추정)

- 두 보드는 핫스팟 Wi-Fi의 TCP(`socket://<RPi4>:7000`, RPi4 쪽 socat)로 이어진다. Wi-Fi가 FIN 없이 끊기면 양쪽 모두 TCP keepalive
  (5 s 뒤 2 s × 3 ≈ 11 s, [10/12](devlog_2026-10-12-motion-bringup.md))가 알아챌 때까지 모른다. 그동안 RPi5의 정지(`abort`)는 닿지 않는데
  RPi4는 남은 버튼을 계속 누른다.
- 실행 중 RPi5→RPi4 방향에는 보낼 것이 거의 없었다(실행 요청 한 줄 뒤 결과를 기다림). RPi4는 '정지가 오지 않음'과 '정지를 보낼 수 없음'을
  가를 방법이 없었다.
- RPi5 문구: G1 수리(`fbb8ea9`)로 링크 예외는 이미 '눌렸는지 모름'이다. 이번에 새로 생기는 경우 — RPi4가 링크를 잃고 스스로 멈춘 결과가
  (링크가 살아나서) 닿는 경우 — 를 그대로 두면 '안전 정지·완료되지 못했어요'(보호자 알림 "실행이 완료되지 못했어요")로 단정했을 것이다.

## 2. 수리 — 링크 생존 신호 규약 1 (`rpi/services/link_heartbeat.py`, 규약은 [protocol.md](../protocol.md) '실행 중 생존 신호')

- **알림:** RPi4 `act_info`에 `heartbeat_protocol: 1`, `heartbeat_timeout_s`.
- **RPi5(`ActClient.execute`):** 알린 RPi4에만 `execute`에 `heartbeat_s`를 싣고, 결과(또는 오류·기한·끊김)까지 `heartbeat {sequence_id}`를
  주기마다 보낸다. 링크 이벤트 루프(`act-client-loop` 스레드)의 asyncio 작업이다 — 서비스 스레드·공용 스레드 풀을 거치지 않고, 정지
  (`abort`)·정지 보고 대기(`abort_with_report`, 최대 1.5 s)와 따로 돈다. 옛 RPi4에는 종전 줄 그대로.
- **RPi4(`ActExecutor`):** `heartbeat_s`가 실린 실행만 감시한다. 인증된 올바른 줄(종류 무관)을 받을 때마다 시각을 적고, 실행 동안 이벤트
  루프 작업이 `min(0.25 s, 제한/4)`마다 `check_link_watchdog()`를 부른다. 마지막 줄 뒤 `max(제한 시간, 주기 × 3)`이 지나면
  `_abort("drive")` — **받은 정지와 같은 길**(컨트롤러 `request_stop` → 모션 어댑터가 MCU에 `stop`을 써 큐를 비움, 재홈·재누름 없음,
  정지 버튼 누름 없음). 결과는 `safety_stop`·`abort_reason: motion_link_lost`(누른 버튼 결과는 그대로). 다음 `act_info`에
  `last_link_stop {sequence_id, run_ref, outcome, pressed, total, silent_ms, timeout_s}`을 한 번 싣는다.
  감시하지 않는 것: `heartbeat_s` 없는 실행(옛 RPi5), 쉬는 중, 정지 버튼 대기, 개발자 조작, 확인 주행.
- **RPi5 문구:** `motion_link_lost` 결과는 `ActClientController.execute`가 `ActLinkError`로 바꿔 서비스의 G1 경로(수신 `unknown`·`unconfirmed`,
  "연결이 끊겨 눌렸는지 확인하지 못했어요 — 가전을 직접 봐 주세요(자동으로 다시 누르지 않아요)")로 보낸다 — 직접·승인·루틴·시나리오 경로가
  같다. 다시 이은 뒤 RPi4가 알린 `last_link_stop`은 보호자 알림 한 건(같은 실행은 한 번, `deps.receive_act_info` → `LinkStopNotices`)과
  `link_status().last_link_stop`.
- **TCP_USER_TIMEOUT(RPi5 링크 소켓, 11 s):** Linux keepalive는 보낸 줄이 확인되지 않고 쌓여 있으면 돌지 않는다. 생존 신호를 쓰면 실행 중
  링크가 끊길 때 늘 쌓인 줄이 있으므로, 이것이 없으면 RPi5 링크는 재전송 한도(수 분 추정)까지 '이어짐'으로 남았을 것이다(실행은 응답 기한
  30 s + 6 s/버튼에서 끝나지만 재연결이 늦어진다). 종전에는 실행 중 보낼 줄이 거의 없어 keepalive 약 11 s로 알았다 — 그 시간을 지킨다.
- **값(추측, 측정 필요):** 주기 1 s(`SIMPLELAY_LINK_HEARTBEAT_S`, 0.2~5, 끌 수 없음), 제한 3 s(`SIMPLELAY_LINK_HEARTBEAT_TIMEOUT_S`, 1~30) —
  생존 신호 두 번을 놓친 것으로는 멈추지 않고 세 번째에 멈춘다. 끊김 뒤 최악 누름 창은 약 11 s → 약 3 s(+ 진행 중 누름 하나). 짧으면 멀쩡한
  실행이 '연결 끊김으로 멈춤'이 된다(안전 쪽 실패). [환경 변수](../환경변수.md)에 적었다.

## 3. 시험

- 새 `rpi4/tests/test_act_link_heartbeat.py` 11건 — act_info 알림, 메시지 읽기(틀린 주기는 '없음'), 생존 신호 끊김 → 스스로 정지(가짜 시계,
  `check_link_watchdog` 직접 — 잠 없음: 남은 버튼 미누름·같은 버튼 재누름 없음·`safety_stop`/`motion_link_lost`), 생존 신호가 계속 오면
  8 s 실행도 멈추지 않음, 주기 2 s면 6 s까지 기다림, 다른 인증 줄도 생존 근거, 쉬는 중·옛 RPi5 실행·실행 끝난 뒤는 요구 없음, 다시 이은 뒤
  `last_link_stop` 한 번, 배경 감시 작업(짧은 실제 시간 한 건).
- 새 `rpi/tests/test_safety_g5_link_heartbeat.py` 8건 — 실행 중 생존 신호가 나가고 결과 뒤 멈춤, 옛 RPi4에는 없음, **정지 보고를 기다리는 동안·
  루프 기본 스레드 풀을 막아 둔 동안에도 제 주기로 나감**, 주기 env, `motion_link_lost` → 서비스 '눌렸는지 모름'(문장·이력·보호자 알림, "완료되지
  못했어요" 없음, 다시 누르지 않음), RPi4 알림 → 보호자 알림 한 건, 끊겨도 `last_link_stop` 유지, 링크 소켓 `TCP_USER_TIMEOUT` 11 s.
- **수정 전(구현 파일 넷을 수정 전 것으로 되돌리고 새 규약 모듈·메시지 읽기만 둠):** **17 실패 / 2 통과**(통과 2건은 메시지 읽기·알림 문장 —
  되돌리지 않은 새 모듈 몫). 그중 '쉬는 중'·'옛 RPi5' 등 회귀 지킴 시험은 새 생성자 인자가 없어 실패한 것이다.
- **층 확인(수리 한 부분씩 끔):** RPi4 감시만 끄면 4 실패(스스로 정지·주기 3배·다시 이은 뒤 알림·배경 감시), RPi5 보내기만 끄면 2 실패(보내기·
  굶지 않음), `motion_link_lost` → 미확인 변환만 끄면 1 실패(문구).
- 전체 결과는 §5.

## 4. 폰·키오스크

- 화면이 이 경우에 보는 것은 `/status`의 `last_status`·`last_outcome`=`unconfirmed`와 `last_detail`(G1 문장)뿐이다 — G1 수리 때 이미 다룬 값이라
  새 값·새 문장 없음. `motion_link_lost`는 서버가 미확인으로 바꾸므로 `last_abort_reason`으로 나가지 않는다(나가더라도 두 앱의 `motionAbortSentence`는
  모르는 `motion_…` 값을 "누름 장치가 멈췄어요"/"작은 팔이 멈췄어요"로 읽는다). 보호자 알림은 서버 문장을 그대로 보인다. **앱 수정 없음.**

## 5. 시험 수

- 백엔드+rpi4 전체(`pytest -q`, 골든 없음): 아래 '결과' 참고.
- `rpi/tests/test_repo_guard.py`·`rpi/tests/test_doc_links.py`: 아래 '결과' 참고(새 파일은 `git add -N`으로 추적 목록에 올린 뒤).
- 폰·키오스크 시험은 돌리지 않았다(앱 코드 변경 없음).

결과: 전체 **3,309 통과 · 10 건너뜀**, 종료 코드 0(새 19건 — rpi4 11·rpi 8, G3·G7 devlog의 3,290에서 순증 19). 두 번 돌렸다 — 1차는
`test_doc_links.py` 1건 실패(보고서·코드 구조에 이 devlog 링크를 먼저 넣고 devlog를 추적 목록에 올리기 전에 돈 것, 그 밖 3,308 통과), 2차가 위
결과다. 부하에 민감한 타이밍 시험 실패는 두 번 모두 없었다. 가드·링크 시험: **8 통과**, 종료 코드 0.

## 6. 실물 미검증 · 남은 위험

- **보드 배포 전이다.** 끊김은 '줄이 안 옴'을 가짜 시계로 흉내 냈다. 실물은 PS-1 S5(실행 중 RPi4 Wi-Fi 끄기)로 — 실행기 로그 "stopping by myself",
  끊김 뒤 누름 수, 멈출 때까지 시간, 다시 이은 뒤 보호자 알림.
- **RPi4 쪽 socat 끊김 감지는 그대로다:** RPi4가 결과·진행 줄을 죽은 연결에 쓰면(쌓인 줄) socat의 keepalive도 돌지 않아 socat이 오래(재전송
  한도, 수 분 추정) 연결을 붙잡을 수 있고, 그동안 RPi5가 다시 붙지 못한다(socat은 연결 하나만 받음). 이번 수리는 **누름을 멈추는 것**만 닫는다.
  socat에 `TCP_USER_TIMEOUT`에 해당하는 옵션을 주는 것은 socat 판에서 지원 여부를 확인한 뒤 따로 한다(`deploy/run_act.sh` 미변경).
- RPi4 읽기 루프가 막히면(예: RPi5 방향 쓰기 대기) 생존 신호를 읽지 못해 침묵으로 보인다 — 그때도 멈추는 쪽이다(안전 쪽 실패).
- 정지 버튼 위 대기(hold)·개발자 조작(홈 최대 90 s)·확인 주행은 감시하지 않는다 — 대기는 누르지 않고 기다리는 상태이고, 개발자 조작은
  RPi5 기한·정지에 의존한다. 필요하면 같은 규약을 넓힌다.
- RPi4 실행기가 다시 시작되면(컨테이너 재시작) `last_link_stop`은 사라지고 실행기 로그에만 남는다(파일로 남기지 않음).
- 남은 빈칸: G4·G6·G8~G10·R1. 작업 규칙 파일의 안전 빈칸 줄은 이 브랜치를 합칠 때 함께 고친다(이번에는 건드리지 않음).
