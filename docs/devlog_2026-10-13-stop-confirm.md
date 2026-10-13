# 2026-10-13 노트북 — 정지 확인을 "보냄"과 "확인"으로 나눔

[정지 확인 계획](계획-정지-확인-2026-10-12.md) "순서와 크기" 1~4단계를 구현했다. 배경은
[10/12 devlog](devlog_2026-10-12-motion-bringup.md) 발견 2: RPi4가 정지 줄을 **쓰기만** 하고 MCU 응답은 버렸는데,
RPi5 `/dev/stop`·세션 끝·폰은 "정지를 확인했어요"라고 말했다(과장).

**보드 없이 가짜 MCU(`rpi/tools/fake_mcu.py`)로만 시험했다. 실물 미검증.** 5단계(실물 확인·배포)는 하지 않았다.

## 무엇을

| 단계 | 커밋 | 내용 |
|---|---|---|
| 1 | `3be54d1` | RPi4 `SerialMotionClient`: `request_stop()`은 그대로 바로 돌아오고 보낸 id·시각을 남긴다. 진행 중 요청의 읽기 루프가 정지 응답을 버리지 않고 기록하고, 대기 중이면 `wait_stop_ack()`가 짧은 기한(0.3 s) 안에 직접 읽는다(읽는 쪽은 op 잠금을 쥔 하나). `confirm_stop()`은 MCU 확인 뒤 `status` 두 번(0.1 s 간격)의 엔코더 a·b가 같을 때만 `verified`. `ok:false` 응답·옛 정지의 늦은 응답은 확인이 아니다 |
| 2 | `98a7e5f` | RPi4 규약: `dev_motion stop` 답에 `stop_level`·`ack_ms`(개발자 조작 규약 **2**), `abort {stop_id}`에 새 `stop_report {stop_id, target, stop_level, ack_ms}`(정지 보고 규약 1, `act_info.stop_report_protocol`). 정지 줄을 먼저 쓰고 확인은 따로 기다려 읽기 루프를 막지 않는다. `stop_id` 없는 옛 abort에는 종전처럼 답하지 않는다. act_main은 serial일 때만 실제 어댑터로 확인하고 모의 모션은 `sent`. 줄 기록에 `>> stop`과 `<< {"id":…,"ok":true}`가 둘 다 남는다. [protocol.md](protocol.md) 갱신 |
| 3 | `b97fa86` | RPi5: `confirmed`는 **`mcu_ack` 이상일 때만** 참(`rpi/services/stop_confirm.py`). 단계 없는 답(옛 RPi4)·모르는 값·`abort drive` 대체는 `sent`. `sent`는 잠그지 않되 "정지 명령을 보냈어요 — 멈췄는지 기계를 봐 주세요". 일반 `/stop`은 abort를 먼저 보내고 보고를 최대 약 1.5 s 기다려 `stop_level`·`stop_ack_ms`·`stop_target`·`stop_confirmed`로 돌려주고, `/status`에 `last_stop_level`·`last_stop_ack_ms`(새 실행에서 지움). 정지 보고 규약을 모르는 RPi4는 기다리지 않는다 |
| 4 | `66402a9` | 폰: 개발자 도구 정지·세션 끝, 실행 화면 정지 안내, 멈춘 실행의 결과 문장. 키오스크: 멈춘 실행 화면에 정지 줄(확인이면 확인색, 보냄이면 주의색). 단계가 없는 옛 서버·모의는 종전 문장 그대로 |

문구: `sent` "정지 명령을 보냈어요 — 멈췄는지 기계를 봐 주세요" · `mcu_ack` "모션 보드가 정지를 확인했어요 (n ms)" ·
`verified` "멈춘 것을 확인했어요 (n ms)". 모의 개발자 어댑터는 단계 없이 종전처럼 `confirmed:true`.

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
- 폰(골든 제외): **591 중 563 통과, 28 실패.** 실패 28건은 HEAD(`c220b49`)에서도 **같은 28건**이다(목록 비교 일치) —
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

[실측 계획](실측-계획-결선.md) §3에 모션 MCU 구간 두 개를 더했다: **A. `sent → mcu_ack`**(줄 기록 `>>`/`<<` 또는 `ack_ms`),
**B. `sent → verified`**(두 번째 `status` 응답). `stop.csv` 선택 열 `t_sent_ms`·`t_mcu_ack_ms`·`t_verified_ms` — 그림 도구는 아직
이 열을 그리지 않는다(첫 측정 뒤 넓힌다).
