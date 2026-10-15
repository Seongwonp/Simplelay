# 백엔드 시험 지도 (`rpi/tests` + `rpi4/tests`)

> 역할: 허브 백엔드·RPi4 실행기 시험(pytest). `rpi/tests` 시험 파일 178개 + `rpi4/tests` 25개, node 시험 3개(`*.test.cjs`).
> 10/15 기준 **3,189 통과·10 건너뜀**(골든 없음) — 인증 범위 시험(`test_route_auth_coverage.py`, 4건)을 더한 뒤 3,193. 모의·합성 입력 시험이며 실물 동작을 대신하지 않는다 — 실물 수준은 [README](../../README.md) 검증 수준 표.

## 실행

```powershell
$env:PYTHONUTF8=1
.\.venv\Scripts\python.exe -m pytest -q --basetemp <ASCII 고유 경로>          # 전체(testpaths = rpi/tests, rpi4/tests)
.\.venv\Scripts\python.exe -m pytest -q rpi/tests/test_serial_motion.py       # 파일 하나
.\.venv\Scripts\python.exe -m pytest -q rpi/tests/test_repo_guard.py rpi/tests/test_doc_links.py   # 커밋 전 게이트
node --test rpi/tests/*.test.cjs                                              # 트윈·미리보기 스크립트(pytest 밖)
```

- 설정은 `pyproject.toml`의 `[tool.pytest.ini_options]`(`testpaths`, `pythonpath = ["."]`). 별도 마커(slow 등)는 없다.
- `conftest.py`는 `SIMPLELAY_ALLOW_UNAUTHENTICATED=1`을 기본으로 켠다(시험 클라이언트 주소가 루프백이 아니어서). 인증 규칙 자체는 `test_auth.py`가 이 값을 지우고 본다.
- **건너뜀은 실행 중에 정해진다:** 선택 의존성이 없으면(`thinqconnect` — ThinQ SDK·자동 실행·정지 재확인 일부, `dbus_fast`, `matplotlib`) 또는 `sh`·`git`이 없으면 건너뛴다.
- 시험 파일끼리 도우미를 import한다(예: `test_eval_recheck_stop`의 정지 계측, `test_serial_motion`의 가짜 MCU 도우미). **파일 이름을 바꾸면 다른 시험이 깨진다.**
- 시험 대부분이 모듈 속성을 직접 바꿔 끼운다(`monkeypatch.setattr(모듈, ...)`) — 코드를 다른 모듈로 옮기면 시험이 실패하지 않고 **조용히 약해질** 수 있다([코드 구조](../../docs/코드-구조.md) §7).

## 부하에 민감한 시험 — 실패하면 단독으로 다시 돌린다

다른 무거운 작업(폰·키오스크 시험 등)과 동시에 돌 때 시간 경계로 가끔 실패한 기록이 있다. 실패하면 **그 시험만 단독으로 다시 돌려** 통과를 확인하고, 단독에서도 실패하면 진짜 실패로 본다.

| 시험 | 왜 민감한가 |
| --- | --- |
| `test_air_quality_suggestion.py::test_stop_is_not_delayed_by_a_stalled_air_quality_read` | 판독 스레드를 멈춘 채 `/stop` 진입이 0.5초 안인지 잰다 |
| `test_sensor_window.py::test_first_run_with_default_config_succeeds_on_first_press` | 실제 스레드 창과 수 ms 박자에 의존 |
| `test_sensor_verifier.py::TestSensorVerifier::test_result_satisfies_verification_result_invariant` | 배경 읽기 스레드와 실제 대기 시간 |
| `test_serial_motion.py`의 시간 기반 시험 1건(기록에 이름 없음 — 후보: `test_timeout_sends_stop_and_requires_rehome`, `test_request_stop_interrupts_a_blocking_move_from_another_thread`) | 짧은 기한(0.03~0.1초)과 스레드 |
| `test_act_client.py::test_late_result_after_timeout_is_discarded_not_matched_to_next_job` | 응답 기한 0.05초 |

정지 진입 시간 시험(`test_eval_recheck*_stop.py`)의 기준값은 개발 PC 기준이며 "어떤 부하에서도 정지를 보장한다"는 뜻이 아니다(파일 머리말).

## 이력 이름 시험이 지키는 것

파일 이름이 평가 회차·날짜에서 왔다. 이름 대신 뜻으로 읽는다.

| 파일 | 지키는 것 |
| --- | --- |
| `test_auto_rule_eval4.py` | **자동 실행 경계**(4차 외부 평가 10/14) — 규칙 저장이 DB를 기다려도 `/stop` 진입이 늦지 않음, 최종 재판정과 전송 사이 철회 직렬화, 시각 기준점·단조 시계 축 |
| `test_eval_recheck_stop.py` | **정지 줄·DB 대기 1차**(HIGH 재확인 10/14) — 설정·루틴 저장이 DB에서 멈춰도 `/stop`이 0.5초 안에 진입, 저장 실패를 성공으로 숨기지 않음 |
| `test_eval_recheck2_stop.py` | **정지 줄·DB 대기 2차** — 공유 스레드 풀 고갈·잠금 대기에도 정지 진입, 동시 변경이 지운 루틴·규칙을 되살리지 않음, 설정 응답과 저장이 같은 판 |
| `test_startup_init_stop.py` | 재시작 직후 첫 서비스 생성이 `/stop`을 막지 않음 |
| `test_eval64_documents.py` | 공개 문서·배포 설정 서술 회귀(실물 증거 아님) — 예시 env의 채널·L3 설정이 실제로 해석되는지, 옛 과소·과대 서술이 없는지 |
| `test_demo_v3_gaps.py` | 시연 v3 갭 S1~S5 — v2 시나리오는 명시적으로만, 루틴 템플릿 4종, 등록 응답의 실행 가능 여부, 리허설 비상정지, 키오스크 안내 우선순위 |
| `test_eval_fixes_routines.py` | 10/06 평가 수리(허브 쪽) — 루틴 사이클 끝 대기·가전별 시간 제한·정지가 대기 루틴 취소·UART 리허설은 실물 있으면 거절 |
| `rpi4/test_eval_fixes_outlet.py` | 같은 평가의 RPi4 쪽 — 채널 대응 비면 기동 거절, 릴레이 채널 검증, 콘센트 모듈 재부팅 걸림은 사람 확인까지 유지 |
| `test_demo_gaps_g5_g10_g13.py` | 시연 갭 G5·G10·G13(9/29) — 가전 제어 경로 표시, 부재 중 수동 시나리오 거절, 위험 경보 주입 |
| `test_thinq_g3_g6.py` · `test_thinq_u1.py` | ThinQ 시나리오·모의 장애 주입(G3·G6), **ThinQ 명령 계약 핵심**(U1 — 승인 결속·`state_confirmed`·응답 유실은 unknown·재전송 없음·PAT 비노출) |

안전 보고의 G1~G11(정지 빈칸)과 위 G 번호(9/29 시연 갭)는 서로 다른 목록이다.

## 영역별 지도

접두사 없음 = `rpi/tests`, `rpi4/` = `rpi4/tests`.

### 인증·보안
`test_auth.py`(API 키·루프백 면제·개방 플래그) · `test_route_auth_coverage.py`(모든 경로의 키 검사 누락 — 허용 목록만 예외) · `test_loopback_origin.py`(루프백 면제의 출처 확인) ·
`test_pairing.py`(폰 연결 승인·1회 키·만료) · `test_health_public.py`(공개 `/health` 축소) · `test_schema_limits.py`(요청 상한) ·
`rpi4/test_link_auth.py`(링크 서명·재전송·키 불일치) · `rpi4/test_link_key_required.py`(링크 키 없으면 기동 거절)

### 승인·명령 계약
`test_command_args.py`(인자 정규화·지문) · `test_command_models.py`(`ApprovedCommand` 불변 조건) · `test_command_physical.py`(결과 → 확인 수준) · `test_result_outcome.py` ·
`test_execution_provenance.py`(실행 출처 결속) · `test_execution_mode_routing.py` · `test_execution_target_gate.py`(모든 진입점의 대상 검증) · `test_sequence_limit_gate.py` · `test_experiment_record.py`

### 실행·job·상태
`test_service.py` · `test_service_lifecycle.py` · `test_service_node_routing.py` · `test_router.py` · `test_closed_loop.py` · `test_layered_verification.py`(L1~L3 복구 정책) ·
`test_progress_tracker.py` · `test_history.py` · `test_persistence.py` · `test_status_appliance_target.py` · `test_sse_events.py` · `test_control_arbiter.py`(제어권 상호 배제) ·
`test_controller_factory.py` · `test_controller_factory_pacing.py` · `test_shutdown.py` · `test_failure_recovery_matrix.py`(자동 재전송·재개 없음) ·
`test_node_registry.py` · `test_esp_node_controller.py` · `test_espnow_node_controller.py`(예비 노드 경로)

### 정지·정지 확인·비상정지
`test_stop_endpoint.py` · `test_emergency_stop_broadcast.py` · `test_stop_confirm.py`(sent → mcu_ack → verified) · `test_stop_report_rpi5.py`(정지 보고를 `/stop`·`/status`에 반영) ·
`test_stop_hold_e2e.py` · `test_stop_hold_sim.py` · `test_stop_park.py` · `test_estop_latch_api.py`(비상정지 래치·`/stop/ack`) ·
`test_eval_recheck_stop.py` · `test_eval_recheck2_stop.py` · `test_startup_init_stop.py`(위 이력 표) · `rpi4/test_act_hold.py` · `rpi4/test_stop_hold.py`

### RPi5↔RPi4 링크
`test_act_client.py` · `test_act_client_controller.py` · `test_act_client_first_connect.py` · `test_act_client_reconnect.py` · `test_act_link_keepalive.py` · `test_act_target.py` ·
`test_link_tap.py` · `test_payload_budget.py` · `test_event_clock_bounds.py` · `rpi4/test_act_executor.py` · `rpi4/test_act_link_integration.py`(실제 클라이언트↔실행기 메모리 연결) ·
`rpi4/test_act_link_retry_l3.py` · `rpi4/test_act_progress.py` · `rpi4/test_bridge.py` · `rpi4/test_clock_ref.py` · `rpi4/test_sequence_store.py`

### 모션·누름 어댑터
`test_serial_motion.py`(모션 보드 어댑터·가짜 MCU) · `test_kinematics.py` · `test_jog_cli.py` · `test_motion_abort.py` · `test_motion_connect.py` · `test_motion_corexy_firmware.py`(펌웨어 정적 대조) ·
`test_motion_protocol_table.py`(어댑터·가짜 MCU·펌웨어 규약 표 일치) · `test_motion_z_mode.py` · `test_press_coordinates.py` · `test_actuator_status.py` · `test_dbus_gpio.py` ·
`rpi4/test_act_main_motion.py` · `rpi4/test_act_motion_abort.py` · `rpi4/test_motion_port_reopen.py`

### 콘센트·L3·센서 판정
`test_outlet_channels.py` · `test_outlet_protocol.py` · `test_power_verifier.py` · `test_power_operation_verifier.py` · `test_power_tail.py` · `test_cycle_end.py` · `test_end_beep.py` ·
`test_done_fusion.py` · `test_fusion_truth_table.py` · `test_sensor_verifier.py` · `test_sensor_window.py` · `test_sensor_config_check.py` · `test_current_generation.py` ·
`test_danger_sound.py` · `test_alert_store.py` · `test_press_recorder.py` · `test_raw_recorder.py` · `rpi4/test_appliance_done_watch.py` · `rpi4/test_danger_sound_monitor.py` ·
`rpi4/test_outlet_channels_wiring.py` · `rpi4/test_outlet_l3.py` · `rpi4/test_target_binding.py` · `rpi4/test_act_main_recorder.py` · `rpi4/test_eval_fixes_outlet.py`

### 제안·습관·의도
`test_suggestion_context.py` · `test_suggestion_feedback.py` · `test_suggestion_lifecycle.py` · `test_suggestion_race.py`(승인·거절 동시성) · `test_suggestion_revision.py` · `test_suggestion_snooze.py` ·
`test_suppression.py` · `test_completed_actions.py` · `test_learning_evidence.py` · `test_learning_status.py` · `test_usage_appliance.py` · `test_empathy.py` · `test_environment.py` ·
`test_cook_done_card.py` · `test_presence.py` · `test_presence_state.py` · `test_presence_state_api.py` · `test_rules.py` · `test_llm_intent.py` · `test_tiered_intent.py` ·
`test_vectordb_intent.py` · `test_vectordb_seed.py` · `test_dbus_agent.py` · `test_dbus_native.py` · `test_http_llm_client.py` · `test_deps.py`

### 조용한 시간·잠시 쉬기
`test_quiet_hours.py` · `test_quiet_close.py` · `test_pause_persist.py`

### 루틴·자동 실행 규칙
`test_routines.py` · `test_routine_wait_done.py` · `test_routine_thinq_step_app_shape.py` · `test_appliance_done_routine.py` · `test_habit_routine_draft.py` · `test_eval_fixes_routines.py` ·
`test_auto_rules.py`(필수 조건 6가지) · `test_auto_rule_boundary.py` · `test_auto_rule_e2e.py`(가열 종료 → 규칙 → SDK → 모의 클라우드) · `test_auto_rule_eval4.py`

### ThinQ·공기질
`test_thinq_u1.py` · `test_thinq_g3_g6.py` · `test_thinq_already_at_target.py` · `test_thinq_discovery.py` · `test_thinq_estop_direct.py` · `test_thinq_probe_script.py` ·
`test_thinq_profile_gate.py` · `test_thinq_sdk_client.py` · `test_thinq_sdk_e2e.py` · `test_thinq_sdk_profile.py` · `test_air_quality_suggestion.py`

### 날씨·평소 화면·서버 문구
`test_weather_kma.py` · `test_weather_service.py` · `test_ambient_api.py` · `test_ambient_builder.py` · `test_hub_location.py` · `test_connections.py` · `test_kiosk_serving.py` · `test_server_wording.py`(화면에 나가는 서버 문장 용어표)

### 가전 등록·준비 판정·사진 매핑
`test_appliance_catalog.py` · `test_appliance_manifest.py` · `test_appliance_registry.py` · `test_appliance_revision.py` · `test_appliance_readiness.py` · `test_readiness_invalidation.py` ·
`test_readiness_list_parity.py` · `test_builtin_visibility.py` · `test_button_map_extension.py` · `test_calibration_api.py` · `test_calibration_transform.py` · `test_panel_mapping.py` ·
`test_panel_scan.py` · `test_panel_scan_api.py` · `test_vision_client.py`

### 개발자 API
`test_dev_api.py` · `test_dev_real_motion.py` · `test_developer_session.py`(세션 안전 불변식) · `test_developer_wiring.py` · `test_probe_history.py` · `rpi4/test_dev_motion.py` · `rpi4/test_dev_motion_link.py`

### 시뮬레이터·트윈
`test_simulator_controller.py` · `test_twin_view.py` · `test_twin_real_mode.py` · `test_parking_rehearsal.py` · `test_routine_rehearsal.py` · `rpi4/test_simulator.py` · `rpi4/test_parking_simulator.py` ·
node: `corexy_preview.test.cjs` · `twin_motion.test.cjs` · `twin_real_mode.test.cjs`

### 시연 흐름
`test_demo_failure.py` · `test_demo_gaps_g5_g10_g13.py` · `test_demo_v3_gaps.py` · `test_final_demo_flow.py`(오프라인 결선 리허설 전체 흐름)

### 문서·저장소·배포
`test_doc_links.py`(추적 md 상대 링크) · `test_repo_guard.py`(플랫폼 고유 명칭·문서·비밀 파일 공개 차단) · `test_eval64_documents.py` · `test_deploy_run_act.py` · `test_deploy_run_backend.py`

### 기타
`test_care_events.py` · `test_wellness_pause.py` · `test_board_probe.py` · `test_plots.py`

지원 파일: `conftest.py`, `fixtures/kma/`(기상청 응답 예시), `rpi4/tests/__init__.py`.
