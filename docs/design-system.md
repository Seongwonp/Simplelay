# 앱 디자인 시스템 (Phase D 구현 참조)

> SimpleLay Flutter 앱 디자인 고도화 기준. Material 3 + 다크 테마 기반. IoT 스마트홈 앱 트렌드 반영.

---

## 1. 색상 시스템

> **이 문서는 구현을 따라간다.** source of truth는 `app/lib/theme/app_colors.dart`와
> `rpi5-touchscreen-app/lib/theme/kiosk_colors.dart`이며, 색을 바꿀 때는 코드를
> 먼저 고치고 이 표를 맞춘다. (2026-08-25 갱신 — 초기 시안 팔레트에서 골드로
> 전환된 뒤에도 이 문서가 한동안 구버전으로 남아 있었다.)

### 기본 방향
따뜻한 골드 + 세이지 그린. 생활가전 옆에 놓이는 기기라 개발자용 대시보드처럼
채도 높은 시안·네온을 쓰지 않는다. 폰과 키오스크가 **같은 팔레트**를 공유해
"휴대 화면과 공간 화면" 관계로 읽히게 한다.

### 다크 팔레트 (기본)

| 역할 | 색상 | 용도 |
|------|------|------|
| 배경 | `#0C0E12` | Scaffold 전체 / 키오스크 bg |
| 카드 | `#15181D` | Card, ListTile / 키오스크 surface |
| 상위 표면 | `#1D2126` | BottomSheet, 오버레이 / surface2 |
| 주요 강조 | `#D9A356` | 버튼, 아이콘, 진행바 (따뜻한 골드) |
| 성공/완료 | `#5FBF8F` | 실행 완료 (세이지 그린) |
| 경고 | `#F0B429` | 재시도·센서 임계 (앰버 — 골드와 색조 구분) |
| 위험/정지 | `#D9605C` | 긴급 정지, 실패 (브릭 레드) |
| 보조 텍스트 | `#9CA3AA` | 설명·라벨 |
| 테두리 | `#33FFFFFF` | 카드 경계 (흰색 20%) |

### 라이트 팔레트 (폰 전용 — 키오스크는 다크 고정)

| 역할 | 색상 | 비고 |
|------|------|------|
| 배경 | `#F4F1EB` | 따뜻한 크림 |
| 카드 | `#FDFCF8` | 거의 흰색 |
| 상위 표면 | `#ECEAE3` | 약간 어두운 크림 |
| 주요 강조 | `#6E4B0A` | **다크의 골드를 그대로 쓰면 대비 약 2:1** — 명도를 낮춰 흰 글자 7.85:1·바탕 7.26:1(2026-10-01, 이전 `#8B6010`은 5.56:1로 7:1 기준 미달) |
| 보조 텍스트 | `#6B7175` | 크림 배경에서 약 4.4:1 |
| 테두리 | `#1A000000` | 검정 10% |

### 필수 규칙 — 색은 반드시 토큰으로

`AppColors.primary`(다크 전용 골드)를 화면에서 직접 쓰면 라이트 모드에서
크림 배경 위 골드가 되어 본문 대비를 크게 밑돈다. **항상 `context.appPrimary`**
같은 테마 인식 확장을 쓴다.

```dart
// lib/theme/app_colors.dart
extension AppColorsX on BuildContext {
  Color get appPrimary      => _isDark ? AppColors.primary : AppColors.primaryLight;
  Color get appBackground   => ...;
  Color get appSurfaceLow   => ...;
  Color get appMuted        => ...;
  Color get appBorderSubtle => ...;
}
```

```dart
// 나쁜 예 — 라이트 모드에서 대비 미달
Icon(Icons.check, color: AppColors.primary)

// 좋은 예
Icon(Icons.check, color: context.appPrimary)
```

`Colors.white24` 같은 하드코딩도 크림 배경에서 사라지므로 `appOverlayFaint`
계열 토큰을 쓴다(수동 조작 그리드·제안 버튼맵이 깨졌던 원인).

## 2. 타이포그래피

```dart
// lib/theme/app_text.dart
class AppText {
  static const heading = TextStyle(
    fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5);
  static const title   = TextStyle(
    fontSize: 18, fontWeight: FontWeight.w600);
  static const body    = TextStyle(
    fontSize: 15, fontWeight: FontWeight.w400);
  static const caption = TextStyle(
    fontSize: 12, color: AppColors.onSurfaceMuted);
  static const sensor  = TextStyle(
    fontSize: 28, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()]);
}
```

---

## 3. 컴포넌트 스타일

### Card — 테두리 글로우

```dart
Card(
  elevation: 0,
  color: AppColors.surfaceLow,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(20),  // 실제 app_theme.dart 값
    side: BorderSide(color: AppColors.borderSubtle, width: 1),
  ),
)
```

### FilledButton

```dart
// ThemeData.filledButtonTheme
filledButtonTheme: FilledButtonThemeData(
  style: FilledButton.styleFrom(
    foregroundColor: Colors.black,
    backgroundColor: AppColors.primary,
    minimumSize: const Size.fromHeight(52),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
  ),
),
```

### NavigationBar

```dart
navigationBarTheme: NavigationBarThemeData(
  backgroundColor: AppColors.surfaceLow,
  indicatorColor: AppColors.primary.withValues(alpha: 0.18),
  labelTextStyle: WidgetStateProperty.all(
    const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
  ),
),
```

### BottomSheet

```dart
bottomSheetTheme: const BottomSheetThemeData(
  backgroundColor: AppColors.surfaceHigh,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  ),
  showDragHandle: true,
),
```

### LinearProgressIndicator (실행 진행바)

```dart
LinearProgressIndicator(
  value: progress,     // null → indeterminate
  minHeight: 6,
  borderRadius: BorderRadius.circular(3),
  color: AppColors.primary,
  backgroundColor: Colors.white12,
),
```

---

## 4. 애니메이션 패턴

### BLE 연결 상태 — AnimatedContainer

```dart
AnimatedContainer(
  duration: const Duration(milliseconds: 400),
  curve: Curves.easeOutCubic,
  decoration: BoxDecoration(
    color: connected
        ? AppColors.primary.withValues(alpha: 0.12)
        : Colors.white12,
    borderRadius: BorderRadius.circular(20),  // 실제 app_theme.dart 값
  ),
)
```

### 제안 카드 교체 — AnimatedSwitcher

```dart
AnimatedSwitcher(
  duration: const Duration(milliseconds: 300),
  transitionBuilder: (child, animation) =>
      FadeTransition(opacity: animation, child: child),
  child: SuggestionCard(key: ValueKey(suggestion.sequenceId)),
)
```

### 제안 카드 슬라이드 인 — SlideTransition

```dart
class SlidingCard extends StatefulWidget { ... }
class _SlidingCardState extends State<SlidingCard>
    with SingleTickerProviderStateMixin {

  late final AnimationController _ctrl = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 350));
  late final Animation<Offset> _offset = Tween(
    begin: const Offset(0, 0.12), end: Offset.zero)
    .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutQuart));
  late final Animation<double> _fade =
    CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);

  @override
  void initState() { super.initState(); _ctrl.forward(); }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: SlideTransition(position: _offset, child: widget.child));
}
```

### Lottie JSON 애니메이션 (선택)

```yaml
# pubspec.yaml
dependencies:
  lottie: ^3.1.0
```

```dart
// BLE 연결 대기 / 실행 중 스피너 대체
Lottie.asset('assets/animations/loading.json',
  width: 80, height: 80, repeat: true);
```

> JSON 파일 크기 < 50 KB 유지. Lottie 색상은 앱 팔레트(`AppColors.primary`)와 사전 조율.

---

## 5. 실시간 센서 시각화

### 패키지 비교

| 항목 | `fl_chart` | `CustomPaint` | `syncfusion` |
|------|-----------|--------------|-------------|
| 번들 크기 | ~300 KB | 0 | ~5 MB+ |
| 실시간 갱신 | setState + 슬라이딩 리스트 | 직접 구현 | ChartSeriesController |
| 라이선스 | MIT | — | 비상업 무료 |
| **추천** | **✅ 바 차트** | 단일 게이지 | 복잡한 대시보드 |

### fl_chart 실시간 mA 바 차트

```yaml
# pubspec.yaml
dependencies:
  fl_chart: ^0.69.0
```

```dart
// 최근 20개 샘플 슬라이딩 윈도우
final List<double> _history = List.filled(20, 0);

void _onSensorUpdate(double ma) {
  setState(() {
    _history.removeAt(0);
    _history.add(ma);
  });
}

BarChart(
  BarChartData(
    maxY: 2000,
    barGroups: _history.asMap().entries.map((e) =>
      BarChartGroupData(x: e.key, barRods: [
        BarChartRodData(
          toY: e.value,
          color: e.value > 1500 ? AppColors.warning : AppColors.primary,
          width: 8,
          borderRadius: BorderRadius.circular(4),
        ),
      ])).toList(),
    titlesData: FlTitlesData(show: false),
    gridData: FlGridData(show: false),
    borderData: FlBorderData(show: false),
  ),
  swapAnimationDuration: const Duration(milliseconds: 150),
)
```

---

## 6. 화면별 개선 방향

| 화면 | 현재 | 개선 |
|------|------|------|
| HomeScreen | 기본 Card + ListTile | 연결 상태 AnimatedContainer, 제안 카드 SlideTransition |
| SuggestionScreen | 단순 Row 타임라인 | 단계 타임라인 UI 강화, 버튼 라벨 아이콘 추가 |
| StatusScreen | 정적 숫자 표시 | fl_chart 실시간 mA/dB 바 차트, 단계 진행 애니메이션 |
| VoiceScreen | 버튼 1개 | 웨이브 비주얼라이저, 인식 텍스트 live 표시 |
| SettingsScreen | 기본 ListView | 섹션 카드 분리, 스캔 결과 애니메이션 |

---

## 7. 접근성 체크리스트

- [ ] 최소 터치 영역 48 × 48 dp (`ConstrainedBox(minHeight: 48)`)
- [ ] 모든 버튼에 `Semantics(label: ...)` 태그
- [ ] 상태 변화 위젯에 `Semantics(liveRegion: true)`
- [ ] 색상 대비 AA 기준 (4.5:1 이상) 확인
- [ ] `NavigationBar` 현재 탭에 `Semantics(selected: true)`

---

## 8. 적용 순서 (권장)

1. `lib/theme/app_colors.dart`, `lib/theme/app_text.dart` 생성
2. `lib/theme/app_theme.dart`에 ColorScheme·컴포넌트 테마 적용
3. StatusScreen fl_chart 센서 바 차트
4. HomeScreen 제안 카드 SlideTransition
5. VoiceScreen 웨이브 비주얼라이저
6. 접근성 Semantics 태그 전체 적용
