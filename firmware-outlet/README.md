# firmware-outlet — ESP32 콘센트 모듈 펌웨어

**컴파일까지만 확인했다(2026-10-05, CT 두 채널 2026-10-06). CT·ADS1115·릴레이·버튼을 붙여 돌려 본 적이 없다.**
`include/config.h`의 핀·CT 보정·상용 전압·역률·릴레이 극성은 전부 **자리표시자(측정 필요)** 다.
채우기 전까지 빌드 때 `#warning`이 뜬다. 실측값이 아니므로 실기기 설정의 근거로 쓰지 않는다.

## 역할 (2026-09-30 하드웨어 방향 확정 §1)

```
전자레인지 전원선 ─ 스플리터 ─(L 한 가닥)─ CT 0 ─ ADS1115 AIN0-AIN1 ─┐
             └──── 릴레이 접점(전자레인지 전원 차단) ◀─GPIO──────────┤
세탁기 전원선 ─ 스플리터 ─(L 한 가닥)─ CT 1 ─ ADS1115 AIN2-AIN3 ─────┤ ESP32(이 보드)
             (릴레이를 거치지 않는다 — CT 계측만)                      │
                                   비상정지 버튼(NC) ─GPIO────────────┘   │
                                                                 USB 시리얼(줄 단위 JSON, 115200)
                                                                       │
                                                RPi4 — 채널별 L3 판정·잔여 전류·사이클 끝(세탁·가열 끝)
```

### CT 두 채널(2026-10-06 사용자 결정)

- 두 번째 CT로 전자레인지와 세탁기를 **동시에** 잰다. `OUTLET_CT_CHANNELS`(기본 2, `firebeetle32_1ct`는 1).
  `power` 줄마다 `ch`가 붙고 `seq`는 채널마다 따로 센다. 옛 호스트·옛 펌웨어와의 호환: `ch` 없는 줄은 채널 0.
- ADS1115는 MUX 하나라 **단발 변환으로 채널을 돌려 읽는다**(틱마다 지난 변환을 읽고 다음 채널 변환 시작, OS 비트로 끝남 확인).
  `SAMPLE_HZ` 500 → 2채널이면 채널당 250 Hz, 10 Hz 창에 25점. 내장 ADC 빌드는 틱마다 두 핀(GPIO36·GPIO39)을 다 읽는다.
- 보정은 채널마다: `CT_AMPS_PER_VOLT_CH`·`CT_CAL_GAIN_CH`·`CT_NOISE_FLOOR_A_CH`·`POWER_FACTOR_EST_CH`(전부 측정 필요).
- **릴레이는 하나이고 `OUTLET_RELAY_CH`(0 = 전자레인지)의 가전 전원만 끊는다. 세탁기 플러그는 릴레이를 거치지 않게 배선한다** —
  모터 기동 전류가 릴레이 정격을 넘을 수 있고(정격 확인 전), 세탁기는 CT로 재기만 한다. 비상정지 버튼도 이 릴레이만 연다.
- 호스트 대응은 RPi4 `SIMPLELAY_OUTLET_CHANNELS=microwave:0,washer:1`. RPi4는 `ready`의 `relay_ch`가 microwave 채널과 다르면 오류 로그를 남긴다.

- **CT → RPi4 직접.** 유효 전력 추정값을 10 Hz(기본)로 보낸다. L3(가전이 실제로 동작하나) 판정은 RPi4가 한다
  (`rpi/verifier/outlet.py` `SerialPowerSensor` → `rpi/controller/power_operation.py` `OutletOperationVerifier`).
- **물리 비상정지는 이 보드 안에서 끝난다.** 버튼이 눌리면 샘플링 태스크(500~2000 Hz)가 그 틱에 릴레이를 연다.
  호스트·시리얼·네트워크를 기다리지 않는다. 호스트에는 사후에 `estop` 이벤트로 알린다.
- 9/30 표의 "노드 5V 급전·접근 단계별 대기 전력 관리"는 이번 범위에 넣지 않았다(아래 '남은 것').

## 릴레이 기본값: 꺼짐(fail-safe)을 고른 이유

- 부팅·재부팅(워치독·패닉·전압 강하) 직후 가전 전원은 **끊긴 채**다. 호스트(RPi4)가 `relay_on`을 보내야 켠다.
- 반대(기본 켜짐)를 고르면 펌웨어가 멈추거나 비상정지 래치가 리셋으로 풀린 순간 가전이 다시 살아날 수 있다.
  비상정지 장치가 '정지 해제'를 기본값으로 갖지 않게 했다.
- 대가: 콘센트 모듈이 재부팅되면 조리 중이던 가전이 꺼진다. 시연 정책(RPi4 시작 때 자동으로 켤지)은
  `SIMPLELAY_OUTLET_RELAY_ON_START=1`로 사람이 고른다(기본은 켜지 않음).
- **비상정지 걸림은 재부팅을 넘어 남는다**(2026-10-05 리뷰 H2): RTC 메모리(리셋·워치독·패닉)와 NVS(전원 차단)에 적어 두고,
  부팅 때 둘 중 하나라도 걸림이면 걸린 채 시작한다 — `ready`·`status`의 `estop`이 true, `relay_on`은 `estop_latched`로 거절.
  풀리는 길은 `estop_reset`(버튼이 돌아온 뒤)뿐이다. RPi4는 사람이 RPi5에서 해제를 확인해야(`POST /stop/ack`) 이것을 보낸다.
- 하드웨어도 같은 방향이어야 한다: 재부팅 중 GPIO는 High-Z다. **활성 HIGH 모듈은 IN에 외부 풀다운,
  활성 LOW(광커플러) 모듈은 모듈 내부 풀업**으로 High-Z일 때 릴레이가 열려야 한다. 실제 모듈로 확인 필요.
- 호스트가 조용해질 때 릴레이를 열지(`HOST_SILENCE_RELAY_OFF`)는 기본 0(끄지 않음) — RPi4 재시작마다 가전이 꺼지지
  않게. 1로 빌드하면 `HOST_SILENCE_MS` 뒤 열고 `host_timeout` 이벤트를 보낸다.

## 빌드

```powershell
# 저장소 밖 venv에 PlatformIO(이 PC: C:\pio-venv). 코어 폴더는 짧은 경로 — 사용자 폴더 아래에서는
# 프레임워크 압축 해제가 Windows 경로 길이 260자 제한에 걸렸다(2026-10-05).
$env:PLATFORMIO_CORE_DIR='C:\pio'
$env:PLATFORMIO_BUILD_DIR='C:\pio-build\firmware-outlet'   # 저장소 경로에 한글이 있을 때
C:\pio-venv\Scripts\pio.exe run -d firmware-outlet             # 기본 env(ADS1115)
C:\pio-venv\Scripts\pio.exe run -d firmware-outlet -e firebeetle32_adc   # ESP32 ADC 대안
C:\pio-venv\Scripts\pio.exe run -d firmware-outlet -e firebeetle32_1ct   # CT 하나
```

플랫폼은 `firmware-motion`과 같은 고정 버전(pioarduino `55.03.312-1` = Arduino-ESP32 3.3.12, ESP-IDF 5.5.5), 보드 `firebeetle32`.

| env | CT 입력 | 비고 |
|---|---|---|
| `firebeetle32`(기본) | ADS1115 2채널(AIN0-AIN1·AIN2-AIN3 차동), ±2.048 V, 860 SPS 단발 변환 → 500 Hz 돌려 읽기 | 9/30 센서 권장안 + 10/6 두 번째 CT |
| `firebeetle32_1ct` | ADS1115 1채널(AIN0-AIN1), 500 Hz | CT 하나로 조립했을 때 |
| `firebeetle32_adc` | ESP32 ADC1 2채널(GPIO36·GPIO39), 2000 Hz, 창 평균으로 DC 제거 | 외부 ADC 없이 시험용. 잡음·비선형 큼 |

**플래시하지 않았다.** 올리기 전에 아래 배선 확인표를 팀원과 채운다.

## 규약

줄 단위 JSON(`\n`), 115200. 자세한 것은 [`docs/protocol.md`](../docs/protocol.md) "콘센트 모듈 링크",
기계가 읽는 표는 [`protocol_table.json`](protocol_table.json). `rpi/tests/test_outlet_protocol.py`가
표 · 가짜 출력(`rpi/tools/fake_outlet.py`) · 이 소스의 이름을 대조한다.

| 명령 | 응답 | 비고 |
|---|---|---|
| `status` | `relay, estop, button, rate_hz, ct, cal, uptime_ms, channels, relay_ch` | `cal: placeholder`면 보정 전 |
| `ping` | `ok` | heartbeat(호스트 기본 1 s) |
| `relay_on` | `ok` / `estop_latched` | 비상정지 걸린 동안 거절 |
| `relay_off` | `ok` | |
| `estop_reset` | `ok` / `estop_active` | 버튼이 돌아온 뒤에만. 해제해도 릴레이는 꺼진 채 |
| `rate` | `ok` / `bad_args` | `hz` 1~20, SAMPLE_HZ를 나누어떨어지는 값, 채널당 창 샘플 20 이상(2채널 ADS1115는 10 Hz까지) |

이벤트: `ready`(부팅 배너, `channels`·`relay_ch`) · `power`(`ch`) · `estop` · `fault`(`ct_init`·`sampling_task`) · `host_timeout`.

## 전력 계산(추정)

창(기본 100 ms = 60 Hz 6주기)마다 채널별로: CT 출력 µV 샘플의 분산(= DC 제거한 제곱 평균) → 실효 전압 →
`Irms = V × CT_AMPS_PER_VOLT_CH[ch](30, SCT-013-030 정격) × CT_CAL_GAIN_CH[ch](1.0, 보정 전)` → 잡음 바닥을 직교 성분으로 뺌(기본 0) →
`watts = Irms × MAINS_VRMS_EST(220, 측정 아님) × POWER_FACTOR_EST_CH[ch](1.0)`. 전압을 재지 않으므로 유효 전력이 아니라
**피상 전력 추정**에 가깝다. L3는 기준선 대비 변화를 보므로 절대 오차에 비교적 둔감하다 — 그래도 보정 전 숫자를 발표에서
"소비 전력 몇 W"로 말하지 않는다.

## 배선 가정 — 팀원(HW)과 확인할 것

| 항목 | 이 펌웨어의 가정(자리표시자) | 확인할 것 |
|---|---|---|
| CT | SCT-013-030 ×2(전압 출력형, 부담 저항 내장, 30 A → 1 V rms) | 두 CT의 실제 모델. 전류 출력형(SCT-013-000)이면 외부 부담 저항 값과 `CT_AMPS_PER_VOLT_CH` |
| CT 물림 | AC 라인 스플리터 연장선의 L **한 가닥** | 코드를 통째로 물리면 상쇄되어 0에 가깝다 |
| ADS1115 | I2C SDA 21 · SCL 22, 주소 0x48(ADDR→GND), ch0 AIN0-AIN1·ch1 AIN2-AIN3 차동, AIN1·AIN3 쪽 각각 VDD/2 바이어스 | 실제 핀·주소·바이어스 회로(분압 저항·커패시터 값). 3채널 이상이면 `ADS1115_MUX_CH` 주석의 배선 |
| ESP32 ADC 대안 | CT 0 → GPIO36, CT 1 → GPIO39, 다른 선 → 1.65 V 바이어스 | 쓸지 여부 |
| 채널 ↔ 가전 | ch0 전자레인지(릴레이 거침), ch1 세탁기(**릴레이 거치지 않음**) | 실제 플러그 배선. RPi4 `SIMPLELAY_OUTLET_CHANNELS`와 맞춘다 |
| 릴레이 | GPIO26, 활성 HIGH, NO 접점 | 모듈 극성(활성 LOW 광커플러 모듈이 흔하다), 접점 정격(전자레인지 약 1~1.5 kW → 220 V 약 7 A + 돌입 전류), 코일 전원(5 V?) |
| 비상정지 버튼 | GPIO27, NC 접점 → GND, 내부 풀업 (눌림·단선 = HIGH = 정지) | 버튼 접점 형식(NC/NO). NO면 단선이 '정지 불가'로 숨는다 |
| 상용 전압·주파수 | 220 V, 60 Hz | 현장 콘센트 실측 |
| 보정 | 채널마다 `CT_CAL_GAIN_CH` 1.0, `CT_NOISE_FLOOR_A_CH` 0 | 채널마다 정격을 아는 저항 부하(전기 포트 등)·클램프 미터와 비교, 무부하 몇 분 기록 |

**안전:** 220 V 배선(릴레이 접점·스플리터)은 절연 케이스 안에서, 팀이 정한 안전 점검 뒤에만 연결한다.
CT는 비접촉이지만 릴레이는 상용 전원을 직접 끊는다.

## 남은 것

- 실물: 보드 배선 → `status`·`power` 이벤트 확인 → 무부하 잡음 → 정격 부하 보정 → 릴레이 극성·재부팅 중 상태 →
  버튼 차단 지연(측정 필요).
- 9/30 표의 노드 5 V 급전·접근 단계별 대기 전력 관리, PZEM 계열 소형화는 이 펌웨어에 없다.
- 모션도 ESP32로 가면 ESP32가 두 개 필요하다(보유 수량 확인 — 하드웨어 방향 확정 §5).
