# 2026-10-13 — ThinQ 공식 SDK 연결 · 모의 클라우드 끝-끝 시험 (데스크톱)

컨설팅 의견("하드웨어 버튼뿐 아니라 소프트웨어적 가전 제어도 포함, 상황 시나리오 공조")에 맞춰, 9/29까지
**SDK 모양만 본뜬 모의**였던 ThinQ 경로를 **공식 SDK를 실제로 부르는 코드**로 바꿨다. 목표는 "가전만
붙이면 되는 상태"와 그 증명이다.

> **검증 수준: 공식 SDK 연결·모의 클라우드 끝-끝 시험, 실제 클라우드·실가전 미검증.**
> SDK가 만든 요청은 저장소 안 모의 ThinQ 클라우드(127.0.0.1)로만 갔다. 구매 예정 공기청정기
> **LG AS186HWWA**(2026년형, 공식 페이지에서 ThinQ(Wi-Fi) 지원 확인)의 **프로필은 미확인**이다.
> 실물 날 순서는 [ThinQ 실물 확인 절차](../ThinQ-실물-확인-절차.md).
>
> **범위(작업 중 조정):** 공기청정기 한 대의 흐름(목록 → 프로필 → 상태 → 승인 후 제어 1회 → 상태 재조회 → 기록)을
> 실제 SDK·모의 클라우드로 끝까지 검증하는 데 집중했다. 세탁기(시작·일시정지·원격 시작 꺼짐 거절)는 조정 전에 이미
> 넣은 만큼만 두고 더 넓히지 않았다. 제습기는 기존 전원 동작 그대로다.

## 1. 커밋

| 커밋 | 내용 |
|---|---|
| `13e0d6b` | 선택 의존성 `thinq = ["thinqconnect==1.0.14"]`(HA core lg_thinq와 같은 고정), 프로필 판정기(`profile.py`), 오류 코드 → 종류·사람 말 이유(`errors.py`), 공개 형식 샘플 프로필(`profiles_sample.py`) |
| `10ac349` | `SdkThinqClient`(SDK 실제 호출), `fake_cloud`·`real` 모드와 기동 거절, PAT·클라이언트 ID 보관 규칙, 우리 쪽 호출 상한, 모의 클라우드 `rpi/tools/fake_thinq_cloud.py`, 실물 미구현 자리(`RealThinqClient`) 제거 |
| `51f1a3d` | 프로필 판정으로 실행 전 거절, 세탁기 시작·일시정지(원격 시작 조건), `/thinq/devices`의 `profile_allowed`, 끝-끝 시험 |
| `5cf85ed` | 공기청정기 연결 끊김·제어 거절 끝-끝 시험(모의 클라우드에 제어 거절 장애, 닫을 때 열린 연결까지 끊기) |
| (이 커밋) | `scripts/thinq_probe.py`, 실물 확인 절차, 이 기록, CLAUDE.md 한 줄 |

## 2. SDK 소스에서 확인한 것 (설치본 `thinqconnect` 1.0.14)

- `ThinQApi(session, access_token, country_code, client_id, mock_response=False)` — aiohttp 세션의
  `request(method=, url=, ...)`만 쓴다. 접속 주소는 `https://api-{지역}.lgthinq.com/{endpoint}`로 **고정**
  (기준 주소 설정 없음, `mock_response`는 HTTP 없이 고정 응답이라 시험에 못 씀).
- 머리글: `Authorization: Bearer <PAT>`, `x-country`, `x-message-id`(요청마다), `x-client-id`, `x-api-key`(SDK 상수),
  `x-service-phase: OP`. 제어에는 `x-conditional-control: true`.
- 경로: `GET devices` · `GET devices/{id}/profile` · `GET devices/{id}/state` · `POST devices/{id}/control`(JSON 그대로).
  성공이면 응답의 `response`만, 실패면 `ThinQAPIException(code, message, headers)` — **이 예외는 요청 머리글(PAT)을
  속성으로 든다.** 우리는 코드·이름만 꺼내 우리 오류로 바꾸고 원인 연결을 끊는다(시험으로 확인).
- 기기 목록 항목: `deviceId` + `deviceInfo{deviceType, modelName, alias, reportable}`. **온라인 여부는 없다** →
  준비 상태는 상태 조회(15초 캐시)로 본다.
- 프로필: `property.<resource>.<prop>.{type, mode[r/w], value{r,w}}`, 세탁기는 위치별 목록(`location.locationName`).
  공기청정기 풍량은 프로필에 `windStrengthDetail`이 있으면 그 키가 우선(SDK `_get_preferred_property_key`).
  세탁기 `operation.washerOperationMode`는 쓰기 전용이고 제어 본문에 `location`을 싣는다(`WasherSubDevice`).
- 오류 코드(`ThinQAPIErrorCodes`): `INVALID_TOKEN 1103`·`NOT_ACCEPTABLE_TERMS 1304`·`EXCEEDED_API_CALLS 1306`·
  `NOT_SUPPORTED_COUNTRY 1307`·`NOT_ALLOWED_API_AGAIN 1309`·`NOT_CONNECTED_DEVICE 1222`·
  `COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF 2301` 등. 우리 표는 SDK가 있으면 시험이 열거형과 대조한다.

## 3. 무엇이 바뀌었나

| 부분 | 지금 |
|---|---|
| 모드 | `SIMPLELAY_THINQ_MODE` = off · mock(프로세스 안 모의) · **fake_cloud**(SDK → 모의 클라우드, 실행 환경 mock, 이름에 '(모의 클라우드)') · **real**(SDK → 실제 클라우드). real은 주소를 바꿀 수 없다 |
| 기동 거절 | real·fake_cloud에서 SDK 없음·PAT 없음·모의 주소가 127.0.0.1이 아님 → uvicorn 기동(lifespan)에서 거절 |
| 비밀 | PAT는 `SIMPLELAY_THINQ_PAT` 또는 저장소 밖 `SIMPLELAY_THINQ_PAT_FILE`. 클라이언트 ID(UUID4)는 저장소 밖 파일에 한 번 만들어 계속 사용. 저장소 안 경로는 거절. 모의 클라우드에는 실제 PAT를 보내지 않는다 |
| 호출 | 전용 이벤트 루프 스레드에서 SDK 코루틴 실행. 분당 30회(추측) 넘으면 보내지 않음. 목록·상태 15초 캐시(준비 판정용), 프로필은 기기마다 한 번 |
| 오류 | 사람 말 이유로: 토큰·약관·권한·국가·호출 한도·원격 꺼짐·미지원 → 거절(실행 안 됨), 기기 미연결 → 보내지 않음, 서버 내부 오류·응답 지연·모르는 코드 → **접수 불명**(재전송 없음) |
| 실행 전 판정 | 기기 프로필에 그 속성이 있고, 쓰기 모드이고, 값이 쓰기 목록에 있을 때만 보낸다. 아니면 failed / not_dispatched + 이유 |
| 세탁기(범위 밖, 이미 넣은 만큼) | `set_operation` START·STOP(일시정지, 실물 의미 미확인). 원격 제어 꺼짐이면 보내지 않음·준비 상태 needs_setup. 확인은 `runState.currentState`(시작 = 진행 상태들, 일시정지 = PAUSE — 값 목록은 추측) |
| 공기청정기 | 전원·풍량·운전 모드(기존 표). 이 모델이 무엇을 허용하는지는 프로필이 정한다 |
| 계약 | U1-a 승인 결속·확인 수준·자동 재전송 없음은 그대로. 실제 클라우드 성공(`real`)은 real 모드에서만 |

모의 클라우드(`rpi/tools/fake_thinq_cloud.py`)의 범위: 기기 3대(공기청정기·제습기·세탁기, 가짜 ID), 목록·프로필·상태·제어,
프로필 기반 제어 검사, 세탁기 원격 제어 스위치(기본 꺼짐), 장애 주입(토큰·약관·권한·국가·호출 한도·내부 오류·기기
미연결·제어 거절·응답 유실·접수 후 상태 고정, 닫으면 열린 연결까지 끊음), 받은 요청 기록(경로·머리글 **이름**·본문, 토큰 값은 일치 여부만). 이벤트(MQTT)·에너지·
등록/구독 API는 흉내 내지 않는다.

## 4. 검증

- 새 시험 **74건**: 프로필·오류 표 20(SDK 판정·열거형 대조 2건 포함), SDK 클라이언트·설정·조립 26, 실행 전 판정 11(SDK 없이),
  끝-끝 11, 확인 스크립트 6.
- 공기청정기 기준 정직한 표시(끝-끝): 승인 카드 → SDK 제어 → 상태 재조회 → 기록(`succeeded/accepted/state_confirmed`, 실행 환경 mock) ·
  **연결 끊김**(모의 클라우드를 닫음 → 준비 판정 412 또는 보내기 전 조회 실패로 `failed/not_dispatched`, 성공 없음) ·
  **제어 실패**(클라우드 거절 → `failed/accepted`, 이유·코드, 상태 그대로) · **응답 유실**(`unconfirmed/unknown`, 재전송 없음, 재조회로만 보임) ·
  **접수 후 상태 미확인**(`unconfirmed/accepted/none`) · 토큰 오류·호출 초과(412 + 이유) · 프로필 밖 값(보내기 전 거절). 기존 시험 수정 3곳: real '실물 미구현' 시험 → SDK 없으면 기동 거절, 세탁기 읽기 전용 →
  시작·일시정지만, real 모드 장애 주입 409 시험에 PAT·클라이언트 ID 파일·fake_cloud 추가.
- **수정 전 실패 확인:** 단계마다 새 시험을 먼저 돌려 실패(모듈 없음·속성 없음)를 봤고, 단계 3은 실행기 변경만 되돌려
  판정·세탁기·끝-끝 시험 15건이 실패하는 것을, lifespan 기동 거절은 `main.py` 변경만 되돌려 실패하는 것을 확인했다.
- 백엔드+rpi4 전체: SDK 설치 **2,797 통과·12 건너뜀**, SDK를 막은 상태(설치 안 된 것과 같게) **2,753 통과·41 건너뜀** — 기본 설치에서도
  실패 없음. repo guard 통과.
- 실제 ThinQ 클라우드 호출 **0건**, 실가전 **0대**.

## 5. 남은 것 (실물 날)

1. PAT 발급(사용자 직접) → 저장소 밖 파일 → `scripts/thinq_probe.py`로 목록·프로필·상태(읽기 전용).
2. AS186HWWA 프로필로 동작 표 확인 — 풍량 키(`windStrength`/`windStrengthDetail`)·값 이름·운전 모드 값. 다르면 표 후보만 고친다.
3. 승인 뒤 제어 1회 → 상태 재조회 → 증거 대장. 서버 real 모드로 같은 것 1회.
4. 확인 대기 상한(3초)·조회 간격(0.5초)·분당 상한(30회)은 추측 — 실측으로 조정.
5. 앱·키오스크 화면은 바꾸지 않았다(가전 이름의 '(모의 클라우드)'로 구분).
6. 세탁기·제습기 실물 확인과 확장(세탁기 원격 시작의 실제 동작·`STOP` 의미, 제습기 프로필)은 남은 일 — 이번에는 넓히지 않았다.
