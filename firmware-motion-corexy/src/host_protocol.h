#pragma once
// SimpleLay 줄 단위 JSON 규약(line-json/v0) — RPi4 rpi/controller/serial_motion.py와 rpi/tools/fake_mcu.py가 기준,
// 명령·필드·오류 코드 표는 firmware-motion/protocol_table.json. 해석·응답 형식은 firmware-motion/src/protocol.cpp를
// 옮겨 왔고(SimpleLay 작성), 명령 처리(cmd_*)는 main.cpp가 원작 모션 코어에 잇는다.
// **실물 미검증.**
#include <stddef.h>
#include <stdint.h>

// 요청 id. 정수가 아니거나 없으면 present=false이고 응답에 "id":null로 나간다.
struct ReqId {
  bool present;
  int32_t value;
};

struct MotionSnapshot {
  const char* state;  // "idle" | "homing" | "moving" | "pressing" | "stopped" | "alarm"
  bool homed;
  int32_t a;
  int32_t b;
  int32_t z;          // 솔레노이드: 켜짐 1 / 꺼짐 0
  const char* alarm;  // nullptr → null
};

// 받은 한 줄(개행 제외, NUL 종료)을 처리한다. JSON 객체가 아닌 줄은 무시한다(fake_mcu와 같다).
// JSON이 아니면 false를 돌려 bring-up 빌드가 사람용 줄로 넘길 수 있게 한다.
bool proto_handle_line(char* line, size_t len);

// main.cpp가 구현한다(loop 태스크에서만 불린다).
void cmd_status(const ReqId& id);
void cmd_limits(const ReqId& id);
void cmd_home(const ReqId& id);
void cmd_move(const ReqId& id, int32_t a, int32_t b, bool has_xy, float x_mm, float y_mm);
void cmd_press(const ReqId& id, bool depth, bool switchbot, int32_t amount, int32_t dwell_ms);
void cmd_stop(const ReqId& id);

void proto_reply_ok(const ReqId& id);
void proto_reply_error(const ReqId& id, const char* code);
void proto_reply_error_retry(const ReqId& id, const char* code, uint32_t retry_ms);
void proto_reply_press_error(const ReqId& id, const char* code, const char* outcome);
void proto_reply_status(const ReqId& id, const MotionSnapshot& snap);
void proto_reply_limits(const ReqId& id, const bool raw[3], const bool deb[3]);
void proto_event(const char* name);
void proto_event_alarm(const char* reason, const char* z_retract);
void proto_event_ready(const char* fw, const char* reset_reason);
void proto_event_position(int32_t a, int32_t b, int32_t z);
