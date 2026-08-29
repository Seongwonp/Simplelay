#pragma once

#include <ArduinoJson.h>
#include <functional>

// 전송 계층 공통 계약.
//
// 개발용 HTTP(http_server.*)와 본선 데모용 ESP-NOW(espnow_transport.*)가 이 콜백들을
// 똑같이 쓴다. main.cpp의 실행 로직은 어느 전송이 붙어 있는지 몰라도 되고, 전송을
// 바꿔도 손댈 필요가 없다 -- 전송 교체가 배선 변경으로 끝나는 이유가 이것이다.

// buttons를 실행하고 완료까지 기다린다. 반환값 true = RPi4로부터 응답을 받음
// (성공이든 실패든 -- outSuccess/outRetry에 실림). false = 응답을 못 받음
// (타임아웃/전송 실패) -- 호출부가 그에 맞는 오류 응답으로 변환한다.
using ExecuteHandler = std::function<bool(const JsonArray& buttons, bool& outSuccess, int& outRetry)>;

// 최근 alert 상태를 out에 채워 넣는다 (active/kind/band_energy_ratio/
// mean_period_seconds) -- rpi/api/schemas.py의 AlertResponse와 같은 모양.
using AlertsHandler = std::function<void(JsonDocument& out)>;

// 긴급 정지 요청. **실행 대기 중에도 도착할 수 있어야 한다** -- 정지가 가장 필요한
// 순간이 바로 실행 중이기 때문이다. HTTP는 이를 별도 포트로 풀고(단일 스레드
// WebServer가 /execute 처리 중 새 연결을 못 받으므로), ESP-NOW는 프레임 종류로
// 구분한다. 어느 쪽이든 main.cpp가 보는 계약은 이 콜백 하나로 같다.
using StopHandler = std::function<void()>;
