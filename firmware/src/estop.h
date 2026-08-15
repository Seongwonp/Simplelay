#pragma once
#include <Arduino.h>

// Set by the ISR in IRAM; checked and cleared in loop().
extern volatile bool estopTriggered;

void estopBegin();
void IRAM_ATTR estopISR();
