// 원작: 팀원(서예솔) Touch Bridge CoreXY 펌웨어 v3, SimpleLay용으로 통신·이름 수정
// =====================================================================
//  CoreXY 모션 컨트롤러 (DC 모터 + 엔코더 폐루프)
//
//  SimpleLay 수정(2026-10-10, 제어 핵심 — PID·기구학·궤적·원점·스톨·추종 오차 — 은 원작 그대로):
//  - STBY는 부팅 때 LOW(출력 꺼짐)로 두고 home()·moveTo()·rawPwm()·hold()가 받아들일 때만 올린다(driverOn).
//  - release(): 브레이크 뒤 STBY LOW. 호스트 워치독·정지·알람 뒤 출력을 내리는 데 쓴다.
//  - hold(): 출력을 내린 뒤(OFF) 누름 직전에 현재 위치를 다시 잡아 유지한다.
//  - clearHomed(): 정지·알람으로 동작이 끊기면 원점 기준을 버린다(SimpleLay 규약: home으로만 복구).
//  표시는 아래 "SimpleLay 추가" 주석.
//
//  기구학 (A = 왼쪽 모터, B = 오른쪽 모터, 단위 mm):
//     A = X + Y          X = (A + B) / 2
//     B = X - Y          Y = (A - B) / 2
//
//  흐름: XY 사다리꼴 궤적 -> 역기구학으로 A/B 목표 -> 모터별 PID(1kHz)
//  모든 public 함수는 스레드 안전 (loop 태스크와 1kHz 제어 태스크 사이)
// =====================================================================
#pragma once
#include <Arduino.h>
#include "config.h"
#include "Tb6612Motor.h"
#include "QuadEncoder.h"

enum class MotionState : uint8_t {
  OFF, IDLE, MOVING, HOMING_X, HOMING_Y, RAW, STOPPED, FAULT
};

enum class MotionEvent : uint8_t {
  MOVE_DONE,      // 목표 도착 (장치 ACK -> CONFIRMED)
  HOME_DONE,      // 원점 복귀 완료
  STOPPED,        // 비상 정지 완료 (STOPPED ACK)
  FAULT_FOLLOW,   // 추종 오차 초과: 걸림/충돌
  FAULT_SETTLE,   // 도착 후 정착 실패
  FAULT_HOME      // 원점을 찾지 못함
};

inline const char* motionStateName(MotionState s) {
  switch (s) {
    case MotionState::OFF: return "OFF";
    case MotionState::IDLE:     return "IDLE";
    case MotionState::MOVING:   return "MOVING";
    case MotionState::HOMING_X: return "HOMING_X";
    case MotionState::HOMING_Y: return "HOMING_Y";
    case MotionState::RAW:      return "RAW";
    case MotionState::STOPPED:  return "STOPPED";
    case MotionState::FAULT:    return "FAULT";
  }
  return "?";
}

// ---------------------------------------------------------------------
// 모터 한 축의 위치 PID + 속도 피드포워드
// ---------------------------------------------------------------------
struct AxisPid {
  float kp = DEFAULT_KP, ki = DEFAULT_KI, kd = DEFAULT_KD, kff = DEFAULT_KFF;
  float integ = 0, prevMeas = 0, velFilt = 0;
  bool first = true;

  void reset() { integ = 0; velFilt = 0; first = true; }

  // ref/meas: 카운트, velRef: 카운트/s, 반환: PWM 비율
  float update(float ref, float meas, float velRef, float dt, float outLimit) {
    float vMeas = first ? 0.0f : (meas - prevMeas) / dt;
    first = false;
    prevMeas = meas;
    velFilt += (vMeas - velFilt) * D_FILTER_ALPHA;

    float e = ref - meas;

    // 정지 상태에서 허용 오차 안이면 출력 0 (떨림·소음 방지)
    if (velRef == 0.0f && fabsf(e) <= POS_TOL_COUNTS) return 0.0f;

    float u = kp * e + integ + kd * (velRef - velFilt) + kff * velRef;

    // 정지 마찰 보상
    if (u > 0)      u = PWM_MIN + (1.0f - PWM_MIN) * u;
    else if (u < 0) u = -PWM_MIN + (1.0f - PWM_MIN) * u;

    // 포화 시 같은 방향으로는 적분하지 않음 (안티 와인드업)
    bool satHigh = u >= outLimit, satLow = u <= -outLimit;
    if (!((satHigh && e > 0) || (satLow && e < 0))) {
      integ += ki * e * dt;
      integ = constrain(integ, -I_LIMIT, I_LIMIT);
    }
    return constrain(u, -outLimit, outLimit);
  }
};

// ---------------------------------------------------------------------
class CoreXYMotion {
public:
  CoreXYMotion()
    : motA_(PIN_A_PWM, PIN_A_IN1, PIN_A_IN2, PWM_CH_A, MOTOR_A_INVERT),
      motB_(PIN_B_PWM, PIN_B_IN1, PIN_B_IN2, PWM_CH_B, MOTOR_B_INVERT),
      encA_(PIN_ENC_A_A, PIN_ENC_A_B, ENC_A_INVERT),
      encB_(PIN_ENC_B_A, PIN_ENC_B_B, ENC_B_INVERT) {}

  void begin(QueueHandle_t eventQueue) {
    evq_ = eventQueue;
    lock_ = xSemaphoreCreateMutex();
    pinMode(PIN_STBY, OUTPUT);
    digitalWrite(PIN_STBY, LOW);   // SimpleLay 수정: 원작은 HIGH. 명령을 받을 때까지 출력 꺼짐
    motA_.begin();
    motB_.begin();
    encA_.begin();
    encB_.begin();
    if (USE_LIMIT_SWITCHES) {
      pinMode(PIN_LIMIT_X, INPUT_PULLUP);
      pinMode(PIN_LIMIT_Y, INPUT_PULLUP);
    }
    state_ = MotionState::OFF;
  }

  // ---------------- 명령 API ----------------

  // XY 절대 좌표[mm]로 이동. speed<=0이면 기본 속도
  // 반환: nullptr = 수락, 그 외 = 거부 사유 문자열
  const char* moveTo(float x, float y, float speed = 0) {
    Guard g(lock_);
    if (!homed_) return "NOT_HOMED";
    if (isHoming() || state_ == MotionState::RAW) return "BUSY";
    if (x < 0 || x > X_MAX_MM || y < 0 || y > Y_MAX_MM) return "OUT_OF_RANGE";
    if (!isActive()) syncToMeasured();
    homingBackoff_ = false;
    driverOn();   // SimpleLay 추가
    startMove(x, y, speed > 0 ? speed : DEFAULT_SPEED);
    return nullptr;
  }

  const char* home() {
    Guard g(lock_);
    if (state_ == MotionState::RAW) return "BUSY";
    syncToMeasured();
    homed_ = false;
    homingBackoff_ = false;
    phaseTime_ = 0;
    driverOn();   // SimpleLay 추가
    state_ = MotionState::HOMING_X;
    return nullptr;
  }

  // 비상 정지: 즉시 브레이크. 다음 명령이 오면 다시 활성화
  void stop() {
    {
      Guard g(lock_);
      motA_.brake();
      motB_.brake();
      homingBackoff_ = false;
      state_ = MotionState::STOPPED;
    }
    emit(MotionEvent::STOPPED);
  }

  // 현재 위치를 원점(0,0)으로 지정 (리밋 없이 벤치 테스트할 때)
  void setOrigin() {
    Guard g(lock_);
    encA_.write(0);
    encB_.write(0);
    homed_ = true;
    syncToMeasured();
    if (state_ != MotionState::RAW) state_ = MotionState::IDLE;
  }

  // 방향 확인용: 모터에 PWM을 직접 ms 동안 인가
  const char* rawPwm(float a, float b, uint32_t ms) {
    Guard g(lock_);
    // 실제로 움직이는 중(이동·원점 복귀)일 때만 거부. IDLE(위치 유지)에서는 허용
    if (state_ == MotionState::MOVING || isHoming()) return "BUSY";
    rawA_ = constrain(a, -1.0f, 1.0f);
    rawB_ = constrain(b, -1.0f, 1.0f);
    rawLeft_ = ms / 1000.0f;
    driverOn();   // SimpleLay 추가
    state_ = MotionState::RAW;
    return nullptr;
  }

  // ---------------- SimpleLay 추가 ----------------

  // 브레이크 뒤 STBY LOW(출력 High-Z). 엔코더는 계속 센다. 위치 유지(IDLE)·방향 시험(RAW)이면 OFF로,
  // 움직이던 중이면 STOPPED로 둔다(호출하는 쪽이 먼저 stop()한다). FAULT·STOPPED는 그대로.
  void release() {
    Guard g(lock_);
    motA_.brake();
    motB_.brake();
    digitalWrite(PIN_STBY, LOW);
    driverOn_ = false;
    homingBackoff_ = false;
    if (state_ == MotionState::IDLE || state_ == MotionState::RAW) state_ = MotionState::OFF;
    else if (state_ == MotionState::MOVING || isHoming()) state_ = MotionState::STOPPED;
  }

  // 출력을 내린 뒤(OFF·STOPPED)라면 현재 측정 위치를 목표로 다시 잡고 유지한다(누름 직전). 원점 전이면 하지 않는다.
  void hold() {
    Guard g(lock_);
    if ((state_ != MotionState::OFF && state_ != MotionState::STOPPED) || !homed_) return;
    syncToMeasured();
    driverOn();
    state_ = MotionState::IDLE;
  }

  // 정지·알람으로 동작이 끊겼다 — 원점 기준을 믿지 않는다.
  void clearHomed() {
    Guard g(lock_);
    homed_ = false;
  }

  // 출력(STBY)이 켜져 위치를 잡고 있거나 움직이는 중인가. 호스트 워치독 판단용.
  bool outputsOn() {
    Guard g(lock_);
    return driverOn_;
  }

  void setGains(float kp, float ki, float kd, float kff) {
    Guard g(lock_);
    for (AxisPid* p : {&pidA_, &pidB_}) {
      p->kp = kp; p->ki = ki; p->kd = kd; p->kff = kff;
      p->reset();
    }
  }

  struct Status {
    MotionState state; bool homed;
    float x, y;            // 측정 위치 [mm]
    float xRef, yRef;      // 목표 위치 [mm]
    int32_t countA, countB;
  };

  Status status() {
    Guard g(lock_);
    Status s;
    s.state = state_; s.homed = homed_;
    s.countA = encA_.read(); s.countB = encB_.read();
    countsToXY(s.countA, s.countB, s.x, s.y);
    s.xRef = xRef_; s.yRef = yRef_;
    return s;
  }

  // ---------------- 제어 루프 (1kHz 태스크에서 호출) ----------------
  void controlStep(float dt) {
    Guard g(lock_);
    const int32_t ca = encA_.read();
    const int32_t cb = encB_.read();
    float vx = 0, vy = 0;

    switch (state_) {
      case MotionState::OFF:
      case MotionState::STOPPED:
      case MotionState::FAULT:
        return;  // 브레이크 상태 유지

      case MotionState::RAW:
        motA_.set(rawA_);
        motB_.set(rawB_);
        rawLeft_ -= dt;
        if (rawLeft_ <= 0) {
          motA_.brake(); motB_.brake();
          syncToMeasured();
          state_ = homed_ ? MotionState::IDLE : MotionState::OFF;
          if (state_ == MotionState::OFF) { motA_.brake(); motB_.brake(); }
        }
        return;

      case MotionState::MOVING:
        advanceTrajectory(dt, vx, vy);
        break;

      case MotionState::HOMING_X:
        vx = -HOMING_SPEED;
        xRef_ += vx * dt;
        phaseTime_ += dt;
        break;

      case MotionState::HOMING_Y:
        vy = -HOMING_SPEED;
        yRef_ += vy * dt;
        phaseTime_ += dt;
        break;

      case MotionState::IDLE:
        break;
    }

    // 역기구학
    const float refA = (xRef_ + yRef_) * COUNTS_PER_MM;
    const float refB = (xRef_ - yRef_) * COUNTS_PER_MM;
    const float velA = (vx + vy) * COUNTS_PER_MM;
    const float velB = (vx - vy) * COUNTS_PER_MM;
    const float limit = isHoming() ? HOMING_PWM_LIMIT : 1.0f;

    motA_.set(pidA_.update(refA, ca, velA, dt, limit));
    motB_.set(pidB_.update(refB, cb, velB, dt, limit));

    const float errMax = fmaxf(fabsf(refA - ca), fabsf(refB - cb));

    if (isHoming()) { checkHoming(errMax); return; }

    // 추종 오차 감시 (걸림·충돌·벨트 미끄러짐)
    if (errMax > FOLLOW_ERR_MAX_MM * COUNTS_PER_MM) {
      followTime_ += dt;
      if (followTime_ >= FOLLOW_ERR_TIME_S) { fault(MotionEvent::FAULT_FOLLOW); return; }
    } else {
      followTime_ = 0;
    }

    // 도착 판정
    if (state_ == MotionState::MOVING && trajDone_) {
      settleTimeout_ += dt;
      if (errMax <= POS_TOL_COUNTS) {
        settleTime_ += dt;
        if (settleTime_ >= SETTLE_S) {
          state_ = MotionState::IDLE;
          if (homingBackoff_) { homingBackoff_ = false; emit(MotionEvent::HOME_DONE); }
          else emit(MotionEvent::MOVE_DONE);
        }
      } else {
        settleTime_ = 0;
      }
      if (state_ == MotionState::MOVING && settleTimeout_ >= SETTLE_TIMEOUT_S)
        fault(MotionEvent::FAULT_SETTLE);
    }
  }

private:
  // FreeRTOS 뮤텍스 RAII
  struct Guard {
    SemaphoreHandle_t m;
    explicit Guard(SemaphoreHandle_t mm) : m(mm) { xSemaphoreTake(m, portMAX_DELAY); }
    ~Guard() { xSemaphoreGive(m); }
  };

  bool isHoming() const {
    return state_ == MotionState::HOMING_X || state_ == MotionState::HOMING_Y;
  }
  bool isActive() const {
    return state_ == MotionState::IDLE || state_ == MotionState::MOVING || isHoming();
  }

  // SimpleLay 추가: 잠금 안에서만 부른다. 출력 핀은 digitalRead로 되읽을 수 없어(입력 버퍼 꺼짐) 플래그로 둔다.
  void driverOn() { digitalWrite(PIN_STBY, HIGH); driverOn_ = true; }
  bool driverOn_ = false;

  static void countsToXY(int32_t a, int32_t b, float& x, float& y) {
    x = (a + b) * 0.5f / COUNTS_PER_MM;
    y = (a - b) * 0.5f / COUNTS_PER_MM;
  }

  void syncToMeasured() {
    countsToXY(encA_.read(), encB_.read(), xRef_, yRef_);
    pidA_.reset();
    pidB_.reset();
    followTime_ = 0;
  }

  void emit(MotionEvent e) { if (evq_) xQueueSend(evq_, &e, 0); }

  void fault(MotionEvent e) {
    motA_.brake();
    motB_.brake();
    homingBackoff_ = false;
    state_ = MotionState::FAULT;
    emit(e);
  }

  // ---------------- 사다리꼴 궤적 ----------------
  void startMove(float x, float y, float speed) {
    p0x_ = xRef_; p0y_ = yRef_;
    p1x_ = x;     p1y_ = y;
    const float dx = x - p0x_, dy = y - p0y_;
    len_ = sqrtf(dx * dx + dy * dy);
    trajT_ = 0; settleTime_ = 0; settleTimeout_ = 0; followTime_ = 0;

    if (len_ < 1e-3f) {
      ux_ = uy_ = 0; vmax_ = 1; amax_ = 1;
      tAcc_ = tCruise_ = tTotal_ = 0; dAcc_ = 0;
      trajDone_ = true;
      state_ = MotionState::MOVING;
      return;
    }
    ux_ = dx / len_; uy_ = dy / len_;

    // CoreXY: 대각선 방향이면 한 모터가 XY 속도의 최대 √2배로 돈다 -> 모터 한계로 제한
    const float k = fmaxf(fabsf(ux_ + uy_), fabsf(ux_ - uy_));
    vmax_ = fminf(speed, MOTOR_BELT_VMAX / k);
    amax_ = fminf(DEFAULT_ACCEL, MOTOR_BELT_AMAX / k);

    tAcc_ = vmax_ / amax_;
    dAcc_ = 0.5f * amax_ * tAcc_ * tAcc_;
    if (2 * dAcc_ > len_) {             // 삼각형 프로파일
      tAcc_ = sqrtf(len_ / amax_);
      vmax_ = amax_ * tAcc_;
      dAcc_ = 0.5f * len_;
    }
    tCruise_ = (len_ - 2 * dAcc_) / vmax_;
    tTotal_ = 2 * tAcc_ + tCruise_;
    trajDone_ = false;
    state_ = MotionState::MOVING;
  }

  void advanceTrajectory(float dt, float& vx, float& vy) {
    if (trajDone_) { xRef_ = p1x_; yRef_ = p1y_; return; }
    trajT_ += dt;
    float s, v;
    if (trajT_ >= tTotal_) {
      s = len_; v = 0; trajDone_ = true;
    } else if (trajT_ < tAcc_) {
      s = 0.5f * amax_ * trajT_ * trajT_;
      v = amax_ * trajT_;
    } else if (trajT_ < tAcc_ + tCruise_) {
      s = dAcc_ + vmax_ * (trajT_ - tAcc_);
      v = vmax_;
    } else {
      const float td = tTotal_ - trajT_;
      s = len_ - 0.5f * amax_ * td * td;
      v = amax_ * td;
    }
    xRef_ = p0x_ + ux_ * s;
    yRef_ = p0y_ + uy_ * s;
    vx = ux_ * v;
    vy = uy_ * v;
  }

  // ---------------- 원점 복귀 ----------------
  void checkHoming(float errMax) {
    const bool isX = state_ == MotionState::HOMING_X;
    bool hit;
    if (USE_LIMIT_SWITCHES) {
      hit = digitalRead(isX ? PIN_LIMIT_X : PIN_LIMIT_Y) == LOW;
    } else {
      hit = phaseTime_ > STALL_ARM_S && errMax > STALL_ERR_MM * COUNTS_PER_MM;
    }

    if (hit) {
      syncToMeasured();             // 벽을 계속 미는 것 방지
      if (isX) {
        state_ = MotionState::HOMING_Y;
        phaseTime_ = 0;
      } else {
        // X, Y 모두 벽에 닿음 -> 여기가 (0,0)
        encA_.write(0);
        encB_.write(0);
        syncToMeasured();
        homed_ = true;
        homingBackoff_ = true;      // 백오프 이동이 끝나면 HOME_DONE
        startMove(HOMING_BACKOFF, HOMING_BACKOFF, HOMING_SPEED);
      }
      return;
    }

    const float maxTravel = (isX ? X_MAX_MM : Y_MAX_MM) * 1.3f + 20.0f;
    if (phaseTime_ * HOMING_SPEED > maxTravel) fault(MotionEvent::FAULT_HOME);
  }

  Tb6612Motor motA_, motB_;
  QuadEncoder encA_, encB_;
  AxisPid pidA_, pidB_;
  QueueHandle_t evq_ = nullptr;
  SemaphoreHandle_t lock_ = nullptr;

  volatile MotionState state_ = MotionState::OFF;
  bool homed_ = false, homingBackoff_ = false;
  float xRef_ = 0, yRef_ = 0;

  // 궤적
  float p0x_ = 0, p0y_ = 0, p1x_ = 0, p1y_ = 0, ux_ = 0, uy_ = 0, len_ = 0;
  float vmax_ = 1, amax_ = 1, tAcc_ = 0, tCruise_ = 0, tTotal_ = 0, dAcc_ = 0, trajT_ = 0;
  bool trajDone_ = true;

  // 타이머
  float settleTime_ = 0, settleTimeout_ = 0, followTime_ = 0, phaseTime_ = 0;

  // RAW 테스트
  float rawA_ = 0, rawB_ = 0, rawLeft_ = 0;
};