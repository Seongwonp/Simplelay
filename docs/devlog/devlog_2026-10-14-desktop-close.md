# 2026-10-14 데스크톱 — 노트북 마감 인계 1~6 끝내기(잠시 쉬기 영속 합침·경보 표·배포 전 확인·재확인 목록)

[노트북 인계](../인계-2026-10-14-노트북-마감.md) '이어서 할 것' 1~6을 순서대로 했다.

- 새 기능은 넣지 않았다. wip 브랜치의 잠시 쉬기 영속은 인계가 정한 범위다.
- force push와 이력 재작성은 하지 않았다. 공개 이력 처리도 하지 않았다.
- HTTP 평문은 미해결 위험으로 둔다.

## 커밋

| 커밋 | 내용 |
|---|---|
| `283ffd5` | 노트북 인계 문서의 벤더 고유 명칭을 일반 표현으로 바꿨다. `37c0183`이 저장소 가드에 걸려 main에서 실패하고 있었다 |
| `98df3ea` | `wip/pause-persist`(`d75ac72`)를 정리해 합쳤다: 잠시 쉬기 끝 시각·범위를 서버에 저장한다. **RPi5에 curl이 없어 wget으로 읽도록 고친 것**도 함께 넣었다 |
| `aee3e18` | 배포 전 확인 시험 3묶음(동작 코드 변경 없음) |
| (이 기록) | 경보 다섯 상태 표, `setup_rpi.sh` 안내, 인계 §8-12, 이 기록 |

- wip 커밋은 main 위에 새 메시지로 다시 만들었다. 원격 `wip/pause-persist` 브랜치는 그대로 두었다(지우지 않음).

## 1. 잠시 쉬기 영속 — 시험 결과 세 칸

새 시험은 수정 전(main)에서 먼저 돌려 실패를 확인했다.
- 서버 12건 실패, wget 경로 1건 실패.
- 폰·키오스크 새 시험은 main에서 컴파일 실패(새 필드 없음).

| 기존 설정 이전 | 새 설정 저장 | 재시작 후 복원 |
|---|---|---|
| **확인 가능한 값일 때만 옮긴다.** 배포 스크립트가 컨테이너를 지우기 **전에** 실행 중 서버의 공개 `/health`에서 `dnd_until`을 읽어 새 컨테이너에 넘긴다. 서버가 다시 검사한 뒤 옛 범위(새 제안만 쉼, 자동 실행은 그대로)로 이어받는다(`test_carried_over_old_pause_keeps_the_old_scope_and_does_not_block_auto_run`) | 새로 켠 잠시 쉬기는 끝 시각과 새 범위(새 제안과 아직 시작하지 않은 자동 실행)로 DB에 저장된다(`test_new_pause_is_saved_with_its_end_time_and_new_scope`) | 재시작 뒤 표시한 끝 시각까지 유지되고, 자동 실행도 계속 쉰다(`test_new_pause_is_restored_after_a_restart_and_still_blocks_auto_run`) |
| 쓰지 않는 값: 빈 값, 해석 불가, 오프셋 없는 시각, 지난 시각, 24시간 넘음(5건). 업데이트 뒤 켠 값은 덮지 않는다. 같은 값은 한 번만 쓴다 | — | 끝 시각이 지나면 풀린다(`test_restored_pause_is_released_at_its_end_time`) |
| 값을 읽지 못하면 **"업데이트 뒤 잠시 쉬기 재설정 필요"**, 값이 null이면 "이어받을 잠시 쉬기 없음", 새 서버면 "서버 DB에 남아 있음"을 출력하고 아무것도 넘기지 않는다(배포 시험 4건). 넘긴 값이 없으면 복원하지 않는다(`test_pause_from_a_memory_only_server_is_not_restored_without_a_carried_value`) | — | 이어받은 값도 재시작 뒤 한 번만 쓰고 유지된다(`test_carried_over_pause_is_used_once_and_survives_a_restart`) |
| **고친 것:** RPi5 기기에는 `curl`이 없고 busybox `wget`만 있다(보드에서 확인). 원래 스크립트는 기기에서 늘 '읽지 못함'이 되어 이어받기가 한 번도 일어나지 않았을 것이다. curl이 실패하면 wget으로 읽는다(`test_board_without_curl_reads_the_old_pause_with_wget`, 수정 전 실패). 보드의 지금 서버에서 `wget`으로 `/health`를 읽는 것까지 확인했다 | | |

전체 시험(`98df3ea`):
- 백엔드+rpi4 3,073 통과(ThinQ SDK 설치로 건너뜀 없음). 가드 실패 1건은 `283ffd5`로 고쳤다.
- 폰 823, 키오스크 344(골든 제외), 골든 55·44 통과.
- analyze error·warning 0.

## 2. 경보 정책 표

[조용한 시간 기록](devlog_2026-10-14-quiet-hours.md) §3을 다섯 상태로 다시 썼다.
- 각 행을 `/status`·`/alerts`에서 지금 확인할 수 있는 값에 대응시켰다(`estop_latched`, `/alerts.active`, `last_abort_reason`, `last_outcome`, `last_stop_level`, `last_stop_job_id`, `last_status`·`last_receipt`, `hold_stop_outcome`).
- 판별할 수 없는 경우는 "판별 불가 — 정책 보류"로 두었다.
  - 사용자 정지인데 `mcu_ack`에서 끝난 경우
  - 정지 단계 보고가 없는 경우(null)
- ②의 '멈춤 확인' 근거는 MCU 알람 보고뿐이라는 점을 적었다.
- **코드는 바꾸지 않았다. 사용자 확정 전이다.**

## 3. `setup_rpi.sh`

- Act 모드 확인 안내를 `/health/detail`(공개 `/health`는 ok·version만)로 바꿨다.
- mDNS 확인 안내에 '생존 확인만'과 인증 경로(`X-API-Key`)를 적었다.

## 4. 배포 전 확인(시험) — `aee3e18`

- **키오스크 실제 헤더:** 네이티브 앱은 `Content-Type`만 보낸다(Dart HTTP).
  - `/status`·`/stop`은 기존 시험이 있었다. `/suggestions`·`/health/detail`과 승인·허용 승인·거절을 추가했다.
  - 승인·허용 승인·거절은 출처 검사를 지나 404(없는 카드)가 나온다. 다른 사이트 Origin이 붙으면 403이다.
  - 변형 확인: 헤더 없는 요청을 막게 하면 3건이 실패한다.
- **`/health/detail` 실패:** 401·연결 실패·타임아웃·해석 실패를 넣었다.
  - 폰 `health()`는 null을 돌려준다(준비됨 아님, 잠시 쉬기는 마지막 값 유지).
  - 키오스크 `checkHealth`는 `ok=false`·`actuatorReady=false`·조용한 시간 '모름'이다.
  - 타임아웃은 `.timeout()`이 던지는 예외를 흉내 냈다. 실제 4·8초를 기다리지는 않았다.
  - 변형 확인: 실패를 준비됨으로 바꾸면 폰 5건·키오스크 4건이 실패한다.

## 5. 인계 §8-12

[인계 2026-10-13](../인계-2026-10-13-데스크톱.md) §8-12에 두 가지를 적었다.
- 7000 포트는 **ⓐ 설정 여부와 ⓑ 실제 차단 결과를 함께** 기록한다. ⓑ를 보지 않았으면 '제한 설정됨·차단 미확인'으로 적는다.
- HTTP 평문은 **"미해결 위험(전용 망·접근 제한으로 완화, TLS 미적용)"**이고, '해결'로 적지 않는다.

## 6. 재확인 목록 (외부 재확인용, 코드 기준 `aee3e18`)

아래를 한 번에 돌려 **90 통과**(`aee3e18`, Windows `.venv`, ThinQ SDK 1.0.14 설치).

```
python -m pytest rpi/tests/test_auto_rule_eval4.py rpi/tests/test_quiet_close.py rpi/tests/test_pause_persist.py \
  rpi/tests/test_quiet_hours.py rpi4/tests/test_link_key_required.py rpi/tests/test_loopback_origin.py \
  rpi/tests/test_health_public.py rpi/tests/test_deploy_run_act.py rpi/tests/test_deploy_run_backend.py
```

| 항목 | 시험 | 확인할 것 |
|---|---|---|
| 기존 HIGH 1 | `test_auto_rule_eval4.py::test_revoke_completed_after_the_final_guard_returned_but_before_the_post_sends_nothing` | 최종 guard 반환 → 끄기 완료 → POST 0건 |
| 기존 HIGH 2 | `test_auto_rule_eval4.py::test_stop_reaches_request_stop_while_a_rule_save_waits_on_the_db_and_a_guard_waits_on_the_store` | DB 쓰기 대기 + 실행 guard + 전체 정지에서 `request_stop`이 바로 불림 |
| 조용한 시간·잠시 쉬기 경계 | `test_quiet_close.py::test_quiet_or_pause_after_the_final_guard_but_before_the_post_sends_nothing[schedule·pause]` | 최종 재판정 뒤 켜도 POST 0건 |
| **결합(인증+조용한 시간+잠시 쉬기)** | `test_quiet_close.py::test_quiet_pause_and_auth_together_still_block_unsent_auto_runs_and_let_stop_through` | API 키 켬, 둘 다 켜면 POST 0건, 키 없는 LAN 정지 401(정지 진입 0), LAN(키)·키오스크(루프백) 정지는 1초 안에 진입. 변형 확인: 자동 실행 조용한 시간 판정을 끄면 실패 |
| 잠시 쉬기 영속 | `test_pause_persist.py`(11)·`test_deploy_run_backend.py`(8) | 위 1절 세 칸 |
| 보안 ① 링크 키 필수 | `rpi4/tests/test_link_key_required.py`(9) | 키 없으면 RPi4·RPi5(uart) 시작 거절, 무인증은 명시 모의에서만 |
| 보안 ② 루프백 출처 | `test_loopback_origin.py`(16) | 다른 사이트 Origin·`null`·cross/same-site는 403(제어 0회), 키오스크 실제 헤더는 통과 |
| 보안 ③ 공개 /health 축소 | `test_health_public.py` | 공개는 생존·버전만, 상세는 키(루프백 키오스크는 면제) |
| 보안 ⑤ RPi4 7000 제한 | `test_deploy_run_act.py::test_link_port_can_be_limited_to_the_hub_address`·`test_link_allow_from_rejects_anything_but_an_ipv4_address` | `SIMPLELAY_LINK_ALLOW_FROM`이면 그 주소만(range=/32), IPv4가 아니면 컨테이너를 세우지 않음 |

**미검증:** 위는 전부 시험(모의 클라우드·가짜 링크) 수준이다. 실기기 확인은 아래 '보드' 절에 따로 적는다.

## 보드 (같은 날 저녁, 실물)

### 배포 — 4종 같은 커밋 `6ea19be`

| 대상 | 확인 |
|---|---|
| RPi5 백엔드 | 이미지 `1aa2733db8ac` |
| RPi4 실행기 | 같은 이미지, `run_act.sh`는 HEAD 판, `link auth on`·`new session` |
| 키오스크 ipk | 실패널 `arc install` 성공(빌드 컨테이너가 다시 쓴 `pubspec.lock`은 되돌림) |
| 폰 APK | 에뮬레이터(x86_64, split-per-abi) |

- 배포 전에 두 보드의 `SIMPLELAY_LINK_KEY`를 확인했다. 둘 다 있고 값이 같았다(해시 비교, 값은 출력하지 않음).
- `SIMPLELAY_ALLOW_UNAUTHENTICATED`·`SIMPLELAY_LINK_AUTH` 줄은 두 보드 모두 없었다. env 파일 권한은 600이다.
- RPi5 env에 `SIMPLELAY_DEV_MODE`·`SIMPLELAY_DEV_REAL_MOTION`이 켜져 있다(보정·시험용). **평가 전에 끈다**(인계 §8-12).

### 잠시 쉬기 세 칸 — 실물

- **기존 설정 이전:**
  - 업데이트 전 서버(568f995)에 60분 잠시 쉬기를 켰다. 공개 `/health`는 `...Z` 꼴로 알렸다.
  - 배포 스크립트가 `wget`으로 읽어 "잠시 쉬기 이어받기: … 까지, 업데이트 전 범위"를 출력했다.
  - 새 서버 `/health/detail`은 같은 끝 시각에 `dnd_scope=suggestions_only`, 문장은 "업데이트 전에 켠 잠시 쉬기라 … 자동 실행은 그대로예요"였다.
  - 이 확인 중에 RPi5에 curl이 없다는 것과 `Z` 꼴을 못 읽는다는 것을 찾아 고쳤다(`98df3ea`·`6ea19be`).
- **새 설정 저장:** 새로 켠 30분은 `suggestions_and_auto`로 저장됐다.
- **재시작 후 복원:**
  - 컨테이너를 재시작한 뒤에도 두 경우 모두 그대로였다.
  - 1분짜리는 70초 뒤 재시작했을 때 풀려 있었다.
  - 끝난 뒤 잠시 쉬기는 꺼 두었다.

### 보안 §8-12 — 실물

- 데스크톱(LAN)에서 키 없이: `/health` 200(생존·버전만), `/health/detail`·`/status`·`POST /stop` 401.
- RPi5 루프백에서: 헤더가 없으면 200. `Origin: https://evil.example`·`Origin: null`·`Sec-Fetch-Site: cross-site`는 403.
- **7000 포트:**
  - ⓐ 설정: RPi4 env에 `SIMPLELAY_LINK_ALLOW_FROM` 있음, RPi5 주소와 같음. 백업은 `env.bak-20261014-allowfrom`.
  - ⓑ 실제 차단 확인 방법: RPi5 백엔드를 멈추고 데스크톱에서 먼저 접속했다.
  - 제한 전에는 접속이 유지됐다. 제한 뒤에는 즉시 닫혔다(socat `refusing connection … due to range option`).
  - 이어서 RPi5 링크는 정상으로 붙었다(`new session`, `actuator_ready: true`).
  - **RPi5 주소가 바뀌면 링크가 끊긴다** — 공유기 DHCP 예약 필요.
- HTTP 평문: 미해결 위험(완화만).

### 다음 보드 날 순서 — 결과

1. **남은 '아침 데우기' 시험 제안:** 서버 재시작으로 사라졌다. 기록을 보면 실행된 적이 없다.
2. **실패 화면 '닫기' → 대기 승인 카드:**
   - 실패 화면 중에 루틴 카드를 만들고, 사용자가 '닫기'를 눌렀다. 1초 간격으로 연속 캡처했다.
   - '닫기' 뒤 평소 화면이 나오고, **약 1초 뒤 대기 카드가 떴다.**
   - 카드는 "내 루틴 '아침 데우기'"·'누를 버튼'이었고, '경로 확인 필요' 칩과 근거 줄은 없었다(`b5f5c2c` 실물 확인).
   - 20초 카운트다운 뒤 평소 화면으로 돌아갔다.
   - 같은 카드는 한 번 보인 뒤 다시 뜨지 않는다. 처음 확인에서 카드가 안 보였던 것은 카운트다운이 끝난 뒤 캡처했기 때문이다.
   - 시험 카드는 모두 거절해 정리했다.
3. **원점·실제 성공 경로·이동 중 정지:** **못 했다 — 모터 B 하드웨어.**
   - 시험대 원점(`homed=true`) 뒤 폰에서 '아침 데우기'를 실행했다.
   - 즉석밥 이동(A만)과 누름 신호는 정상이었다. 시작 이동에서 B 엔코더 0 → `stall` → 재시도 없이 멈췄다.
   - 폰·키오스크는 "모터가 걸려 멈췄어요. 다시 누르지 않았어요"를 보였다. 걸린 뒤 원점이 풀려 조그가 거절됐다.
   - 진단:
     - 손으로 돌리면 엔코더 B가 0 → 2,434를 센다. 엔코더는 정상이다.
     - 시험용 펌웨어로 B 칸에 직접 40% 2초씩 주면 B 0이고, 같은 시험에서 A는 3,862다.
     - 모터 묶음을 맞바꾸면 오른쪽 모터가 A 칸에서 175를 센다. 모터는 정상이다.
     - 사용자 확인: **B 드라이버 전원 LED 꺼짐 → 켠 뒤에도 안 돎.**
     - 배터리를 다시 꽂은 뒤(11:13~)에는 엔코더 A도 −3~1에 머물렀다. 빠진 단자 하나를 다시 꽂은 뒤(11:16)에는 엔코더 A·B 모두 0이었다. **사용자가 보기에 A 모터는 실제로 돌았다** — 그러면 그때는 엔코더 A 신호가 ESP32에 들어오지 않은 것이다(모터가 안 돈 것이 아님).
   - **결론:** B 드라이버 쪽 모터 전원(VM) 또는 그 채널. 배터리·전원 배선 점검이 필요하다(HW 담당).
   - 펌웨어는 시험대 빌드로 되돌렸고, USB는 RPi4에 다시 꽂았다. 실행기는 재시작 없이 포트를 다시 열었다.
   - 끊기는 순간의 정지는 '확인 못 함'으로 잠겼고, 다시 정지하자 풀렸다(6 ms).

### 남은 것

- **모터 전원:** B 드라이버 VM과 배터리 상태 점검 → 원점 → 실제 성공 경로 → 이동 중 정지.
- RPi5 env의 개발자 실물 조작 끄기(평가 전).
- 공유기 DHCP 예약(RPi5 주소 고정).
- 실폰, TalkBack.
