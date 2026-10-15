# ThinQ 실물 확인 절차 (공기청정기가 도착한 날)

**범위: 공기청정기 한 대.** 세탁기·제습기는 이 절차에 넣지 않는다(코드에 모의까지만 있다).

> **지금 수준(2026-10-15):** 공기청정기 **LG AS186HWWA**로 실제 클라우드 **A~E 통과**(허브는 노트북, 집 Wi-Fi) —
> [10/15 기록](devlog/devlog_2026-10-15-thinq-real.md). 프로필: 전원 `POWER_ON/OFF`, 풍량 `windStrengthDetail`
> `LOW/MID/HIGH/AUTO`, 운전 모드 `CLEAN/SLEEP/AUTO`(`SILENT` 없음 → 실행 전 거절). **꺼져 있을 때 `airQualitySensor`는 ThinQ 앱의
> 공기질 센서 설정에 달렸다** — '운전 중에만'이면 비어 오고, **'항상'이면 꺼진 채로도 값이 온다**(§4-4, 10/15 저녁 읽기 전용 조회로 확인).
> 남은 것: §5-1 이미 목표값 실물, RPi5 허브에서 real 모드(보드 인터넷 연결 뒤), 대회장 인터넷 조건.
> 서버는 프로필이 허용하지 않는 동작·값을 **보내기 전에 거절**한다.

순서: **기기 목록 → 프로필 → 상태 조회 → (승인) 제어 1회 → 상태 재조회 → 기록**, 그 뒤 서버에서
**발견 → 사용자 확인 후 추가**(§4-3).
모든 원본 응답은 **저장소 밖**에만 둔다. 실제 기기 ID·PAT는 저장소·채팅·커밋·문서에 넣지 않는다.

## 0. 준비

| 항목 | 내용 |
|---|---|
| 가전 | AS186HWWA를 ThinQ 앱에 등록하고, **앱에서** 전원·풍량이 바뀌는지 먼저 본다(앱이 안 되면 API도 안 된다) |
| 계정 | 가전을 등록한 ThinQ 계정 = PAT를 발급할 계정(다르면 `NOT_OWNED_DEVICE`·`NO_CONTROL_AUTHORITY`) |
| 백엔드 | 리포 `.venv`에 `pip install -e ".[thinq]"` (공식 SDK 1.0.14, 기본 설치에는 없다) |
| 인터넷 | 실제 클라우드(`api-<지역>.lgthinq.com`)에 나가는 회선 |

## 1. PAT 발급 — 사용자가 직접

1. ThinQ Connect 개발자 사이트의 **PAT(Personal Access Token)** 페이지에 가전을 등록한 계정으로 로그인한다.
2. 토큰을 만든다. 권한(범위)은 **기기 목록·상태 조회·기기 제어**가 포함되게 고른다.
   (사이트 화면 문구는 이 저장소에서 확인하지 못했다 — 9/22 조사 때 본문 접속 실패. 화면대로 따른다.)
3. 토큰 값은 **채팅·코드·명령줄·커밋·스크린샷에 넣지 않는다.** 바로 아래 파일에만 붙여 넣는다.

## 2. 저장소 밖 보관

| 무엇 | 위치(예) | 설정 |
|---|---|---|
| PAT | Windows `%USERPROFILE%\.simplelay\thinq_pat` · RPi5 허브 `/mnt/rawdata/simplelay/thinq/thinq_pat`(데이터 폴더, `chmod 600`) | Windows: `SIMPLELAY_THINQ_PAT_FILE=<그 경로>` · RPi5: `deploy/run_backend.sh`가 파일이 있으면 컨테이너 `/data/thinq/thinq_pat`로 넘긴다(10/15) |
| 클라이언트 ID | Windows `~/.simplelay/thinq_client_id` · RPi5 `/mnt/rawdata/simplelay/thinq/thinq_client_id` — 처음 실행 때 UUID4를 **한 번** 만들어 계속 쓴다 | RPi5는 `run_backend.sh`가 데이터 폴더 경로를 넘겨 컨테이너를 다시 만들어도 남는다(설치마다 하나, 지우지 않는다) |
| SDK | RPi5 백엔드 이미지에 `thinqconnect==1.0.14` 포함(`deploy/backend.Dockerfile`, 10/15) — 이 날짜 전 이미지는 다시 빌드해야 한다 | RPi5 env 파일에 `SIMPLELAY_THINQ_MODE=real`, `SIMPLELAY_THINQ_COUNTRY=KR` |
| 국가 | 계정 국가 | `SIMPLELAY_THINQ_COUNTRY=KR` |
| 원본 응답 | `~/.simplelay/thinq_probe/<시각>/` (스크립트 기본) | `--out`으로 바꿀 수 있지만 저장소 안은 거절 |

저장소 안 경로를 PAT·클라이언트 ID·원본 저장 위치로 주면 서버와 스크립트가 **거절**한다.

## 3. 연습(가전 없이, 언제든)

```powershell
# 창 1 — 모의 ThinQ 클라우드(실제 아님, 127.0.0.1만)
.\.venv\Scripts\python.exe -m rpi.tools.fake_thinq_cloud --port 8790
# 창 2 — 같은 스크립트를 모의 클라우드로
.\.venv\Scripts\python.exe scripts\thinq_probe.py --fake-cloud http://127.0.0.1:8790
.\.venv\Scripts\python.exe scripts\thinq_probe.py --fake-cloud http://127.0.0.1:8790 --control air_purifier set_wind_strength HIGH
```

모의 클라우드 결과는 실행 환경 `mock`, 가전 이름 `(모의 클라우드)`다. 이것을 실물 확인으로 적지 않는다.

## 4. 실물 확인

### 4-1. 기기 목록 · 프로필 · 상태 (읽기 전용)

```powershell
$env:SIMPLELAY_THINQ_PAT_FILE = "$env:USERPROFILE\.simplelay\thinq_pat"
$env:SIMPLELAY_THINQ_COUNTRY = "KR"
.\.venv\Scripts\python.exe scripts\thinq_probe.py
```

- 화면에는 기기 종류·모델명·별칭과 ID **끝 4자**만 나온다. 원본(`devices.json`, `<n>_<종류>_profile.json`,
  `<n>_<종류>_state.json`)과 환경 변수 후보(`env.txt`, 전체 기기 ID)는 저장소 밖 폴더에만 쓴다.
- **공기청정기 등록 확인:** `DEVICE_AIR_PURIFIER` 한 대가 보이고 모델명이 AS186HWWA 계열인지 본다.
- **프로필 판정 표:** 각 동작(`set_power`·`set_wind_strength`·`set_job_mode`)마다 "허용 [...]" 또는
  "프로필에 쓰기 속성 없음 → 실행 전 거절"이 찍힌다. 이 표가 이 모델에서 쓸 수 있는 동작의 근거다.

### 4-2. 승인 후 제어 1회 → 상태 재조회

```powershell
.\.venv\Scripts\python.exe scripts\thinq_probe.py --control air_purifier set_wind_strength HIGH
```

- 확인 질문에 `yes`라고 쳐야만 **한 번** 보낸다. 다른 답이면 보내지 않는다. 자동 재전송은 없다.
- 4-1의 판정 표에서 허용된 값만 고른다(허용되지 않은 값은 스크립트가 보내기 전에 거절한다).
- 결과는 `status / receipt / confirmation` 세 칸을 **함께** 읽는다(스크립트가 한 줄로 출력하고 `control.json`에 남긴다).
  `succeeded / accepted / state_confirmed`면 상태 재조회로 변경을 본 것이다. `succeeded / not_dispatched / already_at_target`은
  이미 그 값이라 **보내지 않은 것**이고(§5-1), `succeeded / accepted / state_confirmed_unknown_before`는 보내기 전 값을 못 읽어
  '바꿨다'고 말할 수 없는 확인이다 — D 판정에는 약풍에서 시작해 `state_confirmed`를 받는다. `unconfirmed`는 둘로 나뉜다 —
  `accepted / none`은 **접수 확인, 결과 미확인**, `unknown / none`은 **접수 여부 미확인**(보내는 중 끊김·응답 유실).
  어느 쪽이든 **다시 보내지 말고** 앱·본체로 확인한 뒤 4-1을 다시 돌려 상태를 본다.
- 결과와 재조회 상태는 `control.json`(저장소 밖)에 남는다.

### 4-3. 서버 real 모드 — 발견 → 추가 (선택, 4-2가 된 뒤)

기기 ID를 손으로 적지 않는다. 서버를 real 모드로 띄우고 **앱에서 찾은 가전을 사용자가 추가**한다
(2026-10-13, 모의 클라우드까지만 검증 — 실제 클라우드로는 이날이 처음이다).

```powershell
$env:SIMPLELAY_THINQ_MODE = "real"
$env:SIMPLELAY_THINQ_PAT_FILE = "$env:USERPROFILE\.simplelay\thinq_pat"
$env:SIMPLELAY_DB_PATH = "<저장소 밖 경로>\simplelay.db"   # 추가한 가전이 재시작 뒤에도 남는다
# SIMPLELAY_THINQ_DEVICE_AIR_PURIFIER는 두지 않는다(둘 다 있으면 환경 변수가 먼저, 중복은 생기지 않는다)
```

1. **발견:** 앱 설정 → **LG ThinQ 연결** → **ThinQ에서 찾은 가전**. 공기청정기가 별칭·모델명과 함께 보이고
   "제어할 수 있어요 — 전원 · 풍량 · …"(이 모델 프로필이 허용하는 동작만)인지 본다. 서버로 직접 보려면
   `GET /thinq/discovered`(기기 ID 대신 `key`를 준다).
   - "가전을 찾지 못했어요 — …"가 나오면 그 이유(토큰·약관·국가·연결)를 §6 표로 푼다. 이것은 '0대'가 아니다.
   - "상태만 볼 수 있어요"·"지원하지 않아요"면 추가 버튼이 없다 — 이 모델 프로필로는 제어하지 않는다.
2. **추가:** 공기청정기 줄의 **추가**를 누른다(서버로는 `POST /thinq/added {"key": …}`). 사용자가 누르기 전에는
   아무것도 등록되지 않는다. 추가하면 홈에 'ThinQ' 배지 타일이 생기고 루틴 대상 목록에도 나온다.
   기기 ID는 서버 DB에만 남는다(화면·로그·저장소에 없음).
3. **확인:** `GET /readiness/air_purifier`가 `can_execute: true`인지, 승인 카드나 `POST /thinq/command` 1회 뒤
   `/status`가 `last_execution_mode: real`·`last_confirmation: state_confirmed`인지 본다. 추가해도 실행은
   언제나 승인(확인)을 거친다.
4. 잘못 추가했으면 같은 줄의 **빼기**(`DELETE /thinq/added/{key}`). 환경 변수로 넣은 가전은 여기서 빼지 않는다.

SDK·PAT가 없으면 서버가 **기동을 거절**한다. 실제 클라우드 성공 판정은 이 모드에서만 나온다(모의 클라우드는
언제나 `mock`, 화면에 '(모의 클라우드)'). 가전 도착 전 연습은 §3의 모의 클라우드로 서버를
`SIMPLELAY_THINQ_MODE=fake_cloud`·`SIMPLELAY_THINQ_FAKE_CLOUD_URL=http://127.0.0.1:8790`(기기 ID 환경 변수 없이)로
띄워 같은 순서를 밟는다.

### 4-4. 꺼진 채 공기질 값 (2026-10-15 저녁 — ThinQ 앱 공기질 센서 설정)

허브의 공기질 제안은 공기청정기가 **꺼져 있을 때** 나쁨이면 '공기청정기를 켤까요?'(전원 켜기 한 단계), 켜져 있을 때 나쁨이면
'공기청정기를 강풍으로 바꿀까요?'를 묻는다. 꺼진 쪽은 **센서 값이 꺼진 채로 올 때만** 동작한다.

| ThinQ 앱 공기질 센서 설정 | 꺼져 있을 때 상태 조회 | 허브 |
|---|---|---|
| 운전 중에만 | `airQualitySensor` 비어 옴 | 값 없음 → 제안 없음, 폰 상태 카드는 '항상'으로 바꾸는 방법을 알려 줌 |
| **항상** | PM1·PM2·PM10 값·등급, 종합 등급이 옴 | 나쁨이면 켜기 제안 |

- **확인한 것(10/15 저녁, 읽기 전용):** 설정을 '항상'으로 바꾼 뒤 §4-1 조회에서 전원 `POWER_OFF`·풍량 `AUTO`인 채
  `PM2` 8 · `GOOD`, `PM10` 10이 왔다. 원본은 저장소 밖.
- **아직 안 한 것:** 실제 공기청정기가 꺼진 채 나쁨일 때 켜기 카드가 뜨는 것, 그 카드를 승인해 실제로 켜지는 것(`state_confirmed`).
  나쁨 등급을 실물에서 아직 보지 못했다.
- 꺼진 공기청정기는 전원 밖의 명령(풍량 등)을 클라우드가 거절한다(`COMMAND_NOT_SUPPORTED_IN_POWER_OFF` 2304) — 그래서 꺼진 쪽 제안은
  풍량을 넣지 않고 켜기만 묻는다.
- 연습: 모의(mock)는 `SIMPLELAY_THINQ_MOCK_AIR_SENSOR_ALWAYS=1`, 모의 클라우드는 `--air-sensor-always`로 '항상'을 흉내 낸다(기본은 '운전 중에만').

## 5. 합격 기준

| # | 기준 | 증거(저장소 밖) |
|---|---|---|
| A | 실제 클라우드 인증·기기 목록 조회 성공, 공기청정기 1대 보임 | `devices.json`, 화면 |
| B | 공기청정기 프로필 조회 성공, 동작별 판정 표 확보 | `*_profile.json`, `summary.txt` |
| C | 상태 조회 성공 | `*_state.json` |
| D | 허용된 동작 1개를 승인 뒤 1회 보내고, 상태 재조회로 변경 확인(`state_confirmed`) | `control.json` |
| E | (선택) 서버 real 모드에서 **발견 목록에 공기청정기가 '제어할 수 있어요'로 보이고, 추가 뒤** 같은 동작이 `real`·`state_confirmed`로 기록 | 앱 'ThinQ에서 찾은 가전'·`/status`·`/history` 화면 |
| F | `git status`에 PAT·원본·기기 ID가 없음 | `git status`, `git grep <ID 끝자리>` 결과 없음 |

D가 `unconfirmed`면 실패도 합격도 아니다 — `status`만 적지 말고 `receipt`·`confirmation`을 함께 적어 구별한다(3차 평가 L2):

| status / receipt / confirmation | 기록 문장 |
|---|---|
| `unconfirmed / accepted / none` | 접수 확인, 결과 미확인(확인 상한 안에 상태가 안 바뀜, 또는 정지로 확인을 멈춤). 보내기 전부터 같은 값이면 10/14부터는 보내지 않고 `already_at_target`(§5-1) |
| `unconfirmed / unknown / none` | 접수 여부 미확인(전송 중 끊김·응답 유실 — 클라우드가 받았는지 모른다) |

어느 쪽이든 재전송하지 않는다. `unknown`을 '접수됨'으로 적지 않는다.

### 5-1. '이미 목표값' 확인 (2026-10-14 — 서버 real 모드, D·E가 된 뒤)

반복 시연에서 흔한 경우다. 공기청정기가 **이미 강풍인 채로** 같은 강풍 명령(승인 카드 또는 자동 실행)을 한 번 더 낸다.

| 확인 | 기대 |
|---|---|
| `/status` | `last_outcome: success`·`last_receipt: not_dispatched`·`last_confirmation: already_at_target`·`last_execution_mode: real` |
| 문장 | "이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요." — '바꿨어요'·'확인하지 못했어요'가 아니다 |
| 제어 요청 | **0회** — 서버 로그에 그 시각 ThinQ 제어 호출이 없다(상태 조회만). LG ThinQ 앱 기록에도 제어가 없다 |
| `/history` | 맨 위 줄 `dispatch: state_only` |
| 폰·키오스크 | 폰 실행 상태·기록: 성공, '이미 그 설정이라 보내지 않음'. 키오스크 자동 실행 한 줄: "공기청정기는 이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요" |

이어서 앱·본체로 **약풍**으로 바꾼 뒤 같은 강풍 명령 → `state_confirmed`·"강풍으로 바꿨어요."·제어 1회인지 본다.

**'제어 0회'의 증거는 따로 남긴다.** 가전이 움직이지 않았다는 관찰만으로는 요청이 없었다는 증명이 안 된다. 그 시각의 ThinQ 호출 기록에서 **제어 호출 수와 상태 조회 결과**를 함께 적는다(기기 ID·토큰은 가리고, 원본은 저장소 밖). 사전 조회 실패 경우를 시험했다면 장애 주입으로 만든 것인지 표시한다. '명령 보냄'(`dispatch: sent`)은 클라우드의 **정상 접수 응답**(`receipt: accepted`)을 받았다는 뜻이다. 보냈지만 응답이 끊겼으면 `dispatch: unknown`(`receipt: unknown`) — 전달됐는지 모른다. 어느 쪽도 **가전이 수행했다는 뜻이 아니다** — 수행은 재조회(`state_confirmed`)로만 말한다.

사전 조회 실패 뒤 보내는 것은 **읽는 중 끊김·응답 해석 실패**(`ThinqTransportError`)이거나 상태에 그 값이 없을 때뿐이다. 클라우드가 코드로 거절한 조회(인증·권한·약관·국가·호출 한도)는 보내지 않는다.
모의 클라우드에서는 같은 순서가 시험으로 고정돼 있다(`rpi/tests/test_thinq_already_at_target.py`) — 실제 클라우드·실가전 결과는 이날 처음이다.

## 6. 막혔을 때 (오류 → 이유)

| 클라우드 오류 | 화면 이유(요지) | 할 일 |
|---|---|---|
| `INVALID_TOKEN`·`NOT_FOUND_TOKEN` | 토큰이 유효하지 않음 | PAT 다시 발급 → 파일 교체 |
| `NOT_ACCEPTABLE_TERMS` | 약관 동의 필요 | ThinQ 앱에서 약관 동의 |
| `NOT_ALLOWED_API(_AGAIN)` | 이 토큰으로 쓸 수 없는 API | PAT 권한(범위) 확인 |
| `NOT_SUPPORTED_COUNTRY` | 국가 코드 불일치 | `SIMPLELAY_THINQ_COUNTRY`를 계정 국가로 |
| `EXCEEDED_API_CALLS` | 호출 한도 초과 | 잠시 쉬고 다시(자동 재시도 없음). 우리 쪽 상한은 분당 30회 |
| `NOT_CONNECTED_DEVICE` | 가전이 클라우드에 연결 안 됨 | 전원·Wi-Fi·앱에서 온라인 확인 |
| `COMMAND_NOT_SUPPORTED_IN_REMOTE_OFF` | 원격 제어 꺼짐 | 가전 본체에서 원격 제어 켜기 |
| `NOT_PROVIDED_FEATURE` 등 | 모델이 그 기능 미지원 | 4-1 판정 표에서 허용된 동작만 |

## 7. 증거 대장 문장 예 (그날 실제로 된 것만)

- "2026-MM-DD 실제 ThinQ 클라우드 인증·기기 목록 조회 성공(공기청정기 1대, 모델명 확인)."
- "실제 클라우드에서 공기청정기 프로필·상태 조회 성공 — 원본은 저장소 밖 보관, 동작별 지원 표 작성."
- "승인 후 풍량 변경 명령 1회 전송, 상태 재조회로 변경 확인(state_confirmed)."
- (안 된 것) "운전 모드 변경은 이 모델 프로필에 쓰기 값이 없어 실행 전 거절됨."

쓰지 않을 문장: 모의 클라우드 결과를 "실제 제어 확인"으로, 접수만 된 결과를 "동작 확인"으로, 접수 여부 미확인(`unknown`)을 "접수됨"으로.

## 8. 그 뒤

- 프로필이 우리 표(`rpi/services/thinq/bindings.py`)와 다르면(예: `windStrengthDetail`·다른 값 이름) 표의
  후보 값만 일반 이름으로 고친다. 원본 프로필 파일은 커밋하지 않는다.
- 세탁기·제습기 실물 확인은 이 절차 범위 밖이다(세탁기 시작·일시정지와 원격 시작 꺼짐 거절은 모의 클라우드
  시험까지만 있다 — 남은 일).
