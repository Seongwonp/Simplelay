# 2026-10-13 노트북 — 정지 확인을 "보냄"과 "확인"으로 나눔

[정지 확인 계획](../계획-정지-확인-2026-10-12.md) "순서와 크기" 1~4단계를 구현했다. 배경은
[10/12 devlog](devlog_2026-10-12-motion-bringup.md) 발견 2: RPi4가 정지 줄을 **쓰기만** 하고 MCU 응답은 버렸는데,
RPi5 `/dev/stop`·세션 끝·폰은 "정지를 확인했어요"라고 말했다(과장).

**보드 없이 가짜 MCU(`rpi/tools/fake_mcu.py`)로만 시험했다. 실물 미검증.** 5단계(실물 확인·배포)는 하지 않았다.

## 무엇을

| 단계 | 커밋 | 내용 |
|---|---|---|
| 1 | `3be54d1` | RPi4 `SerialMotionClient`: `request_stop()`은 그대로 바로 돌아오고 보낸 id·시각을 남긴다. 진행 중 요청의 읽기 루프가 정지 응답을 버리지 않고 기록하고, 대기 중이면 `wait_stop_ack()`가 짧은 기한(0.3 s) 안에 직접 읽는다(읽는 쪽은 op 잠금을 쥔 하나). `confirm_stop()`은 MCU 확인 뒤 `status` 두 번(0.1 s 간격)의 엔코더 a·b가 같을 때만 `verified`. `ok:false` 응답·옛 정지의 늦은 응답은 확인이 아니다 |
| 2 | `98a7e5f` | RPi4 규약: `dev_motion stop` 답에 `stop_level`·`ack_ms`(개발자 조작 규약 **2**), `abort {stop_id}`에 새 `stop_report {stop_id, target, stop_level, ack_ms}`(정지 보고 규약 1, `act_info.stop_report_protocol`). 정지 줄을 먼저 쓰고 확인은 따로 기다려 읽기 루프를 막지 않는다. `stop_id` 없는 옛 abort에는 종전처럼 답하지 않는다. act_main은 serial일 때만 실제 어댑터로 확인하고 모의 모션은 `sent`. 줄 기록에 `>> stop`과 `<< {"id":…,"ok":true}`가 둘 다 남는다. [protocol.md](../protocol.md) 갱신 |
| 3 | `b97fa86` | RPi5: `confirmed`는 **`mcu_ack` 이상일 때만** 참(`rpi/services/stop_confirm.py`). 단계 없는 답(옛 RPi4)·모르는 값·`abort drive` 대체는 `sent`. `sent`는 잠그지 않되 "정지 명령을 보냈어요 — 멈췄는지 기계를 봐 주세요". 일반 `/stop`은 abort를 먼저 보내고 보고를 최대 약 1.5 s 기다려 `stop_level`·`stop_ack_ms`·`stop_target`·`stop_confirmed`로 돌려주고, `/status`에 `last_stop_level`·`last_stop_ack_ms`(새 실행에서 지움). 정지 보고 규약을 모르는 RPi4는 기다리지 않는다 |
| 4 | `66402a9` | 폰: 개발자 도구 정지·세션 끝, 실행 화면 정지 안내, 멈춘 실행의 결과 문장. 키오스크: 멈춘 실행 화면에 정지 줄(확인이면 확인색, 보냄이면 주의색). 단계가 없는 옛 서버·모의는 종전 문장 그대로 |

문구: `sent` "정지 명령을 보냈어요 — 멈췄는지 기계를 봐 주세요" · `mcu_ack` "모션 보드가 정지를 확인했어요 (n ms)" ·
`verified` "멈춘 것을 확인했어요 (n ms)". 모의 개발자 어댑터는 단계 없이 종전처럼 `confirmed:true`.
(정정, 외부 평가 72점: n ms는 보낸 뒤 모션 보드 응답까지다 — 폰의 `verified` 문구는 `c3ae6c9`에서 "멈춘 것을 확인했어요 (모션 보드 응답 n ms)"로 고쳤다. 아래 끝 절.)

## 수정 전 실패 확인

| 단계 | 새 시험 | 수정 전 결과 |
|---|---|---|
| 1 | `rpi/tests/test_stop_confirm.py` 12건 | 모듈 수집 오류(`ImportError: STOP_MCU_ACK`). 구현 뒤 변형 확인: `_request`의 정지 응답 기록 한 줄을 빼면 2건 실패(진행 중 기록·다음 요청이 읽은 정지 응답) |
| 2 | `rpi4/tests/test_dev_motion.py` +11, `test_act_main_motion.py` +1 | 10건 실패(`KeyError: stop_level`·`STOP_REPORT_PROTOCOL` 없음·`AbortMsg(stop_id)` 없음·`motion_stop` 인자 없음), 1건(stop_id 없는 abort 무응답 — 호환 고정)은 수정 전에도 통과. act_main 배선 1건 실패 |
| 3 | `test_dev_real_motion.py` +8, `test_stop_report_rpi5.py` 10건, `test_dev_motion_link.py` +1(×2 판) | 8건·10건 실패. 끝-끝 1건은 RPi5 변경만 되돌리면 2판 모두 실패(`None is not None`) |
| 4 | 폰 `stop_level_test.dart` 7건·개발자 도구 +4, 키오스크 `stop_level_test.dart` 7건 | 폰 7건·키오스크 7건 컴파일 실패(`stopLevelSentence` 없음), 개발자 도구 4건 실패 |

고친 기존 시험(종전 과장을 고정하던 것): `test_dev_stop_is_forwarded_to_rpi4`(단계 없는 답을 `confirmed:true`로 보던 단언 제거),
`test_router.py::test_emergency_stop_returns_ok`(응답 모양에 새 필드).

## 시험 수(`66402a9`)

- 백엔드+rpi4: **2,710 통과**, 12 건너뜀(`PYTHONUTF8=1`, `--basetemp C:\pt_tmp\…`). 10/12 2,678 → +32.
- 폰(골든 제외): **591 중 563 통과, 28 실패.** 실패 28건은 HEAD(`c220b49`)에서도 **같은 28건**이다(시험 이름 목록 비교 일치 — 오류 전문까지 비교한 것은 아니다) —
  이 노트북 Flutter의 `ink_sparkle.frag` 판 불일치("Unsupported runtime stages format version. Expected 1, got 2"),
  파일마다 버튼을 처음 누르는 시험에서 난다. 새 시험 11건은 모두 통과. `flutter analyze` error·warning 0(기존 info 4).
- 키오스크(골든 제외): **262 통과**(255 + 7). `flutter analyze` error·warning 0(기존 info 1).
- 골든: **이 노트북에서 원래부터 깨진다** — 폰·키오스크 `screenshot_test.dart`가 데스크톱 경로
  `C:\flutter\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf`를 읽어 setUpAll에서 실패하고, 키오스크
  `provenance_screenshot_test.dart` 4건도 실패한다(HEAD 기준). 그래서 **골든은 갱신하지 않았다.** 바뀐 화면은 정지 단계가
  있을 때만 줄이 생기므로 기존 골든 장면(단계 없음)에는 영향이 없을 것으로 보지만, 데스크톱에서 비교로 확인해야 한다.
- 노트북 환경 메모: 사용자 TEMP가 한글 경로라 `flutter test`가 엔진을 못 띄우고 멈췄다("Could not create root isolate").
  `$env:TEMP=$env:TMP="C:\pt_tmp\ft"`로 돌리면 된다. Flutter는 `C:\dev-simplelay` 정션(이번에 만듦)에서 실행했다.

## 미검증·다음 보드 날

- **실물 미검증.** 실제 ESP32(`firmware-motion-corexy`)의 `stop` 응답 시각·`status`의 a·b 보고로는 확인하지 않았다.
- **두 보드를 함께 배포해야 한다.** 새 RPi5 + 옛 RPi4면 일반 정지는 기다리지 않고 `sent`, 개발자 정지도 `sent`(확인 아님)로 말한다 —
  안전 쪽이지만 화면이 늘 "보냈어요"가 된다. 옛 RPi5 + 새 RPi4는 종전과 같다(`stop_id`를 안 보내 보고 없음).
- 보드 날 확인: 무선 상태에서 폰 정지 → 줄 기록(`SIMPLELAY_MOTION_LOG_PATH`)에 `>> stop`과 `<< {"id":…,"ok":true}`가 둘 다
  남는지, 화면의 ms가 기록과 맞는지, 이동 중 정지에서 `verified`가 나오는지(벨트 미완성이면 모터 축 기준).
- 기한 값(RPi4 응답 0.3 s·확인 간격 0.1 s·RPi5 보고 1.5 s)은 호스트 박자 자리표시자다.
- 정지 버튼 대기(hold)의 가전 정지는 `stop_report target:"hold"`·`stop_level:null`이고 결과는 종전 `hold_stop_outcome`이 말한다.

## 실측 계획 G3

[실측 계획](../실측-계획-결선.md) §3에 모션 MCU 구간 두 개를 더했다: **A. `sent → mcu_ack`**(줄 기록 `>>`/`<<` 또는 `ack_ms`),
**B. `sent → verified`**(두 번째 `status` 응답). `stop.csv` 선택 열 `t_sent_ms`·`t_mcu_ack_ms`·`t_verified_ms` — 그림 도구는 아직
이 열을 그리지 않는다(첫 측정 뒤 넓힌다).

## 외부 평가(72점) 수리 — 정지 보고의 실행 결속(H1)·늦은 단계(M1)·ack_ms 문구

시작 HEAD `d228f9d`. 가짜 MCU·가짜 HTTP 시험까지이며 **실물 미검증**은 그대로다.

### H1 — 이전 정지의 늦은 보고가 새 실행에 섞임 (고침, `03ee1ae`)

- 재현(서버): J1 정지 → J1이 정지로 끝남 → J2 시작(`_begin_run`이 `_last_motion_stop`을 지움) → J1의 정지 보고가 늦게 도착하면
  `target=run`이라는 이유로 다시 저장돼 J2의 `/status`에 J1 단계가 되살아났다. 실제 서비스(`submit_buttons`)·늦게 답하는 링크 대역으로 재현.
- 재현(폰): `emergencyStop()`이 `/stop` 응답을 기다리는 사이 J2가 시작·완료돼도 응답의 단계 문장으로 J2 화면 문장을 덮었다. 결과 문장도
  `/status`의 정지 단계를 어느 실행의 것인지 보지 않고 실었다.
- 수정: 서버는 정지 요청 때 **실행 세대·job**을 잡고(`_run_generation`), 보고를 기다리는 사이 세대가 바뀌었으면 남기지 않는다.
  `/stop`에 `stop_job_id`, `/status`에 `last_stop_job_id`. RPi4 링크(`ActClientController.request_stop`)는 정지마다 보고 핸들을 돌려주고
  `wait_stop_report(handle=)`가 그 정지의 보고만 기다린다(연속 정지가 서로의 보고를 읽지 않는다 — stop_id 결속). 폰은 정지 요청 때의
  실행(sequenceId)이 그대로이고 서버가 같은 job을 멈췄다고 할 때만 단계를 싣는다. `/status` 단계도 `last_stop_job_id`가 자기 job일 때만
  (필드가 없는 옛 서버는 종전처럼). (정정, 2차 평가 M-N1: 당시 폰 `/stop` 파서는 필드가 있는 null도 옛 서버처럼 받았다 — `b1654ab`에서 고침)
- 시험: 서버 `test_stop_report_rpi5.py` +4(J1 정지→종료→J2 시작→J1 보고 지연, 같은 실행이면 종료 뒤에도 유지, `/stop`의 job, 연속 정지 핸들),
  (정정, 2차 평가: 경합 시험의 RPi4 링크는 `_LateReportLink` 대역, 연속 정지 핸들 시험은 실제 `ActClientController`에 `_TwoStopClient` 대역 —
  서버 세대·정지별 future 결속까지이고 MCU 정지 id까지의 연속 경합 보장이 아니다. 그 경계는 아래 2차 평가 M-N2에서 따로 닫았다)
  폰 `stop_report_binding_test.dart` H1 4건(새·옛 서버, 다른 job의 `/status` 단계, 다른 job을 멈춘 응답). 수정 전 서버 4건·폰 4건 실패.
  `test_router.py`의 응답 모양에 `stop_job_id`를 더했다.

### M1 — 결과가 먼저 오고 정지 단계가 늦게 오면 화면에 반영 안 됨 (고침, `29448a5`)

- 재현: RPi4가 실행 결과를 먼저 보내고 정지 보고는 status 두 번 뒤에 온다. 폰은 첫 완료 `/status`로 문장을 만들고 추적을 끝냈고, 키오스크는
  완료 때 `_doneStopLevel`을 고정한 뒤 다시 묻지 않았다. 다른 단말에서 멈춘 실행은 폰이 `/stop` 응답조차 받지 않는다.
- 수정(폰·키오스크): 정지로 끝난 실행의 단계가 아직 없으면 **1초 주기로 최대 3번만**(시도 상한 — 요청 중이면 그 주기를 건너뛰어 3초 안에 끝난다는
  보장이 아니고, timeout·보고 지연이면 끝내 못 받을 수 있다. 이미 단계가 있으면 더 높은 단계를 계속 따라가는 스트림도 아니다) `/status`를 다시 물어 같은 job의 단계가 오면 결과 문장
  (키오스크는 정지 줄)만 고친다. **음성은 다시 말하지 않는다.** 새 실행이 시작되거나 `last_job_id`가 바뀌면 그만둔다. 폰의 `/stop` 응답이
  결과 뒤에 오면 결과 문장을 덮지 않고 같은 job의 단계만 싣는다. 정지 전송은 이 대기와 무관하다(이미 나갔다).
- 시험: 폰 4건(내 정지 응답 지연·다른 단말 정지·옛 RPi4 무보고는 3번 안에 그만둠·후속 조회 중 새 실행), 키오스크 3건(다른 단말 정지·
  옛 RPi4·다른 job 단계). 수정 전 폰 2건·키오스크 2건 실패, 옛 RPi4 시험은 보존 시험(수정 전에도 통과).
  `voice_stop_test` 1건은 후속 조회 타이머가 끝나도록 흘려보내는 줄만 더했다.

### ack_ms 문구 (L2, `c3ae6c9`)

- `ack_ms`는 정지를 보낸 뒤 **모션 보드 응답까지**(sent→mcu_ack)다. 멈춤 확인(verified, status 두 번)까지의 시간이 아니다.
  위 '문구' 절의 `verified` "멈춘 것을 확인했어요 (n ms)"는 n ms 만에 멈춤을 확인했다고 읽혀, 폰은 **"멈춘 것을 확인했어요 (모션 보드 응답 n ms)"**로
  고쳤다. `mcu_ack` "모션 보드가 정지를 확인했어요 (n ms)"는 그 응답 자체라 그대로. [protocol.md](../protocol.md) 표에도 적었다.
- **키오스크의 같은 문장은 고치지 않았다**(이번 키오스크 수정 허용 범위 밖) — 남은 일. (뒤에 2차 평가 수리 `4852abf`에서 맞췄다) 발표·문서에서 화면의 ms를 정지까지 걸린 시간으로 말하지 않는다.
  verified까지의 전체 지연은 [실측 계획](../실측-계획-결선.md) G3의 B 구간으로 따로 잰다.

### 시험 수

백엔드+rpi4 **2,721 통과**, 10 skipped · 폰 **729** · 키오스크 **278**(골든 제외, 실패 0). 자세한 것은 [폰 UI devlog](devlog_2026-10-13-phone-ui.md) 끝 절.

## 2차 외부 평가(84점) 수리 — `/stop` null 결속·MCU 정지 id 결속·형식 오류 응답·키오스크 ms

시작 HEAD `370083c`. 근거: 저장소 밖 2차 평가(84/100, MEDIUM 2·LOW 2 + 1차 L2 잔여). 건마다 시험을 먼저 쓰고 수정 전 실패를 본 뒤 고쳤다.
평가를 반박한 항목은 없다. 가짜 HTTP·가짜 MCU 시험까지이며 **실물 미검증**은 그대로다.

| 항목 | 커밋 | 재현(코드 경로) | 수정 | 수정 전 실패 |
|---|---|---|---|---|
| M-N1 | `b1654ab` | 폰이 J1을 추적하는 사이 서버 실행이 끝나 `/stop`이 `stop_job_id:null`과 단계를 돌려주면, `outcome.jobId == null`이 옛 서버 호환 조건을 통과해 J1 문장에 실렸다(실행 중 화면·결과 뒤 늦은 응답 둘 다) | `StopOutcome.reportsJobId`로 필드 존재를 보존. 필드가 있으면 값이 내 job과 같을 때만, 없으면(옛 서버)만 종전처럼. [protocol.md](../protocol.md) 문장을 사실에 맞춤(키오스크는 `/stop` 응답을 읽지 않아 같은 경로 없음, `/status`는 이미 필드 존재를 구분) | `stop_report_binding_test.dart` 없음·null·다른 job·같은 job × (실행 중, 결과 뒤) 8건 + 파서 1건 — 실제 `RpiApiService` 파서→notifier. 수정 전 null 2건 실패(파서 시험은 구현 뒤 추가) |
| M-N2 | `751f89d` | 두 abort가 연속이면 첫 확인의 멈춤 확인(status) 도중 두 번째 MCU 정지가 `_last_stop`을 바꿔, 첫 `confirm_stop`이 두 번째 정지의 기록(`sent`)을 첫 `stop_id`로 보고했다 | `SerialMotionClient`가 정지 기록을 id별로 남기고(최근 16개) `last_stop_id`를 알린다. `confirm_stop`/`wait_stop_ack(stop_id=)`는 그 정지의 기록만, 기록이 없으면 다른 정지로 대신하지 않는다. MCU 응답은 그 id의 기록에 남는다. 실행기는 정지 전송 직전·직후 id로 확인을 묶는다(run·dev·hold drive·`dev_motion stop`) — 새 MCU 정지가 없으면 `sent`까지만 | `test_dev_motion.py` 두 abort 교차 1건(실제 `ActExecutor`→`SerialMotionClient`→`FakeMcu`, 첫 확인의 status를 붙잡은 사이 두 번째 abort, 두 번째 MCU 정지는 무응답): 수정 전 st1이 `sent`로 실패. `test_stop_confirm.py` +1(수정 전 `last_stop_id` 없음) |
| L-N1 | `079b5b1` | 주기 `/status`가 200 + `hold_state: 123`(TypeError)이면 FormatException이 아니어서 실패 두 번에 '닿지 않음'이 됐다 | `hubStatus`는 응답을 받은 뒤의 해석 실패(본문이 맵 아님·필드 타입 오류)를 모두 FormatException으로 알리고, 주기 조회는 이를 닿은 것으로 센다. 오류를 정상 상태로 처리하지는 않는다(걸림·대기 상태는 모름으로 둔다 — 종전과 같음) | `connection_poll_test.dart` +2(타입 오류·목록 본문, 조회 3번 넘게): 수정 전 2건 실패 |
| 1차 L2 잔여 | `4852abf` | 키오스크 `verified` 정지 줄이 "(n ms)" — 멈춤 확인까지의 시간으로 읽힘 | 폰과 같은 "멈춘 것을 확인했어요 (모션 보드 응답 n ms)", ms 없으면 숫자 없이 | 키오스크 기대 문구를 고친 3건 수정 전 실패 |

- M-N2 시험 보조: 실행기 `wait_dev()`가 끝난 정지 태스크만 남았을 때 완료 콜백이 돌 틈 없이 무한히 돌았다(모두 끝난 `gather`는 루프에 양보하지
  않는다). 교차 시험에서 드러나 같은 커밋에서 `asyncio.sleep(0)`을 더했다. 운영 경로가 아니라 시험·종료 절차용 함수다.
- M-N2 범위: 실행기 이벤트 루프 안에서 정지 전송이 동기로 끝나므로 직후의 `last_stop_id`가 이번 정지다. 다른 **스레드**가 같은 순간 MCU 정지를
  보내는 경합(예: 콘센트 비상정지 동기 경로)은 이 시험이 다루지 않는다. 실제 UART·보드 경합은 미재현.
- M-N1 범위: 새 폰 + 옛 서버(필드 없음)는 여전히 호환으로 단계를 싣고, 그 단계의 출처가 그 job인지 증명하지 못한다. 옛 폰 + 새 서버는 필드를
  무시하므로 폰도 함께 배포해야 한다([인계](../인계-2026-10-13-데스크톱.md) §6).

### 시험과 문서의 주장 범위(2차 평가 1~7) 정정

1. H1 서버 경합 시험의 RPi4 링크는 `_LateReportLink` 대역, 연속 정지 핸들 시험은 `_TwoStopClient` 대역 — 위 H1 절에 적었다. MCU 정지 id 결속은 M-N2.
2. 폰 H1 시험에 필드가 있는 null이 빠져 있었다 — M-N1에서 더했다. 후속 조회 중 새 실행 전환 시험이 모든 HTTP 도착 순서를 덮지는 않는다.
3. M1은 1초 주기 최대 3번 **시도**다 — 3초 보장 아님(위 M1 절 정정).
4. M2 시험 주기는 100 ms, '약 10초'는 설명값 — [폰 UI devlog](devlog_2026-10-13-phone-ui.md) M2 절 정정.
5. M3: `VoiceService` 초기화 캐시 때문에 같은 프로세스의 권한 회수까지 매번 재확인한다고 말하지 않는다 — 폰 UI devlog M3 절 정정.
6. L1: 출발 화면 대역·시험 라우터 — 앱 전체 라우팅 통과 아님(폰 UI devlog L1 절 정정).
7. 노트북 28건 비교는 시험 이름(과 기록된 곳에서는 오류 첫 줄)까지 — 오류 전문 동일이 아니다(위 시험 수 절 정정). 전체 Python 1회 실패를
   부하 시간 의존으로 본 것은 추정이다(폰 UI devlog 정정).

### 시험 수(ASCII 임시 worktree `C:\sl-test3`, HEAD `4852abf`, 골든 제외)

- 백엔드+rpi4 **2,721 통과·12 skipped**(`PYTHONUTF8=1`, `--basetemp C:\pt_tmp\…`, 저장소 폴더에서도 같은 수). 수집 2,733 = 직전 2,731 + 새 2건.
  통과 수가 직전과 같은 것은 `test_deploy_run_act.py` 2건이 이 셸에서 `sh`를 찾지 못해 건너뛰었기 때문이다(직전 10 skipped → 12, 환경 차이).
- 폰 **740 통과**(729 + 11), 실패 0. `flutter analyze` error·warning 0(기존 info 4).
- 키오스크 **278 통과**(기존 시험의 기대 문구만 고침 — 개수 그대로), 실패 0. `flutter analyze` error·warning 0(기존 info 1).
- 골든은 실행·갱신하지 않았다. 바뀌는 장면: 키오스크 정지 줄이 `verified`인 장면(있다면). `rpi/tests/test_repo_guard.py` 통과.

### 남은 것

- 실물: 실제 ESP32 정지 응답·연속 정지 경합·verified, RPi5·RPi4·폰·키오스크 같은 커밋 배포([인계](../인계-2026-10-13-데스크톱.md) §6).
- 다른 스레드의 동시 MCU 정지와 확인 결속(M-N2 범위 밖), 새 폰 + 옛 서버 호환의 출처 증명 불가(M-N1 범위 밖).
- 실기기 TalkBack·200%·권한 창, 골든 눈 검토·갱신, 짧은 허브 재시작, 확인 주행 기록 서버 저장 — 인계 §0 남은 일 그대로.
