import 'package:flutter/material.dart';

/// 키오스크 색 한 벌. 평소(앱과 같은 골드 팔레트)와 고대비 두 벌이 있다(사용자 결정 10/18).
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
}

// 앱(AppColors)과 동일한 골드 팔레트 — 두 화면 간 시각적 통일감 유지.
//
// 고대비(사용자 결정 10/18, 설정 '고대비'): 회색 보조 글자 → 흰색, 옅은 면 → 검정, 옅은 테두리 → 흰 테두리, 상태색은 뜻을
// 그대로 두고 검정 바탕 위에서 더 또렷하게(검정 바탕·검정 글자 모두 7:1 이상, 정지 면은 더 진하게 — 흰 글자 7:1 이상).
// 대비 값은 `test/kiosk_contrast_test.dart`가 고정한다. 실패널에서 1~2 m로 보고 고친다(추측/실패널에서 측정 필요).
//
// 색은 static 게터다 — 고대비를 켜고 끄면 kiosk_screen이 화면 전체를 다시 그린다. 그래서 색을 쓰는 곳에는 const를 붙이지 않는다.
class KioskColors {
  const KioskColors._();

  /// 평소 색.
  static const standard = KioskPalette(
    primary: Color(0xFFD9A356), // 앱 primary와 동일 — 골드(2026-10-01), 검정 글자 9.32:1
    success: Color(0xFFF2F3F7), // 기존 중립 결과용
    // 중립 채움(흰 면·검은 글자) — 확인 필요·실패 화면의 주 단추(화면 구조 개편 10/18). 앰버 띠 위에 골드 면
    // 단추를 두면 '잘 됐으니 다음으로'처럼 읽혔다. 강조색(골드)은 할 일이 정해진 주 행동에만 쓴다.
    neutralFill: Color(0xFFF2F3F7),
    danger: Color(0xFFEF6E64), // 레드 — 면 위 검정 7.08:1
    warning: Color(0xFFE8B339), // 앰버
    // 긴급 정지 면. 연한 붉은색(danger)에 검정 글자는 대비는 넉넉했지만 비상
    // 버튼으로 읽히지 않았다(9/16 화면 평가). 짙은 빨강에 흰 글자 7.3:1.
    stop: Color(0xFFA8201A),
    // 연습(모의) 표시 전용 청록(2026-10-16 디자인 규격 §1-4·§4 결정). 앰버는 주요 행동·주의에만 쓰고
    // 연습에는 쓰지 않는다. 바탕(bg) 위 약 7.3:1 — 아이콘·띠 줄무늬에 쓰고 글자는 흰색으로 둔다.
    practice: Color(0xFF2BB3A6),
    // 실행 진행과 실제 확인 완료 전용 — 연습 청록·주의 앰버와 구분한다.
    running: Color(0xFF77A7FF),
    confirmed: Color(0xFF8DD49A),
    bg: Color(0xFF0F1117), // 앱 background와 동일
    surface: Color(0xFF191C24), // 앱 surfaceLow와 동일
    surface2: Color(0xFF232734), // 앱 surfaceHigh와 동일
    muted: Color(0xFFAEB3C0), // 앱 onSurfaceMuted와 동일
    border: Color(0x33FFFFFF), // 앱 borderSubtle와 동일
    // 설명 그림(버튼판) 칸 글자. 50% 회색이던 때는 버튼판이 꺼진 것처럼 보였다(지도교수 의견 10/17) — 불투명한
    // 밝은 회색으로 올린다. 실제 조작 단추와는 칸 테두리·면 유무로 구분한다(그림 칸은 테두리 없음).
    panelText: Color(0xFFC4C8D2),
    // 채도 있는 색을 **면으로** 쓸 때 얹는 글자색 (앱 AppColors.onAccent와 동일).
    // 초록 위 흰 글자는 2.25:1로 큰 글씨여도 미달이었다 — 검정이면 9.34:1이다.
    onAccent: Color(0xFF000000),
    // 흐린 타일(꺼짐) — 면(surface) 위 5.5:1 언저리. muted(#AEB3C0)는 흰색과 너무 비슷해 켜짐·꺼짐이 갈리지 않는다.
    tileDim: Color(0xFF8E93A0),
  );

  /// 고대비 색(사용자 결정 10/18). 값은 출발값이다 — 실패널에서 보고 고친다(추측/실패널에서 측정 필요).
  static const contrast = KioskPalette(
    primary: Color(0xFFFFC266),
    success: Color(0xFFFFFFFF),
    neutralFill: Color(0xFFFFFFFF),
    danger: Color(0xFFFF8A80),
    warning: Color(0xFFFFCC33),
    stop: Color(0xFF8B0000), // 더 진한 빨강 — 흰 글자 대비를 올린다
    practice: Color(0xFF33E0CC),
    running: Color(0xFF99C2FF),
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
    tileDim: Color(0xFFA0A0A0),
  );

  static KioskPalette _p = standard;

  /// 지금 고대비인가.
  static bool get highContrast => identical(_p, contrast);

  /// 고대비 켜기·끄기 — kiosk_screen만 부른다(설정 복원·토글). 부른 쪽이 화면을 다시 그린다.
  static void setHighContrast(bool on) => _p = on ? contrast : standard;

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
}
