#include "protocol.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <stdio.h>
#include <string.h>

#include "config.h"
#include "motion.h"

namespace {

// ArduinoJson용 고정 풀 할당기 — 힙을 쓰지 않는다. 줄마다 reset()으로 비운다.
// 블록 앞 8바이트에 크기를 적어 reallocate가 복사할 길이를 안다.
class PoolAllocator : public ArduinoJson::Allocator {
 public:
  void reset() { used_ = 0; }

  void* allocate(size_t size) override {
    const size_t total = kHeader + align(size);
    if (used_ + total > sizeof(buf_)) return nullptr;
    uint8_t* block = buf_ + used_;
    memcpy(block, &size, sizeof(size));
    used_ += total;
    return block + kHeader;
  }

  void deallocate(void*) override {}

  void* reallocate(void* ptr, size_t new_size) override {
    if (ptr == nullptr) return allocate(new_size);
    uint8_t* block = static_cast<uint8_t*>(ptr) - kHeader;
    size_t old_size = 0;
    memcpy(&old_size, block, sizeof(old_size));
    if (new_size <= old_size) return ptr;  // 줄이기는 제자리
    // 마지막 블록이면 제자리에서 늘린다.
    if (block + kHeader + align(old_size) == buf_ + used_) {
      const size_t grow = align(new_size) - align(old_size);
      if (used_ + grow > sizeof(buf_)) return nullptr;
      used_ += grow;
      memcpy(block, &new_size, sizeof(new_size));
      return ptr;
    }
    void* fresh = allocate(new_size);
    if (fresh == nullptr) return nullptr;
    memcpy(fresh, ptr, old_size);
    return fresh;
  }

 private:
  static constexpr size_t kHeader = 8;
  static size_t align(size_t n) { return (n + 7u) & ~static_cast<size_t>(7u); }
  alignas(8) uint8_t buf_[JSON_POOL_BYTES];
  size_t used_ = 0;
};

PoolAllocator g_pool;
char g_out[192];

void write_line(const char* s) {
  Serial.write(reinterpret_cast<const uint8_t*>(s), strlen(s));
  Serial.write('\n');
}

void format_id(char* buf, size_t n, const ReqId& id) {
  if (id.present) {
    snprintf(buf, n, "%ld", static_cast<long>(id.value));
  } else {
    snprintf(buf, n, "null");
  }
}

bool read_int(JsonVariantConst v, int32_t* out) {
  if (!v.is<int32_t>()) return false;
  *out = v.as<int32_t>();
  return true;
}

void handle_move(const ReqId& id, JsonDocument& doc) {
  int32_t a = 0;
  int32_t b = 0;
  if (!read_int(doc["a"], &a) || !read_int(doc["b"], &b)) {
    proto_reply_error(id, "bad_args");
    return;
  }
  JsonVariantConst xv = doc["x_mm"];
  JsonVariantConst yv = doc["y_mm"];
  const bool has_x = !xv.isNull();
  const bool has_y = !yv.isNull();
  if (has_x != has_y || (has_x && (!xv.is<float>() || !yv.is<float>()))) {
    proto_reply_error(id, "bad_args");
    return;
  }
  motion_cmd_move(id, a, b, has_x, has_x ? xv.as<float>() : 0.0f, has_y ? yv.as<float>() : 0.0f);
}

void handle_press(const ReqId& id, JsonDocument& doc) {
  const char* mode = doc["mode"].is<const char*>() ? doc["mode"].as<const char*>() : nullptr;
  int32_t dwell_ms = 0;
  if (mode == nullptr || !read_int(doc["dwell_ms"], &dwell_ms) || dwell_ms < 0) {
    proto_reply_error(id, "bad_args");
    return;
  }
  int32_t amount = 0;
  if (strcmp(mode, "depth") == 0) {
    if (!read_int(doc["z_counts"], &amount) || amount <= 0) {
      proto_reply_error(id, "bad_args");
      return;
    }
    motion_cmd_press(id, true, amount, dwell_ms);
  } else if (strcmp(mode, "duration") == 0) {
    if (!read_int(doc["drive_ms"], &amount) || amount <= 0) {
      proto_reply_error(id, "bad_args");
      return;
    }
    motion_cmd_press(id, false, amount, dwell_ms);
  } else {
    proto_reply_error(id, "bad_args");
  }
}

}  // namespace

void proto_handle_line(char* line, size_t len) {
  g_pool.reset();
  JsonDocument doc(&g_pool);
  if (deserializeJson(doc, line, len)) return;  // 해석 불가 줄은 무시(fake_mcu와 같다)
  if (!doc.is<JsonObject>()) return;

  ReqId id = {false, 0};
  int32_t idv = 0;
  if (read_int(doc["id"], &idv)) {
    id.present = true;
    id.value = idv;
  }
  const char* cmd = doc["cmd"].is<const char*>() ? doc["cmd"].as<const char*>() : nullptr;
  if (cmd == nullptr) {
    proto_reply_error(id, "unknown_cmd");
    return;
  }

  // 정지는 id가 없거나 이상해도 먼저 수행한다.
  if (strcmp(cmd, "stop") == 0) {
    motion_cmd_stop(id);
    return;
  }
  if (strcmp(cmd, "status") == 0) {
    motion_cmd_status(id);
    return;
  }
  // heartbeat: 진행 중 동작을 건드리지 않고 바로 답한다. 워치독은 줄을 받을 때 이미 갱신됐다.
  if (strcmp(cmd, "ping") == 0) {
    proto_reply_ok(id);
    return;
  }
  if (strcmp(cmd, "limits") == 0) {
    motion_cmd_limits(id);
    return;
  }

  const bool known = strcmp(cmd, "home") == 0 || strcmp(cmd, "move") == 0 || strcmp(cmd, "press") == 0;
  if (!known) {
    proto_reply_error(id, "unknown_cmd");
    return;
  }
  // 움직이는 명령은 응답을 짝지을 id가 있어야 받는다.
  if (!id.present) {
    proto_reply_error(id, "bad_args");
    return;
  }
  if (strcmp(cmd, "home") == 0) {
    motion_cmd_home(id);
  } else if (strcmp(cmd, "move") == 0) {
    handle_move(id, doc);
  } else {
    handle_press(id, doc);
  }
}

void proto_reply_ok(const ReqId& id) {
  char idb[16];
  format_id(idb, sizeof idb, id);
  snprintf(g_out, sizeof g_out, "{\"id\":%s,\"ok\":true}", idb);
  write_line(g_out);
}

void proto_reply_error(const ReqId& id, const char* code) {
  char idb[16];
  format_id(idb, sizeof idb, id);
  snprintf(g_out, sizeof g_out, "{\"id\":%s,\"ok\":false,\"error\":\"%s\"}", idb, code);
  write_line(g_out);
}

void proto_reply_status(const ReqId& id, const MotionSnapshot& s) {
  char idb[16];
  format_id(idb, sizeof idb, id);
  char alarm[40];
  if (s.alarm != nullptr) {
    snprintf(alarm, sizeof alarm, "\"%s\"", s.alarm);
  } else {
    snprintf(alarm, sizeof alarm, "null");
  }
  snprintf(g_out, sizeof g_out,
           "{\"id\":%s,\"ok\":true,\"state\":\"%s\",\"homed\":%s,\"a\":%ld,\"b\":%ld,\"z\":%ld,\"alarm\":%s}",
           idb, s.state, s.homed ? "true" : "false", static_cast<long>(s.a), static_cast<long>(s.b),
           static_cast<long>(s.z), alarm);
  write_line(g_out);
}

void proto_reply_limits(const ReqId& id, const bool raw[3], const bool deb[3]) {
  char idb[16];
  format_id(idb, sizeof idb, id);
  auto tf = [](bool v) { return v ? "true" : "false"; };
  snprintf(g_out, sizeof g_out,
           "{\"id\":%s,\"ok\":true,\"raw\":{\"x\":%s,\"y\":%s,\"z\":%s},"
           "\"debounced\":{\"x\":%s,\"y\":%s,\"z\":%s}}",
           idb, tf(raw[0]), tf(raw[1]), tf(raw[2]), tf(deb[0]), tf(deb[1]), tf(deb[2]));
  write_line(g_out);
}

void proto_event(const char* name) {
  snprintf(g_out, sizeof g_out, "{\"event\":\"%s\"}", name);
  write_line(g_out);
}

void proto_event_position(int32_t a, int32_t b, int32_t z) {
  snprintf(g_out, sizeof g_out, "{\"event\":\"position\",\"a\":%ld,\"b\":%ld,\"z\":%ld}",
           static_cast<long>(a), static_cast<long>(b), static_cast<long>(z));
  write_line(g_out);
}

void proto_event_alarm(const char* reason) {
  snprintf(g_out, sizeof g_out, "{\"event\":\"alarm\",\"reason\":\"%s\"}", reason);
  write_line(g_out);
}
