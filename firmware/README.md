# firmware — ESP32 BLE↔UART 브릿지

명세: [../docs/esp32-firmware-spec.md](../docs/esp32-firmware-spec.md) · 재사용 경계: [../docs/reuse-boundary.md](../docs/reuse-boundary.md)

- ESP32: 폰 앱 BLE ↔ RPi5 UART 사이의 순수 릴레이 (GRBL 아님 — 그 설계는 폐기됨,
  자세한 사유는 [../docs/actuator-design.md](../docs/actuator-design.md))
- 안전: 물리 E-STOP 인터럽트 → RPi5에 `abort` 즉시 전달. 재시도 하드 리밋·Z 누름 깊이
  상한 등 나머지 안전 계층은 폐루프 컨트롤러(RPi4) 쪽 책임 — [../docs/closed-loop-design.md](../docs/closed-loop-design.md)
