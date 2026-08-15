# 앱 디자인 시스템 (Phase D 구현 참조)

> SimpleLay Flutter 앱 디자인 고도화 기준. Material 3 + 다크 테마 기반. IoT 스마트홈 앱 트렌드 반영.

---

## 1. 색상 시스템

### 기본 방향
`ColorScheme.fromSeed` (현재 `main.dart` 방식 유지) + `copyWith`로 카드 계층만 오버라이드.  
수동 `ColorScheme(...)` 지정은 디자인팀 hex 팔레트 확정 시에만 사용.

```dart
// lib/theme/app_theme.dart
colorScheme: ColorScheme.fromSeed(
  seedColor: const Color(0xFF4FC3F7),   // 시안 — 유지
  brightness: Brightness.dark,
).copyWith(
  surface: const Color(0xFF0D1117),              // Scaffold 배경
  surfaceContainerLow: const Color(0xFF171D25),  // Card 배경
  surfaceContainerHigh: const Color(0xFF1E2733), // BottomSheet 배경
  error: const Color(0xFFEF4444),                // 비상 정지
),
```

### AppColors 상수 (ColorScheme 외부)

```dart
// lib/theme/app_colors.dart
class AppColors {
  // 배경 계층
  static const background        = Color(0xFF0D1117);
  static const surfaceLow        = Color(0xFF171D25);
  static const surfaceHigh       = Color(0xFF1E2733);

  // 주요 강조
  static const primary           = Color(0xFF4FC3F7);  // 시안

  // 상태 신호등 3색
  static const success           = Color(0xFF22C55E);  // 실행 완료
  static const warning           = Color(0xFFF59E0B);  // 센서 과부하 경고
  static const danger            = Color(0xFFEF4444);  // 비상 정지

  // 보조
  static const borderSubtle      = Color(0x40FFFFFF);  // 카드 테두리 25%
  static const onSurfaceMuted    = Color(0xFFB0BEC5);  // 보조 텍스트
}
```

### 색상 역할 표

| 역할 | 색상 | 용도 |
|------|------|------|
| 배경 | `#0D1117` | Scaffold 전체 |
| 카드 | `#171D25` | Card, ListTile |
| BottomSheet | `#1E2733` | 모달 시트 |
| 주요 강조 | `#4FC3F7` | 버튼, 아이콘, 진행바 |
| 성공/완료 | `#22C55E` | 실행 완료 피드백 |
| 경고 | `#F59E0B` | 센서 임계값 초과 |
| 위험/정지 | `#EF4444` | 비상 정지, 에러 |

---

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
    borderRadius: BorderRadius.circular(16),
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
    borderRadius: BorderRadius.circular(16),
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
