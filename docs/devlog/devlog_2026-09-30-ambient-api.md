# 2026-09-30 — 키오스크 평소 화면 서버 API (내장 가전 숨김·날씨·연결 상태)

[UI 확정](../UI-확정-2026-09-30.md) §3-1 평소 화면과 [본선 실행 계획](../본선-실행계획-2026-09-30.md) §3-4·§3-6에 필요한
서버 쪽 세 가지를 만들었다. **Flutter 화면은 바꾸지 않았다**(다른 기기에서 할 일). 실제 기상청 호출은 한 번도 하지 않았다 —
테스트는 공개 활용가이드 형식대로 쓴 응답 파일로만 돌린다. 키를 받으면 아래 §2-4로 한 번 확인한다.

## 1. 내장 가전은 개발자 모드·리허설에서만 목록에 보인다

- `GET /appliances`가 내장 전자레인지·인덕션을 `SIMPLELAY_DEV_MODE=1`이거나 `SIMPLELAY_ACT_MODE=simulator`일 때만 싣는다.
  리허설 런처 `python -m rpi.simulator_main`은 DEV_MODE를 끄고 ACT_MODE를 simulator로 고정하므로 리허설 화면은 종전과 같다.
- 판정은 `rpi/api/deps.py`의 `builtin_appliances_visible()` 하나다. **목록에서만** 숨긴다 — 등록부 `get()`·규칙·실행 경로는 그대로라
  "즉석밥 데워줘" 같은 기존 시연 명령과 테스트는 바뀌지 않는다. 운영 서버에 가전을 하나도 등록하지 않았으면 목록은 `[]`이고,
  키오스크는 "앱에서 가전을 추가해 주세요"를 보여 주면 된다.
- 내장 가전을 전제로 하는 기존 테스트 5개 파일은 파일 끝에 "개발자·리허설 모드로 둔다" 픽스처를 붙였다.
  새 테스트 `test_builtin_visibility.py`는 일반 모드(빈 목록·등록 가전만·`get()` 유지), 개발자 모드, 리허설 런처,
  런처 소스가 ACT_MODE=simulator를 유지하는지를 고정한다.

## 2. 날씨 — 기상청 단기예보 (`rpi/services/weather/`)

### 2-1. 구성

| 파일 | 하는 일 |
|---|---|
| `grid.py` | 위경도 → 격자(nx, ny). 기상청 공개 LCC 변환식 그대로. 서울시청 (60,127)·부산시청 (98,76)·대전시청 (67,100)·제주시청 (53,38)·기준점 (43,136)을 테스트로 고정 |
| `config.py` | 환경 변수 읽기(아래 표). real인데 키나 격자가 없으면 경고 로그 후 off |
| `kma.py` | `getVilageFcst` 요청·해석, 발표 시각 계산, 리허설용 고정 예보 |
| `service.py` | 캐시. 호출자에게 절대 예외를 올리지 않는다 |
| `ambient.py` | 인사말·안내 한 줄·예보 4칸을 만드는 순수 함수 |

- **요청:** `https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0/getVilageFcst` —
  `serviceKey, pageNo=1, numOfRows=1000, dataType=JSON, base_date, base_time, nx, ny`.
- **발표 시각:** 02·05·08·11·14·17·20·23시, 발표 뒤 약 10분부터 조회된다. 그래서 지금 시각에서 10분을 빼고 가장 최근 발표를 고른다
  (08:09 → 05시, 08:10 → 08시, 02:10 전 → 전날 23시).
- **해석:** TMP(기온)·POP(강수확률)·PTY(강수형태 0 없음·1 비·2 비/눈·3 눈·4 소나기)·SKY(1 맑음·3 구름많음·4 흐림)만 시간별로 모은다.
  나머지 항목(PCP·REH·SNO·풍향·풍속 등)은 버린다.
- **오류:** 결과 코드 `00`이 아니면 실패(`03` 자료 없음, `10` 잘못된 요청값, `22` 호출 한도 초과, `30` 등록되지 않은 키 등).
  포털 게이트웨이 오류는 `dataType=JSON`이어도 XML(`OpenAPI_ServiceResponse` → `returnReasonCode`·`returnAuthMsg`)로 오므로 따로 읽는다.
  `Unauthorized` 같은 평문·빈 본문·깨진 JSON도 모두 `KmaError(kind=network|api|parse)`로 바꾼다. **키는 URL에만 실리고,
  예외·로그에는 URL을 넣지 않는다**(테스트가 확인).
- **초단기예보(`getUltraSrtFcst`)는 붙이지 않았다.** 평소 화면의 "몇 시부터 비"와 3시간 단위 4칸은 단기예보로 충분하다.
  "지금 비"의 정확도가 문제되면 그때 붙인다.

### 2-2. 캐시와 오래된 예보

- 새 발표가 나왔을 때만 다시 받는다(하루 최대 8번 + 실패 재시도). 실패하면 `SIMPLELAY_WEATHER_RETRY_MINUTES`(기본 10분) 동안 다시 부르지 않는다 —
  키오스크 폴링이 포털 호출 한도를 태우지 않게.
- 받은 예보는 메모리에 두고, `SIMPLELAY_DB_PATH`가 있으면 settings 한 칸(`weather_forecast_cache`)에도 남긴다. 재시작 직후 인터넷이 없어도
  오래되지 않은 예보는 쓴다. 손상된 저장본은 무시한다.
- 받은 지 `SIMPLELAY_WEATHER_STALE_HOURS`(기본 6시간)가 지나면 `stale: true`이고, 안내와 예보 칸을 비운다(인사말만).
- 네트워크가 없거나 포털이 거절해도 `/ambient`는 200으로 인사말을 준다.

### 2-3. `GET /ambient`

```json
{
  "greeting": "좋은 아침이에요.",
  "tip": {"kind": "rain", "text": "오후 3시부터 비 예보가 있어요. 우산 챙기세요.", "icon": "rain"},
  "hourly": [
    {"time": "2026-09-30T09:00:00+09:00", "hour": 9, "label": "9시", "icon": "clear", "temp": 21, "pop": 20, "precip": false},
    "... 12·15·18시"
  ],
  "weather_source": "kma",
  "fetched_at": "2026-09-29T23:20:00+00:00",
  "stale": false
}
```

- **인사말:** 5~11시 "좋은 아침이에요." · 11~17시 "좋은 오후예요." · 17~21시 "편안한 저녁 보내세요." · 그 밖 "편안한 밤 보내세요."
- **안내 한 줄(하나만):** ① 확인이 필요한 일 → ② 날씨 → ③ 없음(`null`).
  - ① 위험 소리 경보가 켜져 있으면 `kind: alert` "위험할 수 있는 소리가 들렸어요. 주변을 확인해 주세요."
    마지막 실행이 실패·안전 정지면 `kind: appliance` "{가전 이름} 확인이 필요해요. 마지막 작업이 끝까지 되지 않았어요."
    (다음 실행이 시작될 때까지 남는다 — 실행 기록 시각을 쓰지 않는 가장 단순한 규칙.)
  - ② 앞으로 `SIMPLELAY_WEATHER_TIP_HOURS`(기본 12시간) 안에서 비·눈(강수형태가 있거나 강수확률 ≥ `SIMPLELAY_WEATHER_RAIN_POP`, 기본 60%) →
    최고 기온 ≥ `SIMPLELAY_WEATHER_HEAT_C`(기본 33) → 최저 기온 ≤ `SIMPLELAY_WEATHER_COLD_C`(기본 -5) 순.
    예: "오후 3시부터 비 예보가 있어요. 우산 챙기세요." · "지금 비 소식이 있어요. 나갈 때 우산 챙기세요." ·
    "내일 오전 6시부터 …" · "오후 1시부터 눈 예보가 있어요. 길이 미끄러울 수 있어요." ·
    "최고 34도까지 올라 더워요. 물을 자주 드세요." · "최저 -7도까지 내려가 추워요. 따뜻하게 입으세요."
    임계값은 **추측**이다 — 사용자 반응을 보고 바꾼다.
- **예보 4칸:** 다음 3시간 단위 정시부터 4칸(8:20이면 9·12·15·18시, 정각 12:00이면 12시부터). `icon`은 clear·partly·cloudy·rain·snow,
  `precip`이 참인 칸을 키오스크가 강조색으로 칠한다. 예보에 없는 시각은 건너뛴다(4칸보다 적을 수 있다).
- **weather_source:** `kma`(실제) · `mock`(리허설 고정 예보) · `none`(꺼짐·아직 못 받음). 받은 적은 있지만 오래됐으면 `kma` + `stale: true`.
- `SIMPLELAY_WEATHER_MODE=mock`은 네트워크 없이 "맑은 아침 → 오후 3~8시 비" 예보를 늘 돌려준다. 시연 리허설에서 비 안내 장면을 만들 때 쓴다.
  발표 때 화면에 "예보 출처: 연습용"을 따로 적을지는 키오스크 작업에서 정한다(`weather_source`로 구분 가능).

### 2-4. 기상청 키 받기와 설정 (사용자가 할 일)

1. [공공데이터포털](https://www.data.go.kr)에 로그인하고 **"기상청_단기예보 ((구)_동네예보) 조회서비스"**를 검색한다
   (서비스 이름 `VilageFcstInfoService_2.0`).
2. **활용신청**을 누르고 활용 목적(예: "경진대회 스마트홈 허브 날씨 안내")을 적어 신청한다. 개발계정은 보통 자동 승인되며 하루 10,000건까지다
   (우리 사용량은 하루 수십 건 이하).
3. 마이페이지 → 데이터활용 → Open API → 활용신청 현황 → 이 서비스를 열면 **일반 인증키 (Encoding)** 과 **일반 인증키 (Decoding)** 이 보인다.
   **Decoding 키를 쓴다**(서버가 한 번 URL 인코딩한다). Encoding 키(`%2B`·`%2F`·`%3D`가 섞인 것)를 넣어도 `%`가 있으면 그대로 쓰므로 동작하지만,
   두 형태를 섞어 붙이지는 않는다.
4. 승인 직후 한 시간 안팎은 포털에 키가 퍼지지 않아 `SERVICE_KEY_IS_NOT_REGISTERED_ERROR`(코드 30)가 날 수 있다. 서버 로그의
   `weather fetch failed: kind=api code=30`이 그것이다. 기다렸다가 다시 본다.
5. 격자는 둘 중 하나로 준다.
   - 위경도: `SIMPLELAY_WEATHER_LAT=37.5665`, `SIMPLELAY_WEATHER_LON=126.9780` → 서버가 (60, 127)로 바꾼다.
   - 격자 직접: `SIMPLELAY_WEATHER_NX=60`, `SIMPLELAY_WEATHER_NY=127`(활용가이드 첨부 엑셀의 행정구역별 격자). 둘 다 있으면 NX/NY가 우선이다.
6. RPi5에서는 `/etc/simplelay/environment`(systemd `EnvironmentFile`, 저장소 밖)에 적는다. **키를 저장소·채팅·로그에 넣지 않는다.**

   ```
   SIMPLELAY_WEATHER_MODE=real
   SIMPLELAY_KMA_SERVICE_KEY=<Decoding 키>
   SIMPLELAY_WEATHER_LAT=37.5665
   SIMPLELAY_WEATHER_LON=126.9780
   ```

   개발 PC(PowerShell)에서는 `$env:SIMPLELAY_WEATHER_MODE='real'; $env:SIMPLELAY_KMA_SERVICE_KEY='<Decoding 키>'` 후 서버를 켜고
   `curl http://127.0.0.1:8000/ambient`로 `weather_source: "kma"`와 `hourly` 4칸을 확인한다.

### 2-5. 환경 변수 전체

| 변수 | 뜻 | 기본 |
|---|---|---|
| `SIMPLELAY_WEATHER_MODE` | off · mock · real | off |
| `SIMPLELAY_KMA_SERVICE_KEY` | 일반 인증키(Decoding 권장) | 없음 → real이어도 off |
| `SIMPLELAY_WEATHER_NX` / `_NY` | 격자 | 없음 |
| `SIMPLELAY_WEATHER_LAT` / `_LON` | 위경도(NX/NY 없을 때) | 없음 |
| `SIMPLELAY_WEATHER_STALE_HOURS` | 이보다 오래된 예보는 쓰지 않음 | 6 |
| `SIMPLELAY_WEATHER_RETRY_MINUTES` | 실패 뒤 재시도 간격 | 10 |
| `SIMPLELAY_WEATHER_TIMEOUT_SECONDS` | 요청 상한 | 5 |
| `SIMPLELAY_WEATHER_HEAT_C` / `_COLD_C` | 더위·추위 안내 기준(℃) | 33 / -5 |
| `SIMPLELAY_WEATHER_RAIN_POP` | 강수형태 없이도 비로 볼 강수확률(%) | 60 |
| `SIMPLELAY_WEATHER_TIP_HOURS` | 안내가 살펴볼 앞 시간 | 12 |

## 3. 연결 상태 요약 — `GET /connections`

키오스크 오른쪽 위 아이콘 세 개용. 항목마다 `{id, state, title, message, fixes[], source}`이고 `state`는 ok · warn · error · not_installed · unknown.
`title`·`message`·`fixes`는 화면에 그대로 쓴다(UI 확정 §1-5: 부품 이름 대신 사용자 말, 무엇을 못 하게 되는지와 해결 방법).
`source`는 개발·시연 확인용(real · mock · none · sysfs · server)이라 화면 문구로 쓰지 않는다. 테스트가 모든 문구에 부품·개발 용어
(RPi·ESP·UART·노드·모듈·mock 등)가 없고 해요체로 끝나는지 확인한다.

| id | 판정 | 예 |
|---|---|---|
| `network` (와이파이) | 이 응답을 받았다는 것 자체가 화면↔허브 연결의 근거라 기본 ok. 리눅스면 `/sys/class/net/*/operstate`로 루프백 밖 인터페이스가 하나도 up이 아니면 error. 날씨 real 모드에서 마지막 받기가 네트워크 실패면 warn | warn: "인터넷 연결이 불안정해요" · "허브가 인터넷에 닿지 못하고 있어요. 날씨 안내가 보이지 않을 수 있어요. 집 안에서 가전을 누르는 일은 그대로 할 수 있어요." |
| `press` (누름 장치) | `SIMPLELAY_ACT_MODE=uart`일 때만 실제 장치. 통신 프레임 탭(`link_tap`)에서 마지막 실행 명령 뒤 90초(추측) 넘게 답이 없으면 error, 마지막 받은 줄이 오류면 warn, 켠 뒤 주고받은 적이 없으면 unknown. 그 밖의 모드는 연습용 ok(`source: mock`) | error: "누름 장치가 답하지 않아요" · "허브가 보낸 명령에 누름 장치가 답하지 않았어요. 지금은 버튼을 대신 눌러 드릴 수 없어요." |
| `plug` (플러그) | 실물 플러그(ESP32 콘센트 모듈)가 아직 없다. `SIMPLELAY_L3_MODE` off(기본) → not_installed, mock → 연습용 ok, real → unknown. 연결 약함·끊김 문구(`plug_item(link="weak"/"lost")`)는 만들어 두었고 플러그 신호가 생기면 넘긴다 | warn: "플러그 연결이 약해요" · "가전이 끝났는지 알려 주는 플러그와 연결이 약해요. 끝났다는 알림이 늦거나 오지 않을 수 있어요." |

- 모달의 "다시 연결하기"는 지금은 `/connections`를 다시 부르는 것으로 충분하다(서버에 따로 재연결 동작은 없다).
- **한계:** 모션 제어기(Arduino) 준비 신호는 아직 RPi4→RPi5 프레임에 없다. 생기면 `press` 판정에 더한다. 누름 장치 판정은 실기기에서 확인하지 않았다.

## 4. 인증과 배선

- 두 경로는 새 파일 `rpi/api/ambient_router.py`에 있고 `rpi/main.py`가 다른 읽기 경로와 같은 `require_api_key`로 붙인다 —
  키오스크(루프백)는 키 없이, LAN은 `X-API-Key`가 필요하다(테스트 `test_routes_require_key_on_lan`).
- 공유 파일(`router.py`·`deps.py`·`main.py`) 수정은 각각 몇 줄이다. 응답 모델은 `schemas.py` 대신 새 라우터 파일에 두었다.

## 5. 검증

- 새 테스트: `test_builtin_visibility.py` · `test_weather_kma.py` · `test_weather_service.py` · `test_ambient_builder.py` ·
  `test_connections.py` · `test_ambient_api.py`. 응답 픽스처는 `rpi/tests/fixtures/kma/`(정상 08시 발표 15시간치, 결과 코드 03·10, 게이트웨이 XML 30).
- 실패 확인: 키 이중 인코딩 방지를 끄면 키 테스트가, 10분 지연을 0으로 바꾸면 발표 시각 테스트 2건이, 안내 우선순위를 뒤집으면 우선순위 테스트가 실패함을 확인했다.
- 실제 기상청 호출·RPi5 sysfs·UART 누름 장치로는 확인하지 않았다.

## 6. 다음

- 키오스크(Flutter): `/ambient`를 몇 분 간격으로, `/connections`를 30초 안팎 간격으로 부르고 §3-1대로 그린다(다른 기기).
- 사용자: 기상청 키를 받아 §2-4대로 넣고 한 번 확인한다.
- 플러그(ESP32) 연결 신호가 생기면 `plug_item(link=…)`에 넘긴다.
