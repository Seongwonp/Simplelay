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
