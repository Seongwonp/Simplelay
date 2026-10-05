#pragma once
// 하드웨어 경계: TB6612 채널(LEDC PWM + IN1/IN2 + STBY), PCNT 엔코더, 리밋 스위치.
// **실물 미검증** — 핀·방향은 include/board_config.h 자리표시자.
// Z_MODE_SOLENOID 빌드에서는 Z 모터·엔코더·Z 리밋이 없다: Z 축 motor_* 호출은 아무것도 하지 않고
// encoder_read(AXIS_Z)는 0, limit_*(LIMIT_Z)는 false. 대신 solenoid_set이 MOSFET 게이트 핀을 움직인다.
#include <stdint.h>

enum Axis : uint8_t { AXIS_A = 0, AXIS_B = 1, AXIS_Z = 2, AXIS_COUNT = 3 };
enum LimitId : uint8_t { LIMIT_X = 0, LIMIT_Y = 1, LIMIT_Z = 2, LIMIT_COUNT = 3 };

// 핀·LEDC·PCNT 초기화. STBY는 LOW(출력 꺼짐)로 시작한다. PCNT 설정 실패 시 false.
bool drivers_init();

// 부호 있는 듀티(+ = 카운트 증가 방향). 0이면 IN1=IN2=LOW(출력 High-Z, 공회전).
void motor_set_duty(Axis axis, int32_t duty);
// IN1=IN2=HIGH short brake.
void motor_brake(Axis axis);
// 두 드라이버 STBY를 함께 올리거나 내린다.
void drivers_standby_outputs(bool enable);

// 원점 오프셋·부호를 적용한 누적 카운트.
int32_t encoder_read(Axis axis);
// 현재 위치를 0으로 둔다.
void encoder_zero(Axis axis);

// 제어 주기마다 호출(디바운스). 인터럽트 없이 폴링한다.
void limits_sample();
bool limit_active(LimitId id);
// 디바운스 없이 지금 핀을 읽는다(활성 = true). 배선 확인(limits 명령)용 — 동작 판정에는 쓰지 않는다.
bool limit_raw_now(LimitId id);
bool any_limit_active();

// 솔레노이드(Z_MODE_SOLENOID). 모터 방식 빌드에서는 아무것도 하지 않고 solenoid_is_on()은 false.
// 시간 상한·냉각 판정은 motion.cpp가 한다 — 여기는 핀만 움직인다. drivers_standby_outputs(false)도 끈다.
void solenoid_set(bool on);
bool solenoid_is_on();
