#include "protocol.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <stdio.h>
#include <string.h>

#include "config.h"
#include "outlet.h"

namespace {

// ArduinoJson용 고정 풀 할당기 — 힙을 쓰지 않는다. 줄마다 reset()으로 비운다(firmware-motion과 같은 방식).
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
    if (new_size <= old_size) return ptr;
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
char g_out[256];
char g_id[16];
volatile uint32_t g_report_hz = REPORT_HZ_DEFAULT;

void write_line(const char* s) {
  Serial.write(reinterpret_cast<const uint8_t*>(s), strlen(s));
  Serial.write('\n');
}

// 요청 id(정수가 아니거나 없으면 null).
const char* id_text(JsonVariantConst v) {
  if (v.is<int32_t>()) {
    snprintf(g_id, sizeof(g_id), "%ld", static_cast<long>(v.as<int32_t>()));
  } else {
    snprintf(g_id, sizeof(g_id), "null");
  }
  return g_id;
}

void reply_ok(const char* id) {
  snprintf(g_out, sizeof(g_out), "{\"id\":%s,\"ok\":true}", id);
  write_line(g_out);
}

void reply_error(const char* id, const char* code) {
  snprintf(g_out, sizeof(g_out), "{\"id\":%s,\"ok\":false,\"error\":\"%s\"}", id, code);
  write_line(g_out);
}

void reply_status(const char* id) {
  const OutletSnapshot s = outlet_snapshot();
  snprintf(g_out, sizeof(g_out),
           "{\"id\":%s,\"ok\":true,\"relay\":\"%s\",\"estop\":%s,\"button\":%s,\"rate_hz\":%lu,"
           "\"ct\":\"%s\",\"cal\":\"%s\",\"uptime_ms\":%lu}",
           id, s.relay_on ? "on" : "off", s.estop_latched ? "true" : "false",
           s.button_active ? "true" : "false", static_cast<unsigned long>(g_report_hz), ct_source_name(),
           OUTLET_CONFIG_PLACEHOLDER ? "placeholder" : "set", static_cast<unsigned long>(millis()));
  write_line(g_out);
}

}  // namespace

uint32_t proto_report_hz() { return g_report_hz; }

void proto_handle_line(char* line, size_t len) {
  g_pool.reset();
  JsonDocument doc(&g_pool);
  if (deserializeJson(doc, line, len)) return;
  if (!doc.is<JsonObject>()) return;
  const char* id = id_text(doc["id"]);
  const char* cmd = doc["cmd"].is<const char*>() ? doc["cmd"].as<const char*>() : nullptr;
  if (cmd == nullptr) {
    reply_error(id, "unknown_cmd");
    return;
  }
  // 릴레이 끄기는 id가 없거나 이상해도 먼저 수행한다(정지 쪽 명령).
  if (strcmp(cmd, "relay_off") == 0) {
    outlet_relay_off();
    reply_ok(id);
  } else if (strcmp(cmd, "relay_on") == 0) {
    const char* err = outlet_relay_on();
    if (err != nullptr) {
      reply_error(id, err);
    } else {
      reply_ok(id);
    }
  } else if (strcmp(cmd, "estop_reset") == 0) {
    const char* err = outlet_estop_reset();
    if (err != nullptr) {
      reply_error(id, err);
    } else {
      reply_ok(id);
    }
  } else if (strcmp(cmd, "status") == 0) {
    reply_status(id);
  } else if (strcmp(cmd, "ping") == 0) {
    reply_ok(id);
  } else if (strcmp(cmd, "rate") == 0) {
    JsonVariantConst hz = doc["hz"];
    if (!hz.is<int32_t>()) {
      reply_error(id, "bad_args");
      return;
    }
    const int32_t v = hz.as<int32_t>();
    // 창 길이가 정수 샘플이어야 한다(SAMPLE_HZ % hz == 0).
    if (v < REPORT_HZ_MIN || v > REPORT_HZ_MAX || (SAMPLE_HZ % v) != 0) {
      reply_error(id, "bad_args");
      return;
    }
    g_report_hz = static_cast<uint32_t>(v);
    reply_ok(id);
  } else {
    reply_error(id, "unknown_cmd");
  }
}

void proto_event_ready(const char* reset_reason, bool ct_ok) {
  snprintf(g_out, sizeof(g_out),
           "{\"event\":\"ready\",\"fw\":\"%s\",\"protocol\":\"%s\",\"reset\":\"%s\",\"relay\":\"off\","
           "\"ct\":\"%s\",\"ct_ok\":%s}",
           FW_NAME, FW_PROTOCOL, reset_reason, ct_source_name(), ct_ok ? "true" : "false");
  write_line(g_out);
}

void proto_event_power(const PowerReport& r, bool relay_on) {
  // vrms_est: 측정값이 아니라 설정 상수(MAINS_VRMS_EST)다 — 이름에 est를 단 이유.
  snprintf(g_out, sizeof(g_out),
           "{\"event\":\"power\",\"t_ms\":%lu,\"seq\":%lu,\"watts\":%.1f,\"irms_a\":%.3f,\"vrms_est\":%.1f,"
           "\"ct_mv\":%.2f,\"n\":%lu,\"err\":%lu,\"relay\":\"%s\"}",
           static_cast<unsigned long>(r.t_ms), static_cast<unsigned long>(r.seq), r.watts, r.irms_a,
           static_cast<double>(MAINS_VRMS_EST), r.ct_mv_rms, static_cast<unsigned long>(r.n),
           static_cast<unsigned long>(r.read_errors), relay_on ? "on" : "off");
  write_line(g_out);
}

void proto_event_estop(uint32_t t_ms) {
  snprintf(g_out, sizeof(g_out), "{\"event\":\"estop\",\"source\":\"button\",\"t_ms\":%lu,\"relay\":\"off\"}",
           static_cast<unsigned long>(t_ms));
  write_line(g_out);
}

void proto_event_fault(const char* reason) {
  snprintf(g_out, sizeof(g_out), "{\"event\":\"fault\",\"reason\":\"%s\"}", reason);
  write_line(g_out);
}

void proto_event_host_timeout() {
  snprintf(g_out, sizeof(g_out), "{\"event\":\"host_timeout\",\"relay\":\"off\"}");
  write_line(g_out);
}
