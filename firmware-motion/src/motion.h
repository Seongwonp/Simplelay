#pragma once
// 모션 상태기계: 원점 복귀·XY 이동·Z 누름·정지·알람·워치독, 축별 위치 PID.
// 명령은 받자마자 반환하고(비차단), 완료·실패 응답은 motion_tick이 나중에 보낸다.
#include <stdint.h>

#include "protocol.h"

void motion_init(bool hw_ok);
// 제어 주기(CONTROL_PERIOD_US)마다 호출. 동적 할당 없음.
void motion_tick(uint32_t now_ms);
// 호스트에서 완전한 한 줄을 받을 때마다 호출(워치독 갱신).
void motion_note_host_line(uint32_t now_ms);

void motion_cmd_status(const ReqId& id);
void motion_cmd_home(const ReqId& id);
void motion_cmd_move(const ReqId& id, int32_t a, int32_t b, bool has_xy, float x_mm, float y_mm);
// depth=true: z_counts까지(카운트), false: drive_ms 동안 구동(시간).
void motion_cmd_press(const ReqId& id, bool depth, int32_t amount, int32_t dwell_ms);
void motion_cmd_stop(const ReqId& id);
