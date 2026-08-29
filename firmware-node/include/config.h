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
// JSON 라인 버퍼 — **전송 경로 바이트 예산과 짝**이다(rpi/api/schemas.py의
// MAX_EXECUTE_PAYLOAD_BYTES = 2560). 한글 라벨은 UTF-8 3바이트라 상한
// "20개 × 40자"의 최악 줄이 약 2.6KB다. 512로는 조용히 잘렸다(교차 리뷰 지적).
// 예산 + 봉투(type/sequence_id/mac) 여유를 덮는 값으로 잡는다.
#define JSON_BUF_SIZE              3072
#define HTTP_BODY_MAX_BYTES       1024

// ─── ESP-NOW (본선 데모 전송) ───────────────────────────────────────────────
// 시연장 공유 Wi-Fi 혼잡과 무관하게 통신하려는 것이 목적 — 공유기를 아예 거치지
// 않는다. 다만 ESP-NOW는 ESP32 라디오끼리만 통하므로, RPi5 쪽에도 게이트웨이
// ESP32가 UART로 붙어 있어야 한다:
//     RPi5 --UART--> ESP32 게이트웨이 --ESP-NOW--> 이 노드 --UART--> RPi4
#define ESPNOW_ENABLED            0   // 1로 바꾸면 HTTP 대신 ESP-NOW로 동작

// 게이트웨이 ESP32의 MAC. 실기기에서 게이트웨이의 WiFi.macAddress()로 확인해 채운다.
#define ESPNOW_GATEWAY_MAC        {0x00, 0x00, 0x00, 0x00, 0x00, 0x00}

// 양쪽이 같은 채널이어야 통신된다. AP에 붙지 않으므로 명시적으로 고정한다.
#define ESPNOW_CHANNEL            1

// 한 프레임은 250바이트가 상한이라(ESP-NOW 규격) 큰 메시지는 쪼개 보낸다.
// 상한(버튼 20개 × 라벨 40자)의 최악 본문은 약 2.5KB다 — 한글이 UTF-8 3바이트라
// 글자 수로 세면 3배 과소평가한다.
#define ESPNOW_FRAME_HEADER_BYTES 4
#define ESPNOW_MAX_FRAME_BYTES    250
#define ESPNOW_MAX_PAYLOAD_BYTES  (ESPNOW_MAX_FRAME_BYTES - ESPNOW_FRAME_HEADER_BYTES)
// 재조립 버퍼 — ESP-NOW 본문도 같은 바이트 예산을 따른다(위 JSON_BUF_SIZE 주석 참고)
#define ESPNOW_MAX_MESSAGE_BYTES  3072
// 조각이 다 오지 않은 채 이 시간이 지나면 버린다(유실된 조각으로 버퍼가 막히지 않게)
#define ESPNOW_REASSEMBLY_TIMEOUT_MS 3000

// 조각 하나를 보낸 뒤 MAC 계층 전달 결과(송신 콜백)를 기다리는 상한.
// esp_now_send()는 **큐에 넣기만** 하고 즉시 성공을 반환한다 -- 전달 완료가 아니다.
// 공식 권장대로 이전 조각의 콜백을 받고 다음 조각을 보낸다. 안 그러면 큰 메시지의
// 조각이 몰려 큐를 넘기고, 무엇이 실제로 나갔는지도 알 수 없다.
#define ESPNOW_SEND_ACK_TIMEOUT_MS 50

// ─── Pins ──────────────────────────────────────────────────────────────────
#define LED_PIN            2
