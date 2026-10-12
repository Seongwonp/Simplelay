// 원작: 팀원(서예솔) Touch Bridge CoreXY 펌웨어 v3, SimpleLay용으로 통신·이름 수정
// =====================================================================
//  SimpleLay 모션 MCU 펌웨어 — CoreXY XY + 솔레노이드 누름 (ESP32). **컴파일만 확인, 실물 미검증.**
//  모터: DFRobot FIT0482 (6V, 50:1, 홀 엔코더) x2
//  드라이버: JMOD-MOTOR-1 (TB6612FNG)
//  누름: SparkFun ROB-11015 솔레노이드 5V (N-MOSFET 로우사이드 + 플라이백 다이오드)
//
//  ── 연결 ────────────────────────────────────────────────────────────
//  RPi4(rpi/controller/serial_motion.py) ─USB 시리얼 115200, 줄 단위 JSON(line-json/v0)─ 이 보드.
//  무선(BLE)은 쓰지 않는다 — 시연 링크는 유선 하나다(정지 명령 신뢰성).
//  규약 기준: rpi/tools/fake_mcu.py, 명령 표: firmware-motion/protocol_table.json.
//
//  ── 원작에서 그대로 둔 것 ───────────────────────────────────────────
//  - 제어 핵심 include/CoreXYMotion.h·QuadEncoder.h·Tb6612Motor.h(PID·기구학·사다리꼴 궤적·스톨 원점 복귀·
//    추종 오차·정착 실패 감시). 바꾼 곳은 CoreXYMotion.h 머리말에 적었다(STBY 켜고 끄기·원점 기준 버리기).
//  - 1kHz 제어 태스크, 모션 이벤트 큐, 솔레노이드 구동(100% 당김 → 약 35% 유지, 강제 해제 백스톱),
//    "모든 물리 동작은 하나의 큐에서 순서대로, 실패·정지가 오면 남은 큐를 버림"(단일 동작 큐·pump).
//
//  ── 원작에서 뺀 것 ──────────────────────────────────────────────────
//  - BLE 서버·앱 특성(FFE0/FFE1)·Nordic UART, 앱 JSON v2(commandId·positionToken·상태 notify),
//    challenge/auth/provision(HMAC 세션·페어링 키 저장)·KEYRESET, BLE 이름.
//  - GRBL 호환 G-code(G0/G1/G4/G90/G91/G92/$H/$$), SET_GRID·BTN_n, set_servo/get_servo.
//  - '!' 한 글자 즉시 정지(JSON 줄 안의 글자와 섞일 수 있다 — 정지는 {"cmd":"stop"}).
//  - 사람용 텍스트 명령(G/GT/T/H/S/Z/P/M/K)은 기본 빌드에서 뺐다. 방향 시험용으로
//    -DBRINGUP_TEXT_COMMANDS=1 빌드(env esp32dev_bringup)에만 남는다 — 그 빌드는 ready 배너 fw가 다르다.
//
//  ── SimpleLay에서 더한 것 ───────────────────────────────────────────
//  - 부팅 배너 {"event":"ready",...}, status/home/move/press/stop/ping/limits, ok/error 응답, 거절 코드
//    (busy·alarm·not_homed·soft_limit·bad_args·z_unsupported·z_cooldown·hw_init), 알람 이벤트를 먼저 보내고
//    대기 명령 실패를 나중에, 위치 보고(position), 호스트 워치독(host_timeout), 명령 기한(timeout),
//    솔레노이드 켜짐 상한·냉각, MCU 태스크 워치독, 정지·알람 뒤 원점 기준 버리기.
// =====================================================================
#include <Arduino.h>
#include <esp_arduino_version.h>
#include <esp_system.h>
#include <esp_task_wdt.h>
#include <math.h>
#include <string.h>

#include "CoreXYMotion.h"
#include "config.h"
#include "host_protocol.h"

#ifndef BRINGUP_TEXT_COMMANDS
#define BRINGUP_TEXT_COMMANDS 0
#endif

#if BRINGUP_TEXT_COMMANDS
#define FW_NAME FW_NAME_BASE "-bringup"
#warning "BRINGUP_TEXT_COMMANDS=1: 사람용 방향 시험 명령(M·Z 등)이 켜진 빌드 — 시연·RPi4 연결용으로 올리지 않는다"
#else
#define FW_NAME FW_NAME_BASE
#endif

// ---------------- 공용 타입 ----------------
// SimpleLay 수정: 원작의 응답 형식 구분(TEXT/GCODE/JSON)·commandId 대신 호스트 요청 id(ReqId)를 싣는다.
enum Origin : uint8_t { ORG_HOST, ORG_BRINGUP };
enum class StepType : uint8_t { MOVE, HOME, TAP, SET_ORIGIN };

struct Step {
  StepType type;
  Origin org;
  float x, y, f;  // MOVE
  uint32_t ms;    // TAP (켜짐 시간 = drive_ms + dwell_ms)
  ReqId id;       // 호스트 요청 id
};

enum class Phase : uint8_t { WAIT_RELEASE, WAIT_MOTION, TAP_HOLD, TAP_RELEASE };

CoreXYMotion motion;
QueueHandle_t motionEvents;

void raiseAlarm(const char* reason, bool stopMotion);

// =====================================================================
//  솔레노이드 (원작)
// =====================================================================
// config.h에서 이미 쓰는 핀: 4(STBY) 25/26/27(모터A) 32/33/13(모터B)
//   16/17(엔코더A) 18/19(엔코더B), 21/22(리밋, 선택). 남는 출력 핀 중 부팅 영향 없는 23을 사용.
//   피해야 할 핀: 6~11(플래시), 34~39(입력 전용), 0/2/5/12/15(부팅 스트래핑)
//   **게이트 외부 풀다운 필요**: 리셋·패닉·재부팅 중 GPIO는 High-Z라 게이트가 뜨면 코일이 켜질 수 있다.
#ifndef SOLENOID_PIN
#define SOLENOID_PIN 23
#endif
#ifndef SOLENOID_LEDC_CH  // 2.x·3.x 모두 이 채널로 고정(모터 0/1과 다른 타이머)
#define SOLENOID_LEDC_CH 7  // 모터가 0/1 채널을 쓰므로 다른 타이머의 7번
#endif
static_assert(gpioOutputOk(SOLENOID_PIN), "솔레노이드 게이트 핀이 ESP32에 없거나 스트래핑·입력 전용 핀이다");

constexpr uint32_t SOL_PWM_FREQ  = 20000;  // 20kHz (가청 소음 없음)
constexpr uint8_t  SOL_PWM_BITS  = 8;
constexpr uint32_t SOL_HIT_MS    = 60;     // 처음엔 100%로 당기고 (실측 필요)
constexpr uint8_t  SOL_HOLD_DUTY = 90;     // 이후 약 35%로 유지 (발열 감소, 실측 필요)
// SimpleLay 수정: 원작 3000 ms. 이제 솔레노이드는 누름(TAP) 안에서만 켜지므로 요청 상한 + 여유로 줄였다.
constexpr uint32_t SOL_MAX_ON_MS = SOLENOID_ON_MAX_MS + SOL_BACKSTOP_GRACE_MS;  // 이보다 오래 켜져 있으면 강제 해제
constexpr uint32_t SOL_SETTLE_MS = 60;     // 플런저가 끝까지 나가거나 돌아오는 시간 (실측 필요)

volatile bool solOn = false;
bool solHolding = false;
uint32_t solOnAt = 0;
// SimpleLay 추가: 코일 발열 보호(끈 뒤 최소 꺼짐 시간)
uint32_t solOffAt = 0;
uint32_t solCooldownMs = 0;

static void solWrite(uint32_t duty) {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(SOLENOID_PIN, duty);
#else
  ledcWrite(SOLENOID_LEDC_CH, duty);
#endif
}

bool g_solPwmOk = false;  // SimpleLay 추가: 솔레노이드 PWM 채널이 붙었는가

void solBegin() {
  pinMode(SOLENOID_PIN, OUTPUT);
  digitalWrite(SOLENOID_PIN, LOW);
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  // SimpleLay 수정(2026-10-12): 자동 배정 대신 채널 고정 — 모터 PWM 타이머와 겹치지 않게.
  g_solPwmOk = ledcAttachChannel(SOLENOID_PIN, SOL_PWM_FREQ, SOL_PWM_BITS, SOLENOID_LEDC_CH);
#else
  g_solPwmOk = true;
  ledcSetup(SOLENOID_LEDC_CH, SOL_PWM_FREQ, SOL_PWM_BITS);
  ledcAttachPin(SOLENOID_PIN, SOLENOID_LEDC_CH);
#endif
  solWrite(0);
}

void solenoidOn() {
  solWrite((1u << SOL_PWM_BITS) - 1);
  solOnAt = millis();
  solHolding = false;
  solOn = true;
}

void solenoidOff() {
  const bool wasOn = solOn;
  solWrite(0);
  solOn = false;
  solHolding = false;
  if (wasOn) {  // SimpleLay 추가: 냉각 = max(SOLENOID_MIN_OFF_MS, 켜짐 × SOLENOID_OFF_RATIO)
    const uint32_t now = millis();
    const uint32_t byRatio = (now - solOnAt) * SOLENOID_OFF_RATIO;
    solOffAt = now;
    solCooldownMs = byRatio > SOLENOID_MIN_OFF_MS ? byRatio : SOLENOID_MIN_OFF_MS;
  }
}

// SimpleLay 추가
bool solCooling() {
  return solCooldownMs > 0 && static_cast<int32_t>(millis() - solOffAt) < static_cast<int32_t>(solCooldownMs);
}
uint32_t solCooldownLeftMs() { return solCooling() ? solCooldownMs - (millis() - solOffAt) : 0; }

// ---------------- 1kHz 제어 태스크 (원작 + 태스크 워치독) ----------------
void controlTask(void*) {
  esp_task_wdt_add(nullptr);  // SimpleLay 추가: 제어가 멎으면 패닉 → 재부팅(STBY 외부 풀다운이 출력을 꺼 둔다)
  TickType_t last = xTaskGetTickCount();
  const TickType_t period = 1;
  int64_t prev = esp_timer_get_time();
  for (;;) {
    vTaskDelayUntil(&last, period);
    int64_t now = esp_timer_get_time();
    float dt = (now - prev) * 1e-6f;
    prev = now;
    dt = constrain(dt, 0.0005f, 0.005f);
    motion.controlStep(dt);
    esp_task_wdt_reset();
  }
}

// =====================================================================
//  동작 큐 (원작 — 단일 큐. SimpleLay에서는 호스트가 한 번에 하나만 보내고 바쁘면 busy로 거절한다)
// =====================================================================
constexpr int QMAX = 4;  // SimpleLay 수정: 원작 32(G-code 여러 줄을 쌓던 크기)
Step q[QMAX];
int qHead = 0, qCount = 0;

bool qPush(const Step& s) {
  if (qCount >= QMAX) return false;
  q[(qHead + qCount) % QMAX] = s;
  qCount++;
  return true;
}
bool qPop(Step& s) {
  if (!qCount) return false;
  s = q[qHead];
  qHead = (qHead + 1) % QMAX;
  qCount--;
  return true;
}
void qClear() { qHead = qCount = 0; }

bool active = false;
Step cur;
Phase phase;
uint32_t phaseAt = 0, phaseMs = 0;

bool busy() { return active || qCount > 0; }

// =====================================================================
//  SimpleLay 규약 상태
// =====================================================================
const char* g_alarm = nullptr;    // 알람 이유. home으로만 지운다
bool g_stopped = false;           // stop 뒤 다음 명령 전까지 state="stopped"
bool g_hwOk = true;
uint32_t g_lastHostMs = 0;        // 마지막으로 받은 줄(무엇이든) — 호스트 워치독
bool g_releasePending = false;    // 브레이크 유지 뒤 STBY LOW 예약
uint32_t g_releaseAt = 0;
uint32_t g_cmdStart = 0, g_cmdMaxMs = 0;
uint32_t g_lastPosEvent = 0;
// 원작 positionToken의 뜻(이동이 끝난 자리에서만 누름)을 옮긴 것: 마지막으로 확인된 목표 위치.
bool g_posRefValid = false;
float g_refX = 0, g_refY = 0;
// 리밋(USE_LIMIT_SWITCHES일 때만): X·Y 디바운스
bool g_limitDeb[2] = {false, false};
uint8_t g_limitCnt[2] = {0, 0};

Step makeStep(StepType t, Origin o) {
  Step s{};
  s.type = t;
  s.org = o;
  s.id = ReqId{false, 0};
  return s;
}

void scheduleRelease(uint32_t ms) {
  g_releasePending = true;
  g_releaseAt = millis() + ms;
}

void beginDeadline(uint32_t maxMs) {
  g_cmdStart = millis();
  g_cmdMaxMs = maxMs;
}

void emitPosition() {
  g_lastPosEvent = millis();
  auto st = motion.status();
  proto_event_position(st.countA, st.countB, solOn ? 1 : 0);
}

bool limitRaw(int i) {
  if (!USE_LIMIT_SWITCHES) return false;
  return digitalRead(i == 0 ? PIN_LIMIT_X : PIN_LIMIT_Y) == LOW;  // NO 스위치 → GND = 눌림
}

void sampleLimits() {
  for (int i = 0; i < 2; i++) {
    const bool raw = limitRaw(i);
    if (raw == g_limitDeb[i]) {
      g_limitCnt[i] = 0;
    } else if (++g_limitCnt[i] >= LIMIT_DEBOUNCE_SAMPLES) {
      g_limitDeb[i] = raw;
      g_limitCnt[i] = 0;
    }
  }
}

// 현재 동작의 성공 응답
void replyCurOk(const char* text) {
  if (cur.org == ORG_HOST) proto_reply_ok(cur.id);
#if BRINGUP_TEXT_COMMANDS
  else Serial.println(text);
#else
  (void)text;
#endif
}

// 움직이기 전 거절(원작 motion.moveTo/home의 거부 사유 → 규약 코드)
void refuseCur(const char* code) {
  if (cur.org == ORG_HOST) proto_reply_error(cur.id, code);
#if BRINGUP_TEXT_COMMANDS
  else Serial.printf("ERR %s\n", code);
#endif
  qClear();
  active = false;
}

const char* mapCoreRefusal(const char* err) {
  if (!strcmp(err, "NOT_HOMED")) return "not_homed";
  if (!strcmp(err, "OUT_OF_RANGE")) return "soft_limit";
  return "busy";
}

void endActive() { active = false; }

// 알람: 출력을 멈추고, 알람 이벤트를 **먼저**, 대기 중 명령의 실패 응답을 **나중에** 보낸다
// (호스트 serial_motion.py는 이벤트를 받는 즉시 그 요청을 실패로 끝낸다 — 순서가 반대면 늦은 이벤트가
// 다음 요청, 예컨대 복구용 home을 실패시킨다). 원작의 failActive(남은 큐 전부 버림·솔레노이드 끔)를 이었다.
void raiseAlarm(const char* reason, bool stopMotion) {
  const bool wasOn = solOn;
  solenoidOff();                 // 솔레노이드는 끄는 것이 후퇴다(스프링 복귀)
  if (stopMotion) motion.stop();  // 원작 코어가 낸 FAULT는 코어가 이미 브레이크했다
  qClear();
  motion.clearHomed();           // 원점 기준을 믿지 않는다 — home으로만 복구
  g_posRefValid = false;
  g_alarm = reason;
  g_stopped = false;
  proto_event_alarm(reason, wasOn ? "done" : "not_needed");
  if (active) {
    if (cur.org == ORG_HOST) proto_reply_error(cur.id, reason);
#if BRINGUP_TEXT_COMMANDS
    else Serial.printf("FAULT %s\n", reason);
#endif
  }
  active = false;
  scheduleRelease(FAULT_BRAKE_MS);
}

// ---------------- 실행 (원작 startStep·pump) ----------------
void beginMove() {
  const char* err = motion.moveTo(cur.x, cur.y, cur.f);
  if (err) { refuseCur(mapCoreRefusal(err)); return; }
  phase = Phase::WAIT_MOTION;
  beginDeadline(MOVE_MAX_MS);
}

void startStep() {
  active = true;
  switch (cur.type) {
    case StepType::MOVE:
      if (solOn) {  // 누른 채로 끌고 다니지 않도록 먼저 뗌
        solenoidOff();
        phase = Phase::WAIT_RELEASE;
        phaseAt = millis();
        beginDeadline(MOVE_MAX_MS);
      } else {
        beginMove();
      }
      break;
    case StepType::HOME: {
      solenoidOff();
      const char* err = motion.home();
      if (err) { refuseCur(mapCoreRefusal(err)); return; }
      phase = Phase::WAIT_MOTION;
      beginDeadline(HOME_MAX_MS);
      break;
    }
    case StepType::SET_ORIGIN:  // bring-up 빌드 전용(Z 명령)
      motion.setOrigin();
      g_posRefValid = true;
      g_refX = g_refY = 0;
      replyCurOk("OK origin");
      endActive();
      break;
    case StepType::TAP:
      motion.hold();  // 워치독이 출력을 내렸다면 현재 위치를 다시 잡고 누른다
      proto_event("press_start");
      solenoidOn();
      phase = Phase::TAP_HOLD;
      phaseAt = millis();
      phaseMs = cur.ms;
      beginDeadline(cur.ms + SOL_SETTLE_MS + PRESS_TIMEOUT_MARGIN_MS);
      break;
  }
}

void pump() {
  if (!active) {
    if (qPop(cur)) startStep();
    return;
  }
  const uint32_t t = millis() - phaseAt;
  switch (phase) {
    case Phase::WAIT_RELEASE:
      if (t >= SOL_SETTLE_MS) beginMove();
      break;
    case Phase::TAP_HOLD:
      if (t >= phaseMs) {
        solenoidOff();
        proto_event("press_end");
        phase = Phase::TAP_RELEASE;
        phaseAt = millis();
      }
      break;
    case Phase::TAP_RELEASE:
      // 스프링이 플런저를 되돌릴 시간을 둔 뒤 완료 — 그 전에 XY가 움직이면 버튼을 긁는다.
      if (t >= SOL_SETTLE_MS) {
        emitPosition();  // 위치를 ok보다 먼저(호스트는 이벤트를 먼저 처리한다)
        replyCurOk("PRESSED");
        endActive();
      }
      break;
    case Phase::WAIT_MOTION:
      break;  // 모션 이벤트에서 처리
  }
}

void solService() {
  if (!solOn) return;
  uint32_t t = millis() - solOnAt;
  if (!solHolding && t >= SOL_HIT_MS) {
    solWrite(SOL_HOLD_DUTY);
    solHolding = true;
  }
  if (t >= SOL_MAX_ON_MS) {  // 안전장치: 어떤 경로로 켜져 있든 끈다
    if (active && cur.type == StepType::TAP) {
      raiseAlarm("timeout", false);
    } else {
      solenoidOff();
    }
  }
}

// ---------------- 모션 이벤트 (원작 handleEvent → 규약 응답) ----------------
void handleEvent(MotionEvent e) {
  const bool waiting = active && phase == Phase::WAIT_MOTION;
  switch (e) {
    case MotionEvent::MOVE_DONE: {
      if (!waiting || cur.type != StepType::MOVE) return;  // 정지 직후 남은 이벤트 등
      auto st = motion.status();
      const float err = hypotf(st.x - cur.x, st.y - cur.y);
      if (err > PRESS_POS_TOL_MM) {  // 원작 ERROR_POSITION 검사
        raiseAlarm("stall", true);
        return;
      }
      g_posRefValid = true;
      g_refX = cur.x;
      g_refY = cur.y;
      emitPosition();
#if BRINGUP_TEXT_COMMANDS
      if (cur.org == ORG_BRINGUP) Serial.printf("DONE %.2f %.2f\n", st.x, st.y);
#endif
      if (cur.org == ORG_HOST) proto_reply_ok(cur.id);
      endActive();
      return;
    }
    case MotionEvent::HOME_DONE: {
      if (!waiting || cur.type != StepType::HOME) return;
      auto st = motion.status();
      g_posRefValid = true;
      g_refX = st.xRef;
      g_refY = st.yRef;
      replyCurOk("HOMED");
      endActive();
      return;
    }
    case MotionEvent::STOPPED:
      return;  // 정지는 cmd_stop·raiseAlarm이 이미 처리했다
    case MotionEvent::FAULT_FOLLOW: raiseAlarm("stall", false); return;          // 걸림·충돌·탈조
    case MotionEvent::FAULT_SETTLE: raiseAlarm("timeout", false); return;        // 도착 뒤 정착 실패
    case MotionEvent::FAULT_HOME:   raiseAlarm("home_not_found", false); return;
  }
}

void drainMotionEvents() {
  if (motionEvents == nullptr) return;
  MotionEvent e;
  while (xQueueReceive(motionEvents, &e, 0) == pdTRUE) handleEvent(e);
}

// ---------------- 호스트 워치독·명령 기한·리밋·위치 보고 (SimpleLay 추가) ----------------
void safetyService() {
  const uint32_t now = millis();
  sampleLimits();
  if (g_releasePending && static_cast<int32_t>(now - g_releaseAt) >= 0) {
    g_releasePending = false;
    if (!busy()) motion.release();  // 브레이크 유지 뒤 STBY LOW
  }
  const bool hostSilent = static_cast<int32_t>(now - g_lastHostMs) >= static_cast<int32_t>(HOST_WATCHDOG_MS);
  if (active) {
    if (cur.org == ORG_HOST && hostSilent) {
      raiseAlarm("host_timeout", true);
    } else if (static_cast<int32_t>(now - g_cmdStart) >= static_cast<int32_t>(g_cmdMaxMs)) {
      raiseAlarm("timeout", true);
    } else if ((cur.type == StepType::MOVE || cur.type == StepType::TAP) && (g_limitDeb[0] || g_limitDeb[1])) {
      raiseAlarm("limit", true);  // 원점 복귀 밖에서 리밋이 눌렸다
    }
  } else if (!busy() && hostSilent && motion.outputsOn()) {
    motion.release();  // 위치 유지 중 호스트가 조용하다 — 알람 없이 출력만 내린다
  }
}

void positionService() {
  if (!active) return;
  const bool moving = cur.type == StepType::MOVE && phase == Phase::WAIT_MOTION;
  const bool pressing = cur.type == StepType::TAP;
  if ((moving || pressing) &&
      static_cast<int32_t>(millis() - g_lastPosEvent) >= static_cast<int32_t>(POSITION_EVENT_MS)) {
    emitPosition();
  }
}

// =====================================================================
//  규약 명령 (host_protocol.cpp가 부른다)
// =====================================================================
const char* refusal() {
  if (busy()) return "busy";
  if (g_alarm != nullptr) return "alarm";
  if (!motion.status().homed) return "not_homed";
  return nullptr;
}

void cmd_status(const ReqId& id) {
  auto st = motion.status();
  MotionSnapshot s;
  if (g_alarm != nullptr) {
    s.state = "alarm";
  } else if (active && cur.type == StepType::HOME) {
    s.state = "homing";
  } else if (active && cur.type == StepType::TAP) {
    s.state = "pressing";
  } else if (active || st.state == MotionState::RAW) {
    s.state = "moving";
  } else if (g_stopped) {
    s.state = "stopped";
  } else {
    s.state = "idle";
  }
  s.homed = st.homed && g_alarm == nullptr;
  s.a = st.countA;
  s.b = st.countB;
  s.z = solOn ? 1 : 0;
  s.alarm = g_alarm;
  proto_reply_status(id, s);
}

void cmd_limits(const ReqId& id) {
  // z: 솔레노이드 방식이라 Z 리밋 입력이 없다 — 항상 false. 리밋 스위치를 안 쓰면 x·y도 false.
  const bool raw[3] = {limitRaw(0), limitRaw(1), false};
  const bool deb[3] = {g_limitDeb[0], g_limitDeb[1], false};
  proto_reply_limits(id, raw, deb);
}

void cmd_home(const ReqId& id) {
  if (busy()) { proto_reply_error(id, "busy"); return; }
  if (!g_hwOk) { proto_reply_error(id, "hw_init"); return; }
  Step s = makeStep(StepType::HOME, ORG_HOST);
  s.id = id;
  if (!qPush(s)) { proto_reply_error(id, "busy"); return; }
  g_alarm = nullptr;
  g_stopped = false;
  g_releasePending = false;
  g_posRefValid = false;
}

void cmd_move(const ReqId& id, int32_t a, int32_t b, bool has_xy, float x_mm, float y_mm) {
  if (const char* r = refusal()) { proto_reply_error(id, r); return; }
  // 호스트는 모터별 목표 카운트를 보낸다(RPi4 kinematics.py: A = X + Y, B = X − Y). 원작 코어는 mm를 받으므로
  // 원작과 같은 식으로 되돌린다: X = (A + B) / 2, Y = (A − B) / 2.
  const float x = (static_cast<float>(a) + static_cast<float>(b)) * 0.5f / COUNTS_PER_MM;
  const float y = (static_cast<float>(a) - static_cast<float>(b)) * 0.5f / COUNTS_PER_MM;
  if (has_xy && (!isfinite(x_mm) || !isfinite(y_mm) || fabsf(x - x_mm) > KIN_MATCH_TOL_MM ||
                 fabsf(y - y_mm) > KIN_MATCH_TOL_MM)) {
    proto_reply_error(id, "bad_args");  // 호스트·펌웨어 기구 값 불일치 — 움직이지 않는다
    return;
  }
  if (!(x >= 0.0f && x <= X_MAX_MM && y >= 0.0f && y <= Y_MAX_MM)) {
    proto_reply_error(id, "soft_limit");
    return;
  }
  Step s = makeStep(StepType::MOVE, ORG_HOST);
  s.x = x;
  s.y = y;
  s.f = 0;  // 원작 기본 속도
  s.id = id;
  if (!qPush(s)) { proto_reply_error(id, "busy"); return; }
  g_stopped = false;
  g_releasePending = false;
}

void cmd_press(const ReqId& id, bool depth, int32_t amount, int32_t dwell_ms) {
  if (const char* r = refusal()) { proto_reply_error(id, r); return; }
  if (depth) { proto_reply_error(id, "z_unsupported"); return; }  // 솔레노이드는 깊이를 모른다
  const int32_t onMs = amount + dwell_ms;
  if (amount > PRESS_DRIVE_MAX_MS || onMs > static_cast<int32_t>(SOLENOID_ON_MAX_MS)) {
    proto_reply_error(id, "soft_limit");
    return;
  }
  if (dwell_ms > PRESS_DWELL_MAX_MS) { proto_reply_error(id, "bad_args"); return; }
  if (solCooling()) {
    proto_reply_error_retry(id, "z_cooldown", solCooldownLeftMs());
    return;
  }
  // 원작 positionToken 검사를 옮긴 것: 확인된 이동 목표가 없거나 그 뒤 위치가 밀렸으면 누르지 않는다.
  if (!g_posRefValid) { proto_reply_error(id, "not_homed"); return; }
  auto st = motion.status();
  if (hypotf(st.x - g_refX, st.y - g_refY) > PRESS_POS_TOL_MM) {
    motion.clearHomed();
    g_posRefValid = false;
    proto_reply_error(id, "not_homed");
    return;
  }
  Step s = makeStep(StepType::TAP, ORG_HOST);
  s.ms = static_cast<uint32_t>(onMs);
  s.id = id;
  if (!qPush(s)) { proto_reply_error(id, "busy"); return; }
  g_stopped = false;
  g_releasePending = false;
}

// 비상 정지: 큐를 기다리지 않고 즉시(원작 emergencyStop). 브레이크 STOP_BRAKE_MS 뒤 STBY LOW.
void cmd_stop(const ReqId& id) {
  drainMotionEvents();  // 정지 전에 이미 난 완료·알람을 먼저 보고한다
  const bool wasBusy = busy();
  motion.stop();
  solenoidOff();
  qClear();
  if (active) {
    if (cur.org == ORG_HOST) proto_reply_error(cur.id, "stopped");
#if BRINGUP_TEXT_COMMANDS
    else Serial.println("STOPPED");
#endif
    active = false;
  }
  if (wasBusy) {  // 중간에 끊긴 동작 — 호스트도 재홈 전까지 믿지 않는다
    motion.clearHomed();
    g_posRefValid = false;
  }
  if (g_alarm == nullptr) g_stopped = true;
  scheduleRelease(STOP_BRAKE_MS);
  proto_reply_ok(id);
}

// =====================================================================
//  bring-up 전용 사람용 명령 (-DBRINGUP_TEXT_COMMANDS=1에서만)
//  원작 텍스트 명령 중 방향 시험·원점 지정에 필요한 것만 남겼다. 시연 빌드에는 들어가지 않는다.
// =====================================================================
#if BRINGUP_TEXT_COMMANDS
constexpr float BRINGUP_RAW_MAX = 0.5f;       // M 명령 듀티 상한
constexpr uint32_t BRINGUP_RAW_MAX_MS = 2000; // M 명령 시간 상한

int parseFloats(const char* s, float* outv, int maxN) {
  int n = 0;
  char* end;
  while (n < maxN) {
    float v = strtof(s, &end);
    if (end == s) break;
    outv[n++] = v;
    s = end;
  }
  return n;
}

void printHelp() {
  Serial.println("[bring-up] M a b [ms] | Z | G x y [f] | T [ms] | H | S | P | K kp ki kd kff | ?");
}

void printStatus() {
  auto st = motion.status();
  Serial.printf("STATE %s homed=%d pos=(%.2f, %.2f) ref=(%.2f, %.2f) enc=(%ld, %ld) sol=%d q=%d alarm=%s\n",
                motionStateName(st.state), st.homed, st.x, st.y, st.xRef, st.yRef, (long)st.countA,
                (long)st.countB, solOn ? 1 : 0, qCount + (active ? 1 : 0), g_alarm ? g_alarm : "-");
}

void handleBringupLine(char* line) {
  while (*line == ' ') line++;
  if (!*line) return;
  const ReqId none = {false, 0};
  const char cmd = toupper(line[0]);
  if (line[1] != 0 && line[1] != ' ' && strcasecmp(line, "STOP") != 0) { Serial.println("ERR UNKNOWN"); return; }
  if (cmd == 'S') { cmd_stop(none); return; }
  if (cmd == 'P') { printStatus(); return; }
  if (cmd == '?') { printHelp(); return; }
  if (busy()) { Serial.println("ERR BUSY"); return; }
  float a[4];
  const int n = parseFloats(line + 1, a, 4);
  switch (cmd) {
    case 'M': {
      if (n < 2) { Serial.println("ERR USAGE: M a b [ms]"); return; }
      const float da = constrain(a[0], -BRINGUP_RAW_MAX, BRINGUP_RAW_MAX);
      const float db = constrain(a[1], -BRINGUP_RAW_MAX, BRINGUP_RAW_MAX);
      const uint32_t ms = n >= 3 ? (uint32_t)constrain(a[2], 0.0f, (float)BRINGUP_RAW_MAX_MS) : 500;
      g_posRefValid = false;
      const char* err = motion.rawPwm(da, db, ms);
      Serial.println(err ? err : "OK");
      return;
    }
    case 'K':
      if (n < 4) { Serial.println("ERR USAGE: K kp ki kd kff"); return; }
      motion.setGains(a[0], a[1], a[2], a[3]);
      Serial.println("OK");
      return;
    case 'Z':
      g_alarm = nullptr;
      g_stopped = false;
      qPush(makeStep(StepType::SET_ORIGIN, ORG_BRINGUP));
      return;
    case 'H':
      g_alarm = nullptr;
      g_stopped = false;
      g_posRefValid = false;
      qPush(makeStep(StepType::HOME, ORG_BRINGUP));
      Serial.println("OK");
      return;
    case 'G': {
      if (n < 2) { Serial.println("ERR USAGE: G x y [f]"); return; }
      if (const char* r = refusal()) { Serial.printf("ERR %s\n", r); return; }
      Step s = makeStep(StepType::MOVE, ORG_BRINGUP);
      s.x = a[0];
      s.y = a[1];
      s.f = n >= 3 ? a[2] : 0;
      qPush(s);
      Serial.println("OK");
      return;
    }
    case 'T': {
      if (const char* r = refusal()) { Serial.printf("ERR %s\n", r); return; }
      if (solCooling()) { Serial.printf("ERR z_cooldown %lu\n", (unsigned long)solCooldownLeftMs()); return; }
      Step s = makeStep(StepType::TAP, ORG_BRINGUP);
      s.ms = n >= 1 ? (uint32_t)constrain(a[0], 30.0f, (float)SOLENOID_ON_MAX_MS) : 150;
      qPush(s);
      Serial.println("OK");
      return;
    }
    default:
      Serial.println("ERR UNKNOWN");
      return;
  }
}
#endif

// ---------------- 시리얼 줄 받기 (원작 pollSerial — '!' 즉시 정지 제거, 긴 줄은 통째로 버림) ----------------
void pollSerial() {
  static char buf[HOST_LINE_MAX + 1];
  static uint16_t len = 0;
  static bool overflow = false;
  int budget = HOST_LINE_MAX;  // 한 번에 너무 오래 붙잡지 않는다
  while (budget-- > 0 && Serial.available()) {
    const int c = Serial.read();
    if (c < 0) break;
    if (c == '\r') continue;
    if (c == '\n') {
      if (!overflow && len > 0) {
        buf[len] = 0;
        g_lastHostMs = millis();  // 받은 줄이면 무엇이든 워치독 갱신
        drainMotionEvents();
        if (!proto_handle_line(buf, len)) {
#if BRINGUP_TEXT_COMMANDS
          handleBringupLine(buf);
#endif
          // 기본 빌드: JSON이 아닌 줄은 무시한다(fake_mcu와 같다)
        }
      }
      len = 0;
      overflow = false;
      continue;
    }
    if (len < HOST_LINE_MAX) buf[len++] = static_cast<char>(c);
    else overflow = true;
  }
}

// ---------------------------------------------------------------------
const char* resetReasonName() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON: return "poweron";
    case ESP_RST_SW: return "sw";
    case ESP_RST_PANIC: return "panic";
    case ESP_RST_INT_WDT: return "int_wdt";
    case ESP_RST_TASK_WDT: return "task_wdt";
    case ESP_RST_WDT: return "wdt";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_EXT: return "ext";
    default: return "other";
  }
}

void setupTaskWatchdog() {
  esp_task_wdt_config_t cfg = {};
  cfg.timeout_ms = MCU_TASK_WDT_MS;
  cfg.idle_core_mask = (1u << 0);
  cfg.trigger_panic = true;
  if (esp_task_wdt_reconfigure(&cfg) == ESP_ERR_INVALID_STATE) esp_task_wdt_init(&cfg);
  esp_task_wdt_add(nullptr);  // loop 태스크(setup이 도는 태스크)
}

void setup() {
  solBegin();  // 가장 먼저: 부팅 중 솔레노이드가 켜지지 않게
  Serial.setRxBufferSize(HOST_RX_BUFFER_BYTES);
  Serial.setTxBufferSize(HOST_TX_BUFFER_BYTES);
  Serial.begin(HOST_SERIAL_BAUD);

  motionEvents = xQueueCreate(16, sizeof(MotionEvent));
  motion.begin(motionEvents);  // STBY LOW(출력 꺼짐)로 시작
  setupTaskWatchdog();
  const BaseType_t ok = xTaskCreatePinnedToCore(controlTask, "corexy", 4096, nullptr,
                                                configMAX_PRIORITIES - 2, nullptr, 1);
  if (ok != pdPASS || motionEvents == nullptr || !motion.pwmOk() || !g_solPwmOk) {
    g_hwOk = false;  // 제어 태스크가 없다 — home·move·press를 거절한다
    g_alarm = "hw_init";
  }
  // 재부팅 직전에 코일이 켜져 있었을 수 있다(워치독·패닉) — 부팅 뒤 최소 꺼짐 시간 동안은 켜지 않는다.
  solOffAt = millis();
  solCooldownMs = SOLENOID_MIN_OFF_MS;
  g_lastHostMs = millis();
  proto_event_ready(FW_NAME, resetReasonName());
#if BRINGUP_TEXT_COMMANDS
  printHelp();
#endif
}

void loop() {
  esp_task_wdt_reset();
  drainMotionEvents();
  pollSerial();
  pump();
  solService();
  safetyService();
  positionService();
  delay(1);
}
