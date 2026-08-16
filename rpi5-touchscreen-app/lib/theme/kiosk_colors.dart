import 'package:flutter/material.dart';

// 앱(AppColors)과 동일한 골드 팔레트 — 두 화면 간 시각적 통일감 유지
class KioskColors {
  const KioskColors._();

  static const primary = Color(0xFFD9A356); // 따뜻한 골드 (앱 primary와 동일)
  static const success = Color(0xFF5FBF8F); // 세이지 그린
  static const danger  = Color(0xFFD9605C); // 브릭 레드
  static const warning = Color(0xFFF0B429); // 앰버 (골드와 색조 구분)

  static const bg      = Color(0xFF0C0E12); // 앱 background와 동일
  static const surface = Color(0xFF15181D); // 앱 surfaceLow와 동일
  static const surface2 = Color(0xFF1D2126); // 앱 surfaceHigh와 동일
  static const muted   = Color(0xFF9CA3AA); // 앱 onSurfaceMuted와 동일
  static const border  = Color(0x33FFFFFF); // 앱 borderSubtle와 동일
}
