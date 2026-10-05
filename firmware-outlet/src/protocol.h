#pragma once
// 콘센트 모듈 줄 단위 JSON 규약(line-json/outlet-v0). 호스트 쪽은 rpi/verifier/outlet.py,
// 실행 가능한 기준은 rpi/tools/fake_outlet.py, 명령 표는 firmware-outlet/protocol_table.json.
// 시리얼 쓰기는 loop 태스크에서만 한다(샘플링 태스크는 쓰지 않는다).
#include <stddef.h>
#include <stdint.h>

#include "ct.h"

// 받은 한 줄(개행 제외, NUL 종료)을 처리한다. 해석할 수 없는 줄은 무시한다(모션 MCU와 같다).
void proto_handle_line(char* line, size_t len);

// 보고 주기(Hz). rate 명령이 바꾼다. 샘플링 태스크가 창 길이 계산에 읽는다.
uint32_t proto_report_hz();

void proto_event_ready(const char* reset_reason, bool ct_ok);
void proto_event_power(const PowerReport& r, bool relay_on);
void proto_event_estop(uint32_t t_ms);
void proto_event_fault(const char* reason);
void proto_event_host_timeout();
