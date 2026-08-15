#pragma once

class SensorReader {
public:
    void begin();

    // Fills current_ma_out (signed mA) and sound_db_out (0 = stub).
    // Real hardware: replace with ADS1115 I2C read + I2S mic.
    void read(int& current_ma_out, int& sound_db_out);
};

extern SensorReader sensorReader;
