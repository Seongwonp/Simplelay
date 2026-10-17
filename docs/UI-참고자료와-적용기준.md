# UI 참고 자료와 SimpleLay 적용 기준

작성일: 2026-10-17

이 문서는 SimpleLay의 폰 앱·키오스크 UI를 개선할 때 참고할 공개 자료와
적용 기준을 모은다. 외부 화면을 그대로 복제하지 않는다. 제품의 안전 계약,
결선 시연 흐름, 한국어 문구, 큰 글씨 환경에 맞게 원칙만 적용한다.

## 우선 참고할 공식 자료

### 1. Material Design 3 — 접근성

- [Accessibility overview](https://m3.material.io/foundations/accessible-design/overview)
- [Designing for accessibility](https://m3.material.io/foundations/designing/overview)
- [Interaction states](https://m3.material.io/foundations/interaction/states/overview)

**SimpleLay 적용**

- 상태를 색 하나로만 표현하지 않고 문장·아이콘·모양을 함께 사용한다.
- 버튼의 기본·눌림·비활성·확인 필요 상태를 명확히 구분한다.
- 실행 중·정지·확인 불가·자동 실행 건너뜀을 같은 카드 안에서 일관된
  상태 체계로 보여 준다.
- 주 행동은 하나로 두고, 위험하거나 되돌리기 어려운 행동은 확인 내용을
  먼저 보여 준다.

### 2. Android Developers — 적응형 레이아웃

- [Design an Adaptive Layout with Material Design](https://developer.android.com/codelabs/adaptive-material-guidance)
- [Compose Material 3 Adaptive](https://developer.android.com/jetpack/androidx/releases/compose-material3-adaptive)

**SimpleLay 적용**

- 폰의 360×780dp, 글꼴 2.0과 15.8형 키오스크를 별도 배치로 검증한다.
- 화면 폭이 줄거나 글씨가 커지면 버튼을 억지로 한 줄에 넣지 않고 세로로
  쌓거나 정보 우선순위에 따라 접는다.
- 고정 하단 행동 영역이 핵심 설명을 가리지 않게 한다.
- 키오스크는 멀리서 보는 정보와 가까이서 누르는 행동을 분리한다.

### 3. Flutter — 접근성·Semantics·반응형 UI

- [Flutter accessibility](https://docs.flutter.dev/ui/accessibility)
- [Accessibility technologies](https://docs.flutter.dev/ui/accessibility/assistive-technologies)
- [Semantics API](https://api.flutter.dev/flutter/widgets/Semantics-class.html)
- [Adaptive and responsive layouts](https://docs.flutter.dev/ui/layout/adaptive-responsive)

**SimpleLay 적용**

- 루틴 설명과 `편집`·`실행하기`를 하나의 의미 단위로 읽히게 한다.
- 실행 상태 변경은 `liveRegion` 또는 이에 맞는 Semantics로 알린다.
- 접근성 이름에는 화면 장식용 줄바꿈 결합 문자를 넣지 않고 원문을 사용한다.
- 큰 글씨에서 overflow, 잘린 문장, 화면 밖으로 밀리는 주 행동이 없는지
  실제 기기와 위젯 시험 양쪽에서 확인한다.

### 4. W3C WAI — 상태 메시지와 오류 방지

- [WCAG 2.2 — Status Messages](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html)
- [WCAG 2.2 — Error Prevention](https://www.w3.org/WAI/WCAG22/Understanding/error-prevention-all.html)
- [WCAG 2.2 — Error Identification](https://www.w3.org/WAI/WCAG22/Understanding/error-identification.html)

**SimpleLay 적용**

- SnackBar나 화면 전환만으로 중요한 결과를 전달하지 않고 기록·상태 카드에도
  남긴다.
- `성공` 대신 실제 확인 수준을 말한다. 예: `정지 신호를 받았어요`,
  `멈춘 것은 확인하지 못했어요`, `가열 종료를 감지했어요`.
- 실행 전 대상·동작·단계를 다시 보여 주고, 자동 실행 허용은 조건·대상·동작을
  확인한 뒤 저장한다.
- 오류 문장은 원인과 다음 행동을 함께 말한다. `연결 오류`보다
  `허브에 연결되지 않았어요 · 허브 주소를 확인해 주세요`가 우선이다.

### 5. Apple Human Interface Guidelines — 피드백과 접근성

- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Feedback](https://developer.apple.com/design/human-interface-guidelines/feedback)

**SimpleLay 적용**

- 중요한 상태는 색·문자·아이콘·소리 중 둘 이상으로 전달한다.
- 자동 실행, 정지, 비상정지, 결과 확인 불가는 사용자가 화면을 보고 있지
  않아도 알아차릴 수 있는 상태 문장과 접근성 알림을 제공한다.
- 조용한 시간으로 건너뛴 경우에도 “실행하지 않았다”는 결과를 기록한다.

## SimpleLay 화면별 적용 체크

| 화면 | 우선 확인할 것 |
|---|---|
| 홈 | 연결 상태, 실행 가능한 루틴, 자동 실행 상태가 한눈에 구분되는가 |
| 제안 확인 | 대상 가전·할 일·버튼 순서가 먼저 보이고 `지금 실행`이 명확한가 |
| 실행 상태 | 현재 단계, 확인 수준, 정지 버튼, 실패 후 다음 행동이 함께 보이는가 |
| 루틴 | `루틴으로 저장`과 `다음부터도 자동으로`의 의미가 섞이지 않는가 |
| 자동 실행 규칙 | 켜짐·조용한 시간 건너뜀·결과 확인 불가·재허용 필요를 구분하는가 |
| 기록 | 시각만 남지 않고 직접 실행·루틴·자동 실행 출처와 근거가 보이는가 |
| 설정 | 허브·ThinQ·조용한 시간·보안 상태를 사용자의 말로 설명하는가 |
| 키오스크 | 멀리서 상태를 읽을 수 있고, 연속 실행 시 이전 결과가 남지 않는가 |

## 결선 전 디자인 검증 순서

1. 폰 360×780dp에서 일반 글씨와 글꼴 2.0으로 홈·제안·실행 상태·루틴을 확인한다.
2. 키오스크 실제 패널에서 1~2m 거리의 문장 길이·아이콘 의미·버튼 위치를 확인한다.
3. TalkBack으로 루틴 행, 자동 실행 상태, 실행 결과, 정지 결과를 처음부터 끝까지 읽는다.
4. `실행 → 정지 → 다음 실행`, `실패 → 닫기 → 새 제안`, `자동 실행 건너뜀`
   흐름에서 이전 상태가 남지 않는지 확인한다.
5. 색을 보지 않고도 문장과 아이콘만으로 상태를 구분할 수 있는지 확인한다.

## 적용하지 않을 것

- 단순히 유행하는 대시보드나 화려한 애니메이션을 추가하지 않는다.
- 스마트홈 앱의 화면을 그대로 복제하지 않는다.
- 센서 숫자를 크게 배치해 실제로 확인하지 못한 상태를 성공처럼 보이게 하지 않는다.
- 자동 실행을 더 편하게 보이게 하려고 승인·확인 단계를 제거하지 않는다.
