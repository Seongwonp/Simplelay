# Arduino Uno 모션 펌웨어 검토·포팅 계획

2026-10-01. **설계 검토이며 실물·컴파일 검증 아님.** 대상은 ATmega328P 기반 Uno R3(16MHz, SRAM 2KB)다.
Uno R4에는 이 핀·타이머·메모리 계획을 적용하지 않는다. [공식 Uno R3 사양](https://store.arduino.cc/products/arduino-uno-rev3).

확정 역할: RPi5는 해석·제안·키오스크, RPi4는 실행 관리·검증, ESP32는 CT 전력·릴레이 비상정지 콘센트 모듈,
Uno는 CoreXY A/B 모터 구동·정지다. Z는 시간 기반 SwitchBot 분해 모듈이다.
`firmware-motion/`은 ESP32 규약 참고 구현이며 콘센트 ESP32에 업로드하지 않는다.

## 1. 핀 초안 — 배선 전 HW 담당자 확인

Uno의 외부 인터럽트 INT0/INT1은 D2/D3뿐이다. 각 모터 엔코더의 CHA를 하나씩 연결하고 CHB는 방향 판독에 쓴다.
CHANGE 엣지에서 CHB를 읽는 x2 계수를 우선 검토한다. 기존 ESP32 PCNT의 x4와 계수가 다르므로
호스트 `SIMPLELAY_MOTION_DECODING_MULTIPLIER`와 출력축 회전당 카운트를 함께 재측정해야 한다.
x4가 꼭 필요하면 CHB의 pin-change 인터럽트까지 써야 하며 최대 엣지율·ISR 지연 검증이 선행된다.
핀 기능 근거: [공식 핀아웃](https://content.arduino.cc/assets/Pinout-UNOrev3_latest.pdf),
[AVR 코어 핀·타이머 매핑](https://github.com/arduino/ArduinoCore-avr/blob/master/variants/standard/pins_arduino.h).

| 핀 | 제안 배선 | 충돌·제약 |
|---|---|---|
| D0/D1 | USB 브리지 UART RX/TX 전용 | 다른 장치·SoftwareSerial과 공유 금지 |
| D2 / D4 | 모터 A 엔코더 CHA / CHB | D2 INT0, ISR에서 D4 방향 판독 |
| D3 / D7 | 모터 B 엔코더 CHA / CHB | D3 INT1, **D3 PWM 사용 금지** |
| D5 / D6 | TB6612 드라이버1 PWMA / PWMB | Timer0 기본 PWM, 분주·모드 변경 금지 |
| D8 / D9 | 드라이버1 AIN1 / AIN2 | D9 PWM 사용 안 함 |
| D10 / D12 | 드라이버1 BIN1 / BIN2 | D10 PWM·SPI 사용 안 함 |
| D11 | 드라이버2 Z PWMA | Timer2 PWM, tone 사용 금지 |
| A0 / A1 | 드라이버2 Z AIN1 / AIN2 | 디지털 출력으로 사용 |
| A5 | 두 TB6612 STBY 공통 | 외부 풀다운, 리셋 중 차단. I²C 사용 안 함 |
| A2 / A3 / A4 | X / Y / Z 리밋 | PCINT10/11/12, PCINT1 벡터 공유 |
| D13 | 예비·표시용 | 부트로더 LED 토글 가능하므로 STBY로 쓰지 않음 |

두 드라이버 STBY를 공유하는 초안이므로 전역 고장 때 세 축을 함께 끈다. 평상시 축별 정지는 IN/PWM으로 한다.
독립 STBY가 필수면 핀 배분을 다시 설계한다. 모터 전원은 GPIO에서 공급하지 않고 논리 전원·공통 GND·모터 전압,
TB6612 연속/정지 전류·방열을 실제 모듈과 대조한다. SwitchBot 원래 회로를 우회해 DC 모터를 직접 구동한다는
**가정**이다. 실제 모듈이 버튼 접점 방식이면 Z H브리지 계획을 바꿔야 한다.

리밋 PCINT는 현재 포트 비트와 직전 비트를 비교해 변경 축만 표시한다. ISR에서 JSON·Serial·delay를 호출하지 않는다.
빠른 위험 입력은 출력을 차단하는 플래그로 즉시 반영하고, 제어 루프에서 디바운스 상태와 `raw/debounced`를 관리한다.
NC 배선·풀업·단선 활성 수준은 실측 후 결정한다. 32비트 엔코더 스냅샷은 AVR 8비트 CPU에서 원자적이지 않으므로
짧은 `ATOMIC_BLOCK`으로 복사한다. 인터럽트 비활성 구간 길이와 최대 모터 속도의 누락 카운트를 측정한다.

## 2. 2KB SRAM 예산

참고 구현은 `HOST_LINE_MAX=256`, `JSON_POOL_BYTES=6144`, 출력 192바이트, FreeRTOS 제어 스택을 사용한다.
그대로 옮길 수 없다. 아래는 **목표 예산**이며 컴파일 결과나 실측값이 아니다.

| 용도 | 목표 바이트 | 설계 |
|---|---:|---|
| 한 줄 RX | 257 | 기존 256바이트 한도 + NUL, 초과 시 개행까지 통째로 버림 |
| JSON 파서 공간 | 256 | ArduinoJson 6 고정 문서 후보, 입력 버퍼 zero-copy 전제 |
| 응답 버퍼 | 192 | 최대 limits/status 길이 검사, 잘림 응답 전송 금지 |
| UART RX/TX 링 | 128 | 각각 64, 실제 사용 코어 설정 확인 |
| 모션·PID·엔코더·기한·리밋 상태 | 256 | 2축 위치 제어, Z는 시간·상태만 |
| 기타 전역·코어 상태 | 128 | String·동적 컨테이너 금지, 상수는 F()/PROGMEM |
| 스택·ISR 중첩 여유 | 512 | 워터마크 측정, parser·snprintf 최대 경로 포함 |
| 남는 예비 | 319 | 합계 2048, 링크 맵으로 재산정 |

UART 기본 버퍼 근거는 [AVR HardwareSerial 소스](https://github.com/arduino/ArduinoCore-avr/blob/master/cores/arduino/HardwareSerial.h).
ArduinoJson 7의 현재 ESP32 풀을 재사용하지 않는다. ArduinoJson 6의 `StaticJsonDocument<256>` 후보는
최대 요청 객체의 `JSON_OBJECT_SIZE`와 문자열 복사 여부를 실제 AVR 빌드에서 검사해야 한다.
용량 부족을 감지하면 `bad_args` 또는 줄 폐기 정책으로 실패하게 하고 움직이지 않는다.
대안인 수제 파서는 고정 토큰 배열을 쓰되 전체 JSON 문법(공백·escape·숫자 범위·중복 키·끝의 쓰레기)을
검증해야 한다. `strstr`로 cmd만 찾는 파서는 금지한다. 짧은 개발 시간만 보고 수제 파서를 선택하지 않는다.

최초 포팅은 status/ping/limits/stop만 넣되 **동일한 `firmware-motion/protocol_table.json`을 단일 계약으로 참조**한다.
명령 표 사본은 만들지 않는다. id는 signed 32비트 범위를 검사하고 host 장시간 운용 시 id 범위도 검토한다.
호스트의 선택적인 x_mm/y_mm 부동소수점 해석·출력은 AVR 비용을 재고, 모터 목표는 기존 signed 32비트 카운트를 유지한다.

## 3. 타이머·루프·워치독

| 자원 | 용도 | 제약 |
|---|---|---|
| Timer0 | Arduino millis/micros 및 D5/D6 기본 PWM | 기존 시간 기준 보존. ESP32 20kHz 설정을 그대로 적용하지 않음 |
| Timer1 | 1kHz 제어 틱 후보(CTC) | ISR은 틱 플래그만. D9/D10 PWM·Servo 금지 |
| Timer2 | D11 Z PWM | D3는 입력, OC2B 출력 비활성. tone 등 점유 금지 |
| AVR WDT | 주 루프 고착 복구 | 소프트웨어 host timeout과 별개 |

FreeRTOS 태스크·뮤텍스는 없애고 한 루프에서 제어 tick → 제한된 RX 바이트 처리 → 제한된 TX 처리를 순환한다.
한 번에 256바이트를 파싱·블로킹 출력하면 1ms 제어 목표가 깨질 수 있다. RX 바이트 예산과 TX 잔여 공간을 확인하고
응답을 단계적으로 내보낸다. stop 처리의 최대 지연을 측정하며, 틱 누적/누락은 고장으로 처리한다.
1kHz는 참고 구현의 목표일 뿐 AVR에서 달성됐다는 뜻이 아니다.

`<avr/wdt.h>`의 `wdt_enable`/`wdt_reset`을 사용한다. 부트 초기 `.init3`에서 MCUSR 리셋 원인을 보관하고
WDRF를 정리한 뒤 WDT를 끄는 절차를 검토한다. 부트로더가 원인을 먼저 지우거나 WDT 리셋 루프를 만드는지 확인한다.
정상 제어·통신 루프가 한 바퀴 완료됐을 때만 feed하고 ISR에서 무조건 feed하지 않는다.
리셋 전후 STBY 풀다운이 출력 차단을 유지해야 한다. [avr-libc WDT 문서](https://avrdudes.github.io/avr-libc/avr-libc-user-manual/group__avr__watchdog.html).

호스트 watchdog은 기존 500ms ping/2s timeout을 출발점으로 검증한다. 참고 구현처럼 수신 줄마다 갱신할지,
유효 명령만 갱신하도록 강화할지는 규약·fake MCU·호스트 테스트를 함께 변경하는 별도 결정이다.
무응답 시 즉시 출력 차단, 원점 무효화, `host_timeout` 이벤트/실패 응답, 자동 재개 금지가 필요하다.
물리 정지 입력·콘센트 릴레이 차단은 플랫폼 서비스나 RPi 추론의 생존에 의존하지 않는다.

## 4. 시리얼·DTR

초기 baud 후보는 참고 구현과 같은 115200, 8N1이다. 호스트 `SIMPLELAY_MOTION_BAUD`와 맞추고
실제 USB 브리지·16MHz 오차·최대 수신량에서 누락을 재현 시험한다. 필요하면 양쪽을 57600으로 낮춘다.
8N1에서 256바이트 전송만 약 22.2ms(115200 기준)다. 수신과 제어를 병행해야 한다.

Uno USB 포트 open의 DTR 변화는 리셋을 일으킬 수 있다([공식 Uno 설명](https://store.arduino.cc/products/arduino-uno-rev3)).
`PySerialLineTransport`가 open 전 DTR/RTS를 내려도 OS/브리지 동작까지 보장하지 않는다.
RPi4가 포트를 단독 소유하고 부트 `ready` 또는 status backoff로 연결한다. `connect_timeout_s`는 실제 부팅 시간으로 확인한다.
실행 중 `ready`는 현재 작업 실패·원점 무효·재홈 요구다. 프로브 기본 모드는 이 때문에 포트를 열지 않는다.
Z를 누르는 도중 USB 리셋이 발생해도 무조건 후퇴시키지 않는다. 기구가 눌린 채 남는 위험과 해제 절차를 따로 검증한다.

## 5. 그대로 유지할 계약 / 다시 만들 부분

| 참고 구현 | Uno 대응 |
|---|---|
| 줄 JSON, id 응답 대응, line-json/v0 | 유지. 개행·오버플로·잘못된 타입·늦은 응답 테스트 공유 |
| status/ping/limits/stop 필드 | 1:1 유지. 없는 센서를 성공/정상으로 꾸미지 않음 |
| home/move 완료 뒤 ok, busy/not_homed/alarm 거부 | 계약 유지, 비차단 AVR 상태기계 재구현 |
| press duration | 시간 구동·dwell·제한된 복귀 상태기계로 변경 |
| press depth 및 Z 엔코더 | 지원하지 않음: bad_args. z 필드 0은 계측 위치가 아님을 문서화 |
| XY 변환·소프트 리밋 | RPi4 계산 유지, MCU 하드 리밋/목표 범위 검증 유지 |
| PCNT x4·LEDC·ESP 태스크 watchdog | INT/PCINT 계수·AVR 타이머 PWM·avr wdt로 교체 |
| ready/reset, alarm/z_retract, position | 필드 유지. 실제 가능한 reset 원인·Z 복귀 결과만 보고 |
| Z 알람 후퇴 | 기구 확인 전 자동 후퇴 금지. timeout·원점 불명은 skipped |

`fake_mcu.py`는 호스트 규약 리허설 도구이며 실제 엔코더·관성·전류·PWM 안전 검증을 대신하지 않는다.
Z 리밋이 없으면 limits의 거짓 정상값을 반환하는 골격보다 지원 불가를 명시하는 계약 검토가 먼저다.

## 6. 구현 순서·위험과 완료 기준

이번에는 `firmware-uno/` 골격을 만들지 않는다. 6KB 풀의 제거, 파서 용량 증명, Z 피드백 부재 정책과
고착 시 차단 경로가 아직 결정되지 않아 단순 보드 이름 변경으로 끝나는 포팅이 아니다.

1. 핀·전압·STBY 풀다운·Z 구동 방식·리밋 존재를 HW 담당자와 확정한다.
2. PlatformIO `platform=atmelavr`, `board=uno`, `framework=arduino` 환경을 고정 버전으로 구성한다.
   status/ping/limits/stop만 구현하고 home/move/press는 TODO로 거절한다. 출력은 계속 비활성으로 둔다.
3. 계약 표 기반 호스트 테스트: 정상/잘린 줄/초과 길이/escape/범위 초과/stop 우선/재부팅/heartbeat를 검증한다.
   빌드 맵과 최대 스택 워터마크로 SRAM 예산을 입증한다. 미구현 motion을 컴파일 성공으로 주장하지 않는다.
4. 무부하 엔코더 최대 엣지율·양방향 계수·리밋 단선·DTR·WDT 리셋 중 STBY를 측정한다.
5. 전류 제한 전원·정지 경로를 확보한 뒤 A/B 저속 홈과 작은 이동부터 진행한다. Z는 마지막이다.

주요 위험은 엔코더 누락, JSON/TX로 인한 제어 지연, SRAM/스택 충돌, DTR 재부팅, 시간 기반 Z의 과누름,
전원 차단 뒤 기구 잔류, 원점 오인이다. 최대 속도에서 누락·정지 지연을 통과하지 못하면 외부 카운터 또는
더 여유 있는 MCU를 별도 검토한다. 현재 Uno 확정을 조용히 다른 보드로 바꾸지 않는다.
