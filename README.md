# 🏠 SimpleLay: 사람과 가전 사이를 잇는 허브

> 부문: 스마트 가전<br/>팀명: 자비스<br/>개발기간: 2026.07 ~ 2026.11 (제24회 임베디드SW경진대회 결선, 2026.11.06 발표)

실제 사용 기록에서 습관을 알아채 먼저 묻고, 맡겨 주신 일만 알아서 하는 가정용 허브

<table>
<tr>
<td align="center"><b>누름 장치 (버튼식 전자레인지)</b></td>
<td align="center"><b>본체 키오스크 — 먼저 묻는 제안</b></td>
<td align="center"><b>폰 앱</b></td>
</tr>
<tr>
<td><img src="docs/submission/img/press-device-on-microwave-2026-11-04.jpg" alt="전자레인지 조작부 위에 붙인 CoreXY 누름 장치" width="260"></td>
<td><img src="docs/submission/img/kiosk-suggestion-real-2026-11-03.png" alt="본체 키오스크에 뜬 제안 카드: 공기청정기를 켜 둘까요?, 이유와 네·아니요 버튼" width="420"></td>
<td><img src="docs/submission/img/phone-home-real-2026-11-06.png" alt="SimpleLay 폰 앱 홈 화면 (실기기)" width="200"></td>
</tr>
</table>

[제출 시연 영상 보기 (3분 29초)](https://www.youtube.com/watch?v=duf_ZUxTOUo) · 더 많은 화면은 [제출 그림 모음](docs/submission/그림-대응표.md)

---

## 📌 프로젝트 개요 (Overview)

**SimpleLay**는 사용자가 매일 비슷한 시간에 하는 일을 기록에서 알아채고, 그 시간이 되기 전에 "지금 할까요?"라고 먼저 묻는 가정용 허브입니다. 사용자가 직접 맡겨 주신 일만 알아서 하고, 한 일은 결과로 알려 드립니다.

LG ThinQ 가전은 공식 API로 연결하고, 버튼만 있는 옛 가전은 조작부 위의 누름 장치와 콘센트 전류 센서(CT)로 같은 흐름에 넣습니다. 새 가전을 사지 않아도 지금 쓰는 가전부터 함께 쓸 수 있도록 하는 것이 목표입니다.

주요 특징:
- **습관을 알아챕니다** — 같은 시간대에 서로 다른 날 사흘 이상, 세 번 이상 직접 쓴 일을 습관으로 봅니다. 학습 모델이 아니라 설명할 수 있는 규칙이어서, 카드에 실제로 쓴 날짜를 근거로 함께 보여 드립니다.
- **알맞은 때에 먼저 묻습니다** — 사람이 있을 때 평소 시각 10분 전에 묻습니다. 실내외 공기, 날씨, 방 밝기 같은 상황을 함께 보고 제안하거나 조언만 드리기도 합니다.
- **맡겨 주신 일만 알아서 합니다** — '네'를 자주 눌러도 저절로 자동으로 바뀌지 않습니다. 언제, 무엇을 하는지 확인하고 직접 맡겨 주셔야 하며, 언제든 다시 끌 수 있습니다.
- **열이 나는 가전은 매번 확인합니다** — 전자레인지와 인덕션은 맡길 수 없고, 실행할 때마다 '네'를 받습니다. 폰과 키오스크에서 언제든 멈출 수 있습니다.
- **판단은 집 안 본체에서 합니다** — 말 알아듣기와 사람 감지는 본체 안에서 처리합니다. 카메라는 사람이 있는지 없는지만 보며, 사진은 저장하거나 보내지 않습니다.

## 🏗 시스템 아키텍처 (System Architecture)

```mermaid
flowchart LR
    phone["폰 앱"]
    subgraph rpi5["본체 (Raspberry Pi 5)"]
        hub["허브 서버<br/>습관 · 제안 · 승인 · 기록"]
        kiosk["15.8형 키오스크"]
        sense["사람 감지 · 말 알아듣기 · 온습도"]
    end
    subgraph rpi4b["실행기 (Raspberry Pi 4)"]
        act["실행 · 정지 · 결과 확인"]
    end
    motion["누름 장치<br/>ESP32 · CoreXY · SwitchBot Bot"]
    outlet["콘센트 모듈<br/>ESP32 · CT 센서"]
    appliance["버튼식 전자레인지"]
    thinq["LG ThinQ<br/>공기청정기"]

    phone -->|"승인 · 조작"| hub
    kiosk --> hub
    sense --> hub
    hub -->|"Wi-Fi · 인증된 연결"| act
    act -->|"USB"| motion
    act -->|"USB"| outlet
    motion -->|"버튼 누름"| appliance
    appliance -.->|"소비전력"| outlet
    hub -->|"공식 API"| thinq
```

본체는 사용자가 승인한 명령과 같은지 확인한 뒤에만 실행기로 보냅니다. 정지는 다른 작업과 따로 다니는 전용 경로로 보내고, 실행기는 본체와 연결이 끊기면 스스로 멈춥니다. 더 자세한 내용은 [아키텍처](docs/architecture.md), [장치 간 규약](docs/protocol.md), [본체와 클라우드의 판단 경계](docs/inference-boundary.md)에 정리했습니다.

---

## 📡 하드웨어 구성 (Hardware)

| 구성 요소 | 모델 / 사양 | 역할 |
| --- | --- | --- |
| 본체 | Raspberry Pi 5 + 15.8형 터치 패널 | 허브 서버와 키오스크, 사람 감지와 말 알아듣기 |
| 실행기 | Raspberry Pi 4 (본체와 Wi-Fi, 인증 키) | 버튼 누르기 실행, 정지와 결과 보고, 가열 작동·종료 판정 |
| 누름 장치 | ESP32 + CoreXY 갠트리 (엔코더 기어드 DC 모터 6 V, 50:1 ×2) + SwitchBot Bot | 조작부 위 지정한 위치로 움직여, 도착을 확인한 뒤 버튼을 누름 |
| 콘센트 모듈 | ESP32 + DFRobot SEN0211 CT 센서 (0–20 A) | 가전의 소비전력으로 작동과 가열 종료를 판정 |
| 온습도 센서 | DHT22 | 키오스크의 실내 온습도 표시, 환기 조언 |
| 카메라 | USB 웹캠 | 사람이 있는지 없는지만 판단 |
| LG 가전 | LG 공기청정기 (ThinQ) | 공식 클라우드 연동으로 제어하고 상태를 다시 확인 |
| 버튼식 가전 | 전자레인지 | 누름 장치와 CT 센서로 같은 흐름에 넣는 대상 |

갠트리·모터·드라이버와 모션 제어의 핵심은 같은 팀 하드웨어 담당이 다른 작품(Touch Bridge)을 위해 만든 기계를 함께 씁니다. SimpleLay에서 새로 만든 것은 그 위의 제안·승인·결과 확인, 콘센트 모듈, 정지 규약과 안전 계층, 화면입니다 — [재사용 경계](docs/reuse-boundary.md).

누름 장치는 평면 버튼(다이얼 제외)을 대상으로 하며, 조작부 하나에 한 대를 붙입니다. 전자레인지에 음식을 넣고 꺼내는 것은 사람이 합니다.

---

## 🧠 소프트웨어 구성 (Software)

### ● 허브 서버 (`rpi/`)
- Platform: Raspberry Pi 5 (Docker)
- Language / Framework: Python, FastAPI, SQLite
- Key Roles:
    - 습관 알아채기(최근 28일, 서로 다른 3일·같은 시간대 3번)와 상황 제안
    - 승인, 맡기기(자동 실행 규칙), 실행 상태 관리, 폰·키오스크 API
    - LG ThinQ 공식 API 연동과 상태 다시 읽기
- 말 알아듣기: 정해진 규칙이 먼저 처리하고, 규칙으로 알아듣지 못한 말만 본체 AI 런타임의 공개 사전학습 언어 모델이 정해진 동작 가운데 하나를 고릅니다. 인터넷 없이 동작하며, 실행 전에는 늘 사람이 확인합니다.
- 사람 감지: 같은 런타임의 공개 사전학습 검출 모델로 사람이 있는지 없는지만 판단합니다. 쓰는 곳은 화면 깨우기와 말 걸 시점뿐이며, 실행의 근거가 아닙니다.

### ● 실행기 (`rpi4/`)
- Platform: Raspberry Pi 4 (Docker)
- Language: Python
- Key Roles:
    - 누름 장치에 버튼 순서를 보내고 정지와 결과를 보고
    - 콘센트 모듈의 전력 값으로 가열 작동(100 W 이상 5초)과 종료(15 W 이하 3초) 판정
    - 본체 생존 신호가 끊기면 스스로 정지

### ● 키오스크 (`rpi5-touchscreen-app/`)
- Platform: Raspberry Pi 5 + 15.8형 터치 패널
- Language / Framework: Dart, Flutter (Linux)
- Key Features: 큰 글씨의 제안 카드와 승인, 실행 상태, 큰 정지 버튼. 사람이 다가가면 화면이 깨어나고, 오래 비웠다 돌아오면 인사합니다.

### ● 폰 앱 (`app/`)
- Platform: Android
- Language / Framework: Dart, Flutter
- Key Features: 가전 등록(조작부 사진에서 버튼 위치 지정), 승인, 실행, 정지, 기록, 맡기기 설정

### ● 펌웨어 (`firmware-motion-corexy/`, `firmware-outlet/`)
- Platform: ESP32
- Language / Framework: C++, Arduino (PlatformIO)
- Key Roles: 누름 장치의 원점·이동·누름·정지 응답, 콘센트 모듈의 전력 계측과 보고

### ● 공용·배포 (`packages/`, `deploy/`)
- 폰과 키오스크가 함께 쓰는 Dart 패키지(가전 그림 등), 보드 배포 스크립트와 Dockerfile

---

## 📂 프로젝트 구조 (Repository Structure)

```plaintext
Simplelay/
├─ rpi/                     # 허브 서버 (controller·verifier는 실행기도 함께 사용)
├─ rpi4/                    # 실행기
├─ rpi5-touchscreen-app/    # 터치 패널 키오스크 (Flutter Linux)
├─ app/                     # 폰 앱 (Flutter Android)
├─ firmware-motion-corexy/  # 누름 장치 펌웨어 기록 (ESP32)
├─ firmware-outlet/         # 콘센트 모듈 펌웨어 (ESP32)
├─ firmware-motion/         # 모션 규약 표 (protocol_table.json)
├─ firmware/ · firmware-node/  # 초기 설계의 예비 경로
├─ packages/                # 공용 Dart 패키지
├─ deploy/                  # 보드 배포 (Dockerfile, 실행 스크립트)
├─ scripts/                 # 빌드·점검 도구
├─ housing/                 # 외형 검토 모델 (제작하지 않음)
└─ docs/                    # 설계·실측·제출 문서, 개발 기록
```

폴더별 안내는 각 폴더의 README에, 모듈별 지도와 안전 규칙이 들어 있는 코드 위치는 [코드 구조](docs/코드-구조.md)에 정리했습니다.

---

## 🔧 설치 및 실행 방법 (How to Run)

### 1) 하드웨어 없이 시뮬레이터로 실행
PC 한 대에서 승인 → 실행 → 결과 흐름을 확인하실 수 있습니다. 모터·센서·가전은 모두 모의로 동작합니다. 저장소 루트에서 실행합니다.

```powershell
py -m venv .venv; .\.venv\Scripts\python.exe -m pip install -e ".[test]"   # 1. 백엔드 환경
$env:SIMPLELAY_LOCAL_APPLIANCES = "home_mw,washer,intercom"                 # 2. 시연용 가전
.\.venv\Scripts\python.exe -m rpi.simulator_main --port 8782              # 3. 시뮬레이터
```

http://127.0.0.1:8782/simulator 에서 다음을 해 보실 수 있습니다.

- **실행** — 전자레인지 버튼 순서를 실행하면 `execute` → `result` 통신과 '모의' 표시가 나타납니다.
- **실패** — 실패를 넣고 다시 실행하면, 실패가 성공으로 바뀌지 않고 그대로 결과에 남습니다.
- **승인** — '키오스크에 시연 제안 띄우기'를 누르면 `/kiosk/`에 제안 카드가 뜨고, 승인하기 전에는 실행하지 않습니다. 키오스크 웹은 먼저 빌드해야 합니다 — [브라우저 시뮬레이터 실행](docs/브라우저-시뮬레이터-실행.md).

### 2) 자동 시험

```powershell
$env:PYTHONUTF8=1; .\.venv\Scripts\python.exe -m pytest           # 허브 서버 + 실행기
cd app; flutter test --exclude-tags screenshot                     # 폰 앱
cd rpi5-touchscreen-app; flutter test --exclude-tags screenshot    # 키오스크
```

### 3) 실제 보드
보드 배포와 현장 절차는 [운영 런북](docs/결선-운영-런북.md), 설정 값은 [환경 변수](docs/환경변수.md)를 참고해 주세요.

---

## 📊 실측 결과 (Results)

실제 보드와 가전으로 확인한 결과입니다. 날짜와 조건을 함께 적었습니다.

| 항목 | 결과 | 조건 |
| --- | --- | --- |
| 실행 경로 | 폰·키오스크 → 본체 → 실행기(Wi-Fi) → 누름 장치 보드까지 명령 전달과 응답, 키오스크 부팅 자동 실행 | 9/30–10/14 |
| LG 공기청정기 | 찾기·추가·상태 표시·풍량·전원 변경 후 상태를 다시 읽어 확인 | 10/15–16, 실제 1대 |
| 정해진 시각 자동 실행 | 22:00 켜기 2.3초, 07:00 끄기 2.7초 만에 상태 확인 | 10/16–17, 각 1회 |
| 습관 알아채기 | 실제 사용 기록에서 습관 3개 확인 (낮 1시쯤 켜기, 평일 밤 10시쯤 켜기, 밤 10시쯤 끄기). 제안을 여러 번 승인해도 저절로 자동 실행으로 바뀌지 않음 | 10/16 이후 기록 |
| 상황 제안 | 밤에 불을 끄자 수면 모드를 제안 → 17초 뒤 사용자 승인 → 2초 뒤 공기청정기 상태 확인 | 10/28 0시 30분 |
| 가열 종료 판정 (CT) | 사람이 시작한 1분 가열 4회 모두 종료를 판정, 판정한 작동 시간 60.6–60.7초 | 11/2–3, 전자레인지 1대 |
| 실제 누름 경로 | '네' → 시작 버튼 누름 → 소비전력으로 작동 확인(0 W → 3,754 W) → 정지 버튼 위 대기 → 앱에서 정지 → 정지 버튼 누름으로 전자레인지 멈춤 | 11/5, 1회 |
| 누름 장치 | 모터 구동과 엔코더 계수, 이동 중 정지 응답 18 ms, 도착 허용 오차 약 1 mm 안에서 도착 확인 뒤 누름 | 10/12–14, 11/2–5 |
| 사람 감지 | 본체 카메라로 한 장 약 0.8초에 판단 | 10/25–26 |
| 말 알아듣기 | 언어 모델만 쓰면 해당 없는 말에도 56% 동작을 고름 → 앞뒤 규칙으로 걸러 6%. 처음 보는 문장 42개 중 38개 정답, 해당 없는 말 17개 모두 실행 안 함, 응답 가운데값 9.8초 — [평가 기록](docs/발표/언어모델-평가-2026-10-26.md) §13 | 본체, 인터넷 없이 |

<p align="center"><img src="docs/submission/img/phone-real-run-power-confirmed-2026-11-05.png" alt="폰 앱 실행 결과: 가전이 전기를 쓰기 시작한 것도 확인했어요, 기준선 0.0W에서 3,754W, 1.0초 유지" width="520"><br/><sub>11/5 실제 누름 경로에서 소비전력으로 작동을 확인한 폰 화면</sub></p>

CT 판정은 '가열이 끝났다'는 것까지 알려 드리며, 조리가 다 됐다는 뜻은 아닙니다. 그래서 화면에는 '조리 완료가 아닐 수 있어요'라고 함께 표시합니다. 전력은 220 V 가정 추정치이며 전력계와 대조하지 않았습니다. 측정 기록은 [10/30 계측](docs/devlog/devlog_2026-10-30-outlet-sen0211-verification.md)과 [11/3 반복 측정](docs/devlog/devlog_2026-11-03-ct-repeat-deck.md)에 있습니다.

### 한계
- 누름 장치의 실제 누름은 반복 시험 횟수가 적습니다. 결선 당일에는 엔코더 배선이 끊겨, 같은 장치로 찍어 둔 실제 영상으로 누름 장면을 대신했습니다 — [결선 당일 기록](docs/devlog/devlog_2026-11-06-finals.md).
- 사용 기록은 10월 중순부터 팀원 2명분이라, 습관 알아채기를 일반화해서 말하지 않습니다.
- 가전별 버튼 구성도를 모아 공유하는 기능은 만들지 못했습니다.

날짜별 작업과 시험 기록은 [개발 기록](docs/devlog/)과 [시험 지도](rpi/tests/README.md), 전체 실측 표는 [실측 기록표](docs/실측-기록표.md)에 있습니다.

### 버튼 누름 장치와의 설계 차이

버튼 하나 위에 붙이는 시판 장치와 **설계 방식**을 비교했습니다. 성능 비교는 아니며, 시판 제품도 앱의 타이머나 일정으로 정한 시각에 버튼을 누를 수 있습니다 (S1)(S3).

| | 시판 버튼 누름 장치 (공개 사양, 2026-10-14 확인) | SimpleLay |
| --- | --- | --- |
| 누르는 범위 | 장치 하나가 버튼 하나 (S1)(S3) | 장치 하나가 조작부의 여러 버튼을 순서대로 |
| 언제 누를지 | 사용자가 정한 타이머·일정 (S1)(S3) | 사용 기록에서 습관을 알아채 먼저 묻고, 맡겨 주신 것만 자동으로 |
| 결과 확인 | 상태 값은 켜짐/꺼짐, 스위치 모드에서만 유효 (S2) | 소비전력으로 작동과 가열 종료를 판정하고, 확인하지 못하면 그대로 알림 |
| 다른 가전과 | 앱·허브·음성 비서 연동 (S1)(S3) | LG ThinQ 가전과 같은 승인·결과 흐름 |

출처: S1 [SwitchBot Bot 제품 페이지](https://www.switch-bot.com/products/switchbot-bot) · S2 [SwitchBot API 문서](https://github.com/OpenWonderLabs/SwitchBotAPI/blob/main/devices/others/bot.md) · S3 [Adaprox Fingerbot Plus 제품 페이지](https://www.adaprox.io/products/fingerbot-plus)

---

## 🧪 테스트 환경 (Test Environment)

| 구분 | 환경 |
| --- | --- |
| 본체 · 실행기 | Raspberry Pi 5, Raspberry Pi 4 (각각 Docker), 가정 Wi-Fi와 폰 핫스팟 |
| 화면 | 15.8형 터치 패널 키오스크, Android 실기기(Galaxy A31)와 에뮬레이터 |
| 가전 | LG 공기청정기 1대 (실제 ThinQ 클라우드), 버튼식 전자레인지 1대 |
| 센서 | DFRobot SEN0211 CT 센서, DHT22, USB 웹캠 |
| 개발 PC | Windows, Python 가상환경 + Flutter (하드웨어 없이 시뮬레이터 실행) |

---

## 📚 문서 안내

- [문서 모음](docs/README.md) — 처음 보실 문서, 시연·하드웨어·ThinQ·제출 문서
- [코드 구조](docs/코드-구조.md) · [환경 변수](docs/환경변수.md) · [시험 지도](rpi/tests/README.md)
- [시연 계획](docs/본선-시연-계획-v4.md) · [실측 기록표](docs/실측-기록표.md) · [제출 체크리스트](docs/submission/제출-체크리스트.md) · [근거 부록](docs/submission/근거-부록.md)
- [개발 기록](docs/devlog/) · [지난 문서](docs/archive/) · [공개 점검 기록](docs/공개-점검-2026-10-28.md)
- [개발 도구 사용 고지](docs/submission/개발도구-사용-고지-초안.md) — 코드·시험·문서 작성에 AI 도구를 사용했습니다. 개발 기록은 당시의 실패와 수정 과정을 그대로 남겨 두었습니다.

---

## 팀원 구성

<div align="center">

| **서예솔 (팀장)** | **박성원** |
|:---:|:---:|
| • 누름 장치 CoreXY 기구 설계·제작 <br> • 모터·엔코더 구성 <br> • 모션 보드 펌웨어 | • 소프트웨어 전체 (허브 서버 · 실행기 · 키오스크 · 폰 앱) <br> • 보드 통신, 정지와 안전 처리 <br> • 본체 안 AI 연동, LG ThinQ 연동 <br> • CT 콘센트 모듈 제작, 전력 측정 |
| ![Hardware](https://img.shields.io/badge/Hardware-CoreXY-d9822b) <br> ![ESP32](https://img.shields.io/badge/ESP32-Firmware-0A84FF) | ![Python](https://img.shields.io/badge/Python-FastAPI-05998B) <br> ![Flutter](https://img.shields.io/badge/Flutter-App_%26_Kiosk-02569B) <br> ![Embedded](https://img.shields.io/badge/Raspberry_Pi-Docker-C51A4A) |

</div>

---

## 라이선스

[MIT](LICENSE) — 팀 자비스 (박성원 · 서예솔). 외부 모델·SDK·참고 구현에는 각각의 배포 조건이 적용됩니다. LG ThinQ는 LG전자의 상표입니다.
