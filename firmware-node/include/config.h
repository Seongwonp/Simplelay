#pragma once

// ─── WiFi (dev-mode transport only — production demo path is ESP-NOW,
// see docs/roadmap.md M2) ────────────────────────────────────────────────────
// 개발 중 임시 하드코딩 — 나중에 프로비저닝 방식(WiFiManager 등)으로 교체 예정.
#define WIFI_SSID       "CHANGE_ME"
#define WIFI_PASSWORD   "CHANGE_ME"

// ─── HTTP server (RPi5 -> 이 노드) ───────────────────────────────────────────
// rpi/services/esp_node_controller.py의 EspNodeController가 이 포트로 붙는다.
#define HTTP_PORT       8080

// 긴급 정지 전용 리스너 — 반드시 HTTP_PORT + 1 (EspNodeController가 base_url
// 포트 + 1로 계산해 붙는다). 별도 포트인 이유: WebServer는 단일 스레드라
// /execute 처리(waitForActReply 블로킹) 중에는 같은 포트의 새 연결을 받지
// 못한다 — 정지가 가장 필요한 순간에 정지 요청이 대기열에서 썩는 구조였다.
#define STOP_PORT       (HTTP_PORT + 1)

// ─── UART (Serial2) → RPi4 (이 노드가 담당하는 가전의 Act 보드) ────────────────
// Serial2 default pins on FireBeetle WROOM-32 — firmware/(폰 폴백 브릿지)와
// 같은 핀 배치, 다른 물리 보드라 충돌 없음.
#define ACT_UART_BAUD       115200
#define ACT_UART_RX_PIN      16
#define ACT_UART_TX_PIN      17

// ─── Timing ────────────────────────────────────────────────────────────────
// RPi4가 execute에 응답(폐루프 재시도 포함)할 때까지 기다리는 최대 시간 —
// 버튼 수에 비례(rpi/services/esp_node_controller.py의 timeout_for와 같은
// 산정식). 단, RPi5보다 항상 먼저 포기해야 한다: 그래야 RPi5가 조용히
// 타임아웃되는 대신 504를 받아 정지까지 보낼 수 있다. 그래서 기저값을
// RPi5(30s)보다 10초 짧게 잡는다.
#define ACT_BASE_TIMEOUT_MS       20000
#define ACT_PER_BUTTON_TIMEOUT_MS  6000
// 고정값 시절의 상한 — 방어적 절대 상한으로만 남긴다
#define ACT_MAX_TIMEOUT_MS       180000
#define JSON_BUF_SIZE              512
#define HTTP_BODY_MAX_BYTES       1024

// ─── Pins ──────────────────────────────────────────────────────────────────
#define LED_PIN            2
