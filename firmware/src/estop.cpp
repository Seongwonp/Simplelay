#include "estop.h"
#include "config.h"

volatile bool estopTriggered = false;

void estopBegin() {
    pinMode(ESTOP_PIN, INPUT_PULLUP);
    attachInterrupt(digitalPinToInterrupt(ESTOP_PIN), estopISR, FALLING);
    log_i("E-STOP armed on GPIO %d (active-low)", ESTOP_PIN);
}

void IRAM_ATTR estopISR() {
    estopTriggered = true;
}
