# UI 제품 앱·공개 레퍼런스

작성일: 2026-10-17

공식 디자인 가이드가 아니라 실제 제품 앱, 공개 UI 작업물, 오픈소스
레퍼지토리에서 SimpleLay UI에 참고할 만한 패턴을 모은 문서다.
화면·아이콘·브랜드 자산을 복사하지 않고 정보 구조와 상호작용 원칙만 참고한다.

## 먼저 볼 제품 앱

### LG ThinQ

- [App Store 화면·업데이트](https://apps.apple.com/us/app/lg-thinq/id993504342)
- [Google Play 검색·화면](https://play.google.com/store/search?q=LG%20ThinQ&c=apps)

**볼 포인트**

- 홈에서 가전 카드와 상태를 한눈에 보여 주고, 자주 쓰는 제어를 카드 가까이에 둔다.
- 루틴은 시간·기기 상태·상황을 조건으로 선택하고, 실행할 동작을 분리한다.
- 가전 상세에서 기본 상태와 세부 제어를 단계적으로 보여 준다.

**SimpleLay에 적용**

- 홈의 첫 영역은 등록 가전 전체보다 `지금 할 일`, `실행 중`, `확인 필요`를
  우선한다.
- 루틴 편집기는 `언제/무엇을/그다음` 문장형 구조를 유지하되, 자동 실행 전
  조건·대상·동작을 다시 확인시킨다.
- ThinQ 상태는 실제로 읽어 확인한 값과 단순히 명령을 보낸 상태를 구분한다.

**그대로 가져오지 않을 것**

- ThinQ의 많은 기능 탭과 상용 서비스 메뉴를 SimpleLay에 늘리지 않는다.
- ThinQ가 보여 주는 가전 상태를 CoreXY의 물리 누름 확인과 같은 수준으로
  표현하지 않는다.

### Samsung SmartThings

- [SmartThings 제품 소개](https://www.samsung.com/us/smartthings/)
- [SmartThings 앱 화면](https://apps.apple.com/us/app/smartthings/id1222822904)
- [SmartThings 루틴 도움말](https://support.smartthings.com/hc/en-us/articles/360051931952-Routines-in-SmartThings)
- [SmartThings 자동화·Scene 개발 문서](https://developer.smartthings.com/docs/automations/scenes/)
- [SmartThings Now 소개](https://news.samsung.com/us/samsung-introduces-smartthings-now-platform-update-brings-intuitive-user-experiences/)

**볼 포인트**

- Favorites/Home에서 사용자가 자주 쓰는 기기와 루틴을 앞에 고정한다.
- 기기 제어와 자동 실행을 구분하고, 수동 실행 루틴과 조건 실행 루틴을
  함께 관리한다.
- 자동화는 `IF 조건 → THEN 동작`으로 읽히며, 여러 기기 동작을 하나의
  시나리오로 묶는다.
- 사용 맥락에 따른 카드와 제안을 홈 상단에 배치한다.

**SimpleLay에 적용**

- 자동 실행 규칙 카드에 `조건`, `대상`, `동작`, `다음 실행`, `최근 결과`를
  고정된 순서로 보여 준다.
- `루틴으로 저장`과 `다음부터도 자동으로`를 SmartThings의 수동 실행과
  자동화처럼 서로 다른 상태로 명확히 분리한다.
- 자동 실행이 조용한 시간에 건너뛴 경우 “다시 시도하지 않음”을 결과에
  남긴다. 편리함보다 안전 계약이 우선이다.

### Toss

- [Toss x LottieFiles 사례](https://lottiefiles.com/case-studies/toss)
- [Toss Dashboard UI 사례](https://www.behance.net/gallery/118953055/Toss-DashBoard-design-portfolio)
- [Toss 관련 디자인 시스템 정리](https://github.com/VoltAgent/awesome-design-md/issues/209)

**볼 포인트**

- 한 화면의 핵심 숫자와 다음 행동을 먼저 보여 주는 정보 피라미드.
- 단일 강조색과 제한된 중간색으로 시각적 소음을 줄인다.
- 어려운 용어 대신 사용자가 바로 이해할 수 있는 문장과 짧은 보조 설명을
  사용한다.
- 대기·완료·실패 같은 순간에 작은 모션과 명확한 결과 피드백을 제공한다.

**SimpleLay에 적용**

- 실행 상태 화면에서 `지금 무엇을 하는지`를 가장 크게, 센서 원시값은 접어서
  보여 준다.
- 버튼을 많이 만들지 말고 `지금 실행`, `이번엔 안 할게요`, `정지`처럼
  순간의 주 행동을 하나로 정한다.
- 오류 문장을 짧게 쓰되 원인과 다음 행동을 함께 둔다.

**그대로 가져오지 않을 것**

- 금융 앱의 과도한 축하 애니메이션을 물리 장치 실행 결과에 사용하지 않는다.
- 성공처럼 보이는 모션으로 `확인 불가` 상태를 덮지 않는다.

### My Hyundai / Hyundai Digital Key

- [myHyundai App](https://apps.apple.com/gb/app/myhyundai/id6741947307)
- [Hyundai Digital Key](https://www.hyundai.com/eu/en/driving-hyundai/owning-a-hyundai/discover-myhyundai-app/digital-key.html)

**볼 포인트**

- 잠금·시동·공조처럼 위험도가 다른 행동을 큰 핵심 버튼으로 분리한다.
- 차량 상태와 제어 행동을 한 화면에서 연결하되, 실제 상태 변화 확인을
  별도 문장으로 알려 준다.
- 디지털 키 공유처럼 권한이 필요한 흐름은 대상·권한·기간을 확인시킨다.

**SimpleLay에 적용**

- 실행 상태에서 `정지`를 다른 버튼과 시각적으로 분리하고, 정지 결과를
  `신호를 보냄/보드가 받음/멈춤 확인`으로 나눈다.
- 자동 실행 허용 화면에서 조건·대상 가전·동작을 한 번 더 확인한다.
- 버튼 누름처럼 위험한 물리 동작은 자동화 허용 대상에서 제외한다.

## 공개 UI 작업물과 오픈소스

### Flutter 스마트홈 UI

- [anuragJoshi05/Smart-Home](https://github.com/anuragJoshi05/Smart-Home)
- [Qharny/Smart_Home_UI](https://github.com/Qharny/Smart_Home_UI)
- [julvikramsupandi/flutter-ui-smart-home-app](https://github.com/julvikramsupandi/flutter-ui-smart-home-app)
- [last-26/SmartHome-App-V2](https://github.com/last-26/SmartHome-App-V2)
- [mitchkoko/ModernSmartHomeUI](https://github.com/mitchkoko/ModernSmartHomeUI)

**볼 포인트**

- 기기 카드, 온·습도·전력 요약, 제어 버튼, 상태 애니메이션을 작은 화면에
  배치하는 방법.
- 다크 테마에서 카드 계층·강조색·토글 상태를 만드는 방법.
- 센서 차트와 장치 제어를 한 화면에서 분리하는 방법.

**주의**

- 많은 저장소가 시각적 데모 중심이라 실제 명령 확인·실패·정지 안전 계약은
  충분하지 않을 수 있다.
- SimpleLay는 이 저장소들의 UI 구조만 참고하고, 성공 판정·재시도·자동
  실행 정책은 현재 서버 안전 계약을 따른다.
- 코드나 이미지 자산을 가져오기 전 각 저장소의 라이선스를 확인한다.

### Home Assistant 기반 대시보드

- [Home Assistant React Dashboard](https://github.com/home-assistant-react/dashboard)
- [HA Component Kit](https://github.com/shannonhochkins/ha-component-kit)
- [Dynamic HA Dashboard / Glance](https://github.com/jvenuto80/Dynamic-HA-Dashboard)
- [Home Assistant Dashboard examples](https://github.com/ruudmens/home-assistant-dashboard)

**볼 포인트**

- 방·기기·즐겨찾기 기반 그룹화.
- 벽걸이 태블릿·키오스크에서 쓰는 큰 타일과 고정 영역.
- 실시간 상태를 WebSocket/event 기반으로 갱신하는 화면 구조.
- 사용자가 자주 보는 장치만 앞에 두는 개인화 방식.

**SimpleLay에 적용**

- 키오스크는 한 화면에 모든 설정을 넣지 않고 `상태 요약 → 확인 필요한
  가전 → 실행 중인 작업 → 보조 정보` 순서를 유지한다.
- 폰 홈은 기기 수를 늘리는 대신 현재 실행·제안·자동화 결과를 먼저 보여 준다.
- 이벤트가 늦게 오거나 이전 실행 결과가 남지 않도록 `job_id`와 실행 세대를
  기준으로 화면을 갱신한다.

### Figma·Dribbble·Behance 시각 레퍼런스

- [Figma Smart Home Dashboard UI Kit](https://www.figma.com/community/file/1152167387789323493/figma-ui-kit-smart-home-dashboard-community)
- [Figma Smarthome App Dashboard](https://www.figma.com/community/file/1346524533199148625/smarthome-app-dashboard)
- [Figma Smart Home Control Template](https://www.figma.com/community/file/1224671102837352485/smart-home-control-app-interface-ui-design-template)
- [Dribbble Smart Home UI](https://dribbble.com/tags/smart-home-ui)
- [Dribbble Smart Home Dashboard](https://dribbble.com/shots/27637222-Smart-Home-Dashboard-UI-Modern-IoT-Home-Automation-Control)
- [Behance Home Automation UI](https://www.behance.net/search/projects/Home%20Automation%20ui%20design)

**볼 포인트**

- 카드 크기와 여백의 리듬, 정보 밀도, 큰 상태 아이콘, 다크 화면 대비.
- 방·기기 전환, 상세 제어 화면, 자동화 편집 화면의 시각적 계층.
- 키오스크처럼 멀리서 읽는 화면에서 제목·상태·행동 버튼을 배치하는 방법.

**주의**

- Glassmorphism, 네온, 과도한 그라디언트는 실제 가전 제어와 접근성에
  불리할 수 있다.
- Dribbble·Behance·Figma 결과물은 동작 실패·접근성·긴 문장·큰 글씨를
  보여 주지 않는 경우가 많다. SimpleLay는 예쁜 화면보다 확인 수준과
  복구 경로를 우선한다.

## SimpleLay에 적용할 공통 패턴

1. **상태 우선 홈**: `지금 할 일 → 실행 중 → 확인 필요 → 등록 가전`.
2. **조건-동작 카드**: 자동 실행은 `언제/무엇을/대상/현재 상태/최근 결과` 순서.
3. **한 화면 한 주 행동**: 실행·정지·저장은 각각 하나의 명확한 주 버튼.
4. **점진적 공개**: 사용자는 결과를 먼저 보고, 센서 원시값과 상세 로그는 펼쳐 본다.
5. **확인 수준 배지**: 보냄·보드 응답·상태 확인·확인 불가를 색 외에 문장과
   아이콘으로 함께 표시한다.
6. **안전한 실패**: 실패 화면에는 원인, 현재 장치 상태, 다음 행동, 재시도 가능
   여부를 함께 둔다.
7. **폰과 키오스크의 같은 말**: 화면 크기는 달라도 `가열 종료 감지`,
   `정지 확인`, `조용한 시간이라 건너뜀` 같은 핵심 용어는 통일한다.

## 참고 우선순위

1. **제품 동작 구조**: LG ThinQ, SmartThings
2. **정보 우선순위와 문장**: Toss
3. **큰 상태·위험 행동 피드백**: My Hyundai
4. **카드·타일·키오스크 배치**: Home Assistant 대시보드
5. **시각적 변형 탐색**: Figma, Dribbble, Behance
6. **구현 아이디어**: Flutter 스마트홈 GitHub 저장소

예쁜 화면을 고르는 기준은 “멋있어 보이는가”가 아니라, SimpleLay의 사용자가
멀리서도 현재 상태와 다음 행동을 이해하고, 실행 결과를 실제 근거와 함께
확인할 수 있는가로 한다.
