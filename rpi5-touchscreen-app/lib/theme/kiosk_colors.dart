import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// 키오스크 색 한 벌. 밝은 화면(기본)·어두운 화면(시안 B 10/24, 폰 팔레트)과 고대비(사용자 결정 10/18) 세 벌이 있다.
@immutable
class KioskPalette {
  const KioskPalette({
    required this.primary,
    required this.success,
    required this.neutralFill,
    required this.danger,
    required this.warning,
    required this.stop,
    required this.practice,
    required this.running,
    required this.confirmed,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.muted,
    required this.border,
    required this.panelText,
    required this.onAccent,
    required this.tileDim,
    required this.ink,
    required this.glass,
    required this.glassText,
    required this.glassMuted,
    required this.well,
    required this.mint,
    required this.art,
    required this.brightness,
  });

  final Color primary;
  final Color success;
  final Color neutralFill;
  final Color danger;
  final Color warning;
  final Color stop;
  final Color practice;
  final Color running;
  final Color confirmed;
  final Color bg;
  final Color surface;
  final Color surface2;
  final Color muted;
  final Color border;
  final Color panelText;
  final Color onAccent;

  /// 가전 타일의 흐린 모양(꺼짐·아무 작동 없음) 아이콘·이름 색(사용자 결정 10/19, 두 번째). 밝은 모양은 흰색.
  /// 타일 면 위 4.5:1 이상이면서 흰색과 눈으로 구분되는 회색 — 대비 값은 `test/kiosk_tile_power_1019_test.dart`가 지킨다.
  final Color tileDim;

  /// 바탕·카드 위 기본 글자·아이콘 색(밝은 화면 = 짙은 남색 계열 검정, 어두운 화면·고대비 = 흰색). 시안 B(10/24) `--ink`.
  final Color ink;

  /// 가전 표시창(어두운 '유리' 패널, 시안 B `--glass`) — 밝은 화면에서도 어둡다. 글자는 [glassText]·[glassMuted].
  final Color glass;
  final Color glassText;
  final Color glassMuted;

  /// 가전 그림 칸 바탕(시안 B `--well`).
  final Color well;

  /// 고른 칸·강조 옅은 면(시안 B `--mint`).
  final Color mint;

  /// 가전 그림 선 색(시안 B `--art`).
  final Color art;

  /// Material 기본 색(스위치·대화 창)의 밝기.
  final Brightness brightness;
}

// 어두운 화면(dark)은 시안 B 어두운 모양(폰 앱 어두운 팔레트)의 바탕·면·강조색에, 어두운 바탕용 상태색(10/18 값)을 쓴다.
//
// 고대비(사용자 결정 10/18, 설정 '고대비'): 회색 보조 글자 → 흰색, 옅은 면 → 검정, 옅은 테두리 → 흰 테두리, 상태색은 뜻을
// 그대로 두고 검정 바탕 위에서 더 또렷하게(검정 바탕·검정 글자 모두 7:1 이상, 정지 면은 더 진하게 — 흰 글자 7:1 이상).
// 대비 값은 `test/kiosk_contrast_test.dart`가 고정한다. 실패널에서 1~2 m로 보고 고친다(추측/실패널에서 측정 필요).
//
// 색은 static 게터다 — 고대비를 켜고 끄면 kiosk_screen이 화면 전체를 다시 그린다. 그래서 색을 쓰는 곳에는 const를 붙이지 않는다.
class KioskColors {
  const KioskColors._();

  /// 화면 안 중앙 창 뒤에 까는 어두운 막.
  static Color get scrim => Colors.black.withValues(alpha: 0.6);

  /// 어두운 화면(설정 '어두운 화면', 시안 B 어두운 모양 10/24). 상태색은 종전 어두운 바탕 값 그대로.
  static const dark = KioskPalette(
    primary: Color(0xFFA0DED2), // 시안 B 어두운 모양 — 민트 면·짙은 글자(onAccent)
    success: Color(0xFFF2F3F7), // 기존 중립 결과용
    // 중립 채움(흰 면·검은 글자) — 확인 필요·실패 화면의 주 단추(화면 구조 개편 10/18). 앰버 띠 위에 골드 면
    // 단추를 두면 '잘 됐으니 다음으로'처럼 읽혔다. 강조색(골드)은 할 일이 정해진 주 행동에만 쓴다.
    neutralFill: Color(0xFFF2F3F7),
    danger: Color(0xFFEF6E64), // 레드 — 면 위 검정 7.08:1
    warning: Color(0xFFE8B339), // 앰버
    // 긴급 정지 면. 연한 붉은색(danger)에 검정 글자는 대비는 넉넉했지만 비상
    // 버튼으로 읽히지 않았다(9/16 화면 평가). 짙은 빨강에 흰 글자 7.3:1.
    stop: Color(0xFFA8201A),
    // 연습(모의) 표시 전용 — 폰 팔레트와 같은 파랑(10/24 시각 QA: 진행 중 색이 청록 primary 계열로 바뀌어 연습은
    // 파랑으로 구분한다). 앰버는 주의에만 쓰고 연습에는 쓰지 않는다.
    practice: Color(0xFF9BCBFA),
    // 실행 진행 — primary 청록 계열(10/24 시각 QA: 파랑은 연습과 겹쳤다). 주의 앰버와 구분한다.
    running: Color(0xFFA0DED2),
    confirmed: Color(0xFF8DD49A),
    bg: Color(0xFF0F1117), // 시안 B --bg
    surface: Color(0xFF1A1D26), // 시안 B --card
    surface2: Color(0xFF252935), // 시안 B --well
    muted: Color(0xFFA4A9B4), // 시안 B --muted
    border: Color(0xFF2E3340), // 시안 B --line
    // 설명 그림(버튼판) 칸 글자. 50% 회색이던 때는 버튼판이 꺼진 것처럼 보였다(지도교수 의견 10/17) — 불투명한
    // 밝은 회색으로 올린다. 실제 조작 단추와는 칸 테두리·면 유무로 구분한다(그림 칸은 테두리 없음).
    panelText: Color(0xFFC4C8D2),
    // 채도 있는 색을 **면으로** 쓸 때 얹는 글자색 (앱 AppColors.onAccent와 동일).
    // 초록 위 흰 글자는 2.25:1로 큰 글씨여도 미달이었다 — 검정이면 9.34:1이다.
    onAccent: Color(0xFF0F2B27),
    // 흐린 타일(꺼짐) — 면(surface) 위 5.5:1 언저리. muted(#AEB3C0)는 흰색과 너무 비슷해 켜짐·꺼짐이 갈리지 않는다.
    tileDim: Color(0xFF8E93A0),
    ink: Color(0xFFECEEF3),
    glass: Color(0xFF0A1614),
    glassText: Color(0xFFA0DED2),
    glassMuted:
        Color(0xFFBFD9D3), // 유리 위 10:1 이상(10/24 시각 QA — 8FB3AC는 작은 글자에서 흐렸다)
    well: Color(0xFF252935),
    mint: Color(0xFF1F3C37),
    art: Color(0xFFC9CDD6),
    brightness: Brightness.dark,
  );

  /// 밝은 화면 — 평소 색(시안 B 승인 10/24, 폰 앱 AppColors 밝은 팔레트와 같은 값). 기본값.
  ///
  /// 상태색은 뜻(계열)을 그대로 두고 밝은 바탕 위 글자·흰 글자 면 모두 4.5:1 이상이 되게 짙게 했다(추측/실패널에서 측정 필요).
  /// 채운 면 위 글자([onAccent])는 흰색이다.
  static const light = KioskPalette(
    primary: Color(0xFF175C55), // 폰 primary — 흰 글자 7.6:1
    success: Color(0xFF2B2F36),
    neutralFill: Color(0xFF3D4047), // 중립 채움 — 밝은 화면에서는 짙은 회색 면·흰 글자
    danger: Color(0xFFB3261E),
    warning: Color(0xFF8A5300),
    stop: Color(0xFFA8201A),
    practice: Color(0xFF164D7B), // 폰 practiceLight — 흰 글자 9:1 이상
    running: Color(0xFF175C55), // primary 청록 계열 — 흰 글자 7.6:1
    confirmed: Color(0xFF1E6B3A),
    bg: Color(0xFFF4F6FA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFECEFF4),
    muted: Color(0xFF5A5F69),
    border: Color(0xFFDADFE7),
    panelText: Color(0xFF3D4047),
    onAccent: Color(0xFFFFFFFF),
    tileDim: Color(0xFF6B717C),
    ink: Color(0xFF16181D),
    glass: Color(0xFF10201E),
    glassText: Color(0xFFA0DED2),
    glassMuted: Color(0xFFBFD9D3),
    well: Color(0xFFECEFF4),
    mint: Color(0xFFDDF4EE),
    art: Color(0xFF3D4047),
    brightness: Brightness.light,
  );

  /// 평소 색 = 밝은 화면(10/24부터 기본).
  static const standard = light;

  /// 고대비 색(사용자 결정 10/18). 값은 출발값이다 — 실패널에서 보고 고친다(추측/실패널에서 측정 필요).
  static const contrast = KioskPalette(
    primary: Color(0xFFFFC266),
    success: Color(0xFFFFFFFF),
    neutralFill: Color(0xFFFFFFFF),
    danger: Color(0xFFFF8A80),
    warning: Color(0xFFFFCC33),
    stop: Color(0xFF8B0000), // 더 진한 빨강 — 흰 글자 대비를 올린다
    practice: Color(0xFF99C2FF),
    running: Color(0xFF7FE6D6),
    confirmed: Color(0xFFA6F0B0),
    bg: Color(0xFF000000),
    surface: Color(0xFF000000),
    // 아주 옅은 면만 남겨 칸 모양은 보이게(흰 글자 18:1 이상). 칸의 경계는 흰 테두리가 맡는다.
    surface2: Color(0xFF141414),
    muted: Color(0xFFFFFFFF),
    border: Color(0xFFE6E6E6),
    panelText: Color(0xFFFFFFFF),
    onAccent: Color(0xFF000000),
    // 고대비의 muted는 흰색이라 흐린 타일이 켜진 타일과 같아진다 — 검정 위 8:1 언저리 회색(너무 어둡지 않게).
    tileDim:
        Color(0xFFC0C0C0), // 검정 위 11:1 — 흰색(밝게)과는 구분되고 흐려 보이지 않게(10/24 시각 QA)
    ink: Color(0xFFFFFFFF),
    glass: Color(0xFF000000),
    glassText: Color(0xFFFFFFFF),
    glassMuted: Color(0xFFFFFFFF),
    well: Color(0xFF141414),
    mint: Color(0xFF141414),
    art: Color(0xFFFFFFFF),
    brightness: Brightness.dark,
  );

  static KioskPalette _p = standard;
  static bool _dark = false;
  static bool _hc = false;
  static bool _night = false;

  /// 지금 고대비인가.
  static bool get highContrast => _hc;

  /// 지금 어두운 화면인가(고대비와 따로 저장 — 고대비를 끄면 고른 밝기로 돌아간다).
  static bool get darkMode => _dark;

  /// 고대비 켜기·끄기 — kiosk_screen만 부른다(설정 복원·토글). 부른 쪽이 화면을 다시 그린다.
  static void setHighContrast(bool on) {
    _hc = on;
    _apply();
  }

  /// 밝은·어두운 화면 고르기(10/24) — kiosk_screen만 부른다. 고대비가 켜져 있으면 고대비가 우선한다.
  static void setDarkMode(bool on) {
    _dark = on;
    _apply();
  }

  /// 조용한 시간 어둡게(처음 화면) — 밝은 화면이어도 그동안은 어두운 화면 색을 쓴다(밤에 밝은 바탕은 눈부시고,
  /// 밝은 바탕을 어둡게 덮으면 글자 대비가 무너진다). kiosk_screen만 부른다.
  static void setQuietNight(bool on) {
    _night = on;
    _apply();
  }

  static bool get quietNight => _night;

  static void _apply() {
    _p = _hc ? contrast : (_dark || _night ? dark : light);
    _listenable.value = _p;
  }

  static final ValueNotifier<KioskPalette> _listenable =
      ValueNotifier<KioskPalette>(standard);

  /// 색 한 벌이 바뀌면 알린다 — 앱 테마(대화 창·알림 줄이 쓰는 색)가 따라 바뀌게(코드 검토 10/24).
  /// 듣는 쪽은 그리는 도중에 바뀔 수 있으니(조용한 시간 어둡게는 build 안에서 바뀐다) 다음 프레임에 다시 그린다.
  static ValueListenable<KioskPalette> get listenable => _listenable;

  /// Material 기본 색(스위치 바탕·구분선·대화 창 면)을 지금 색 한 벌(밝은·어두운 화면·고대비)에 맞춘 테마.
  /// 앱 테마([base] 없음)와 키오스크 화면 안쪽 테마가 같은 규칙을 쓴다.
  static ThemeData theme([ThemeData? base]) {
    base ??= ThemeData(brightness: brightness);
    final scheme =
        ColorScheme.fromSeed(seedColor: primary, brightness: brightness)
            .copyWith(
      surface: surface,
      onSurface: ink,
      onSurfaceVariant: highContrast ? ink : muted,
      outline: border,
      outlineVariant: border,
      primary: primary,
      onPrimary: onAccent,
    );
    return base.copyWith(
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      dividerColor: border,
      colorScheme: scheme,
      textTheme: base.textTheme.apply(bodyColor: ink, displayColor: ink),
      iconTheme: base.iconTheme.copyWith(color: ink),
    );
  }

  /// 지금 쓰는 색 한 벌.
  static KioskPalette get palette => _p;

  static Color get primary => _p.primary;
  static Color get success => _p.success;
  static Color get neutralFill => _p.neutralFill;
  static Color get danger => _p.danger;
  static Color get warning => _p.warning;
  static Color get stop => _p.stop;
  static Color get practice => _p.practice;
  static Color get running => _p.running;
  static Color get confirmed => _p.confirmed;
  static Color get bg => _p.bg;
  static Color get surface => _p.surface;
  static Color get surface2 => _p.surface2;
  static Color get muted => _p.muted;
  static Color get border => _p.border;
  static Color get panelText => _p.panelText;
  static Color get onAccent => _p.onAccent;
  static Color get tileDim => _p.tileDim;
  static Color get ink => _p.ink;
  static Color get glass => _p.glass;
  static Color get glassText => _p.glassText;
  static Color get glassMuted => _p.glassMuted;
  static Color get well => _p.well;
  static Color get mint => _p.mint;
  static Color get art => _p.art;
  static Brightness get brightness => _p.brightness;
}
