#pragma once
#include <Arduino.h>

// Set by the ISR in IRAM; checked and cleared in loop().
extern volatile bool estopTriggered;

void estopBegin();
// IRAM_ATTR는 정의(estop.cpp)에만 단다. 선언에도 달면 코어 3.x(IDF 5)에서 섹션
// 이름이 둘로 갈려 -Wattributes 경고가 난다. 정의 쪽 속성으로 IRAM 배치는 같다.
void estopISR();
