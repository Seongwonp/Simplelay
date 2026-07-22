# firmware — ESP32 브릿지 · GRBL 설정 (Touch Bridge 재사용/참조)

Touch Bridge 하드웨어 플랫폼에서 가져온다. 재사용 경계: [../docs/reuse-boundary.md](../docs/reuse-boundary.md)

- ESP32 브릿지: 앱/RPi 명령 → UART → Arduino Uno GRBL
- GRBL 설정: steps/mm, max rate, acceleration, travel (NK1704S 기준 재튜닝)
- 6겹 안전: 리드스크류 셀프락 → 스프링 완충 → probe 접점 → 하드리밋 → 소프트리밋 → 물리 E-STOP
