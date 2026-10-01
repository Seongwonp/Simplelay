import 'package:flutter/material.dart';

// 앱(AppColors)과 동일한 골드 팔레트 — 두 화면 간 시각적 통일감 유지
class KioskColors {
  const KioskColors._();

  static const primary = Color(0xFFD9A356); // 앱 primary와 동일 — 골드(2026-10-01), 검정 글자 9.32:1
  static const success = Color(0xFFF2F3F7); // 성공은 색을 쓰지 않는다
  static const danger  = Color(0xFFEF6E64); // 레드 — 면 위 검정 7.08:1
  static const warning = Color(0xFFE8B339); // 앰버

  // 긴급 정지 면. 연한 붉은색(danger)에 검정 글자는 대비는 넉넉했지만 비상
  // 버튼으로 읽히지 않았다(9/16 화면 평가). 짙은 빨강에 흰 글자 7.3:1.
  static const stop    = Color(0xFFA8201A);

  static const bg      = Color(0xFF0F1117); // 앱 background와 동일
  static const surface = Color(0xFF191C24); // 앱 surfaceLow와 동일
  static const surface2 = Color(0xFF232734); // 앱 surfaceHigh와 동일
  static const muted   = Color(0xFFAEB3C0); // 앱 onSurfaceMuted와 동일
  static const border  = Color(0x33FFFFFF); // 앱 borderSubtle와 동일

  // 채도 있는 색을 **면으로** 쓸 때 얹는 글자색 (앱 AppColors.onAccent와 동일).
  // 초록 위 흰 글자는 2.25:1로 큰 글씨여도 미달이었다 — 검정이면 9.34:1이다.
  static const onAccent = Color(0xFF000000);
}
