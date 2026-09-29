#pragma once
// 모션 상태기계: 원점 복귀·XY 이동·Z 누름·정지·알람·워치독, 축별 위치 PID.
// 명령은 받자마자 반환하고(비차단), 완료·실패 응답은 motion_tick이 나중에 보낸다.
//
// 동시성(2026-09-29): motion_tick은 제어 태스크(CONTROL_HZ, main.cpp)에서, motion_cmd_*는 loop
// 태스크(시리얼 해석)에서 불린다. 둘 다 **motion_lock을 잡은 채로만** 부른다(MotionGuard). 시리얼
// 쓰기(proto_*)도 같은 잠금 안에서만 일어나 줄이 섞이지 않는다.
#include <stdint.h>

#include "protocol.h"

void motion_init(bool hw_ok);
// 제어 주기(CONTROL_PERIOD_US)마다 제어 태스크가 잠금을 잡고 호출. 동적 할당 없음.
void motion_tick(uint32_t now_ms);
// 호스트에서 완전한 한 줄을 받을 때마다 호출(워치독 갱신). 잠금 없이 불러도 된다(32비트 한 번 쓰기).
void motion_note_host_line(uint32_t now_ms);

void motion_lock();
void motion_unlock();

struct MotionGuard {
  MotionGuard() { motion_lock(); }
  ~MotionGuard() { motion_unlock(); }
  MotionGuard(const MotionGuard&) = delete;
  MotionGuard& operator=(const MotionGuard&) = delete;
};

void motion_cmd_status(const ReqId& id);
void motion_cmd_home(const ReqId& id);
void motion_cmd_move(const ReqId& id, int32_t a, int32_t b, bool has_xy, float x_mm, float y_mm);
// depth=true: z_counts까지(카운트), false: drive_ms 동안 구동(시간).
void motion_cmd_press(const ReqId& id, bool depth, int32_t amount, int32_t dwell_ms);
void motion_cmd_stop(const ReqId& id);
// 리밋 입력 X·Y·Z의 즉시값·디바운스 값. 상태를 바꾸지 않고 동작 중에도 바로 답한다.
void motion_cmd_limits(const ReqId& id);
