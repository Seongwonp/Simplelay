#pragma once
// 줄 단위 JSON 규약(line-json/v0) — rpi/controller/serial_motion.py 머리말과
// rpi/tools/fake_mcu.py가 기준이다. 명령·필드·오류 코드 표: firmware-motion/protocol_table.json.
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
  int32_t z;
  const char* alarm;  // nullptr → null
};

// 받은 한 줄(개행 제외, NUL 종료)을 처리한다. 해석할 수 없는 줄은 fake_mcu처럼 무시한다.
void proto_handle_line(char* line, size_t len);

void proto_reply_ok(const ReqId& id);
void proto_reply_error(const ReqId& id, const char* code);
void proto_reply_status(const ReqId& id, const MotionSnapshot& snap);
void proto_event(const char* name);
void proto_event_alarm(const char* reason);
