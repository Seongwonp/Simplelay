import 'package:flutter/material.dart';

class AppColors {
  // ── 다크 배경 계층 ──────────────────────────────────────────────────────
  static const background     = Color(0xFF0C0E12);
  static const surfaceLow     = Color(0xFF15181D);
  static const surfaceHigh    = Color(0xFF1D2126);

  // ── 라이트 배경 계층 ────────────────────────────────────────────────────
  static const backgroundLight  = Color(0xFFF4F1EB); // 따뜻한 크림
  static const surfaceLowLight  = Color(0xFFFDFCF8); // 거의 흰색
  static const surfaceHighLight = Color(0xFFECEAE3); // 약간 어두운 크림

  // ── 주요 강조 ───────────────────────────────────────────────────────────
  static const primary      = Color(0xFFD9A356); // 다크 모드 골드
  static const primaryLight = Color(0xFF8B6010); // 라이트 모드 — 명도 낮춰 대비 확보

  // ── 상태 색상 (다크/라이트 공용) ────────────────────────────────────────
  static const success = Color(0xFF5FBF8F); // 세이지 그린
  static const warning = Color(0xFFF0B429); // 앰버 — 골드(#D9A356)와 색조 뚜렷이 구분
  static const danger  = Color(0xFFD9605C); // 브릭 레드

  // ── 보조 (다크) ──────────────────────────────────────────────────────────
  static const borderSubtle      = Color(0x33FFFFFF);
  static const onSurfaceMuted    = Color(0xFF9CA3AA);

  // ── 보조 (라이트) ─────────────────────────────────────────────────────────
  static const borderSubtleLight   = Color(0x1A000000);
  static const onSurfaceMutedLight = Color(0xFF6B7175);
}

// BuildContext 확장 — 현재 밝기에 따라 올바른 색상을 반환
extension AppColorsX on BuildContext {
  bool get _isDark => Theme.of(this).brightness == Brightness.dark;

  Color get appPrimary       => _isDark ? AppColors.primary      : AppColors.primaryLight;
  Color get appBackground    => _isDark ? AppColors.background   : AppColors.backgroundLight;
  Color get appSurfaceLow    => _isDark ? AppColors.surfaceLow   : AppColors.surfaceLowLight;
  Color get appBorderSubtle  => _isDark ? AppColors.borderSubtle : AppColors.borderSubtleLight;
  Color get appMuted         => _isDark ? AppColors.onSurfaceMuted : AppColors.onSurfaceMutedLight;

  // 표면 위에 살짝 얹는 채움·테두리·보조 텍스트 — 다크는 흰색 기반, 라이트는
  // 검정 기반. Colors.white* 하드코딩은 크림색 라이트 배경에서 안 보이므로
  // 반드시 이 토큰을 쓴다 (수동 조작 그리드·제안 버튼맵이 깨졌던 원인).
  Color get appOverlayFaint   => _isDark
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.black.withValues(alpha: 0.04);
  Color get appBorderFaint    => _isDark ? Colors.white12 : Colors.black12;
  Color get appOutline        => _isDark ? Colors.white24 : Colors.black26;
  Color get appOnSurfaceSoft  => _isDark ? Colors.white70 : Colors.black87;
  Color get appOnSurfaceFaint => _isDark ? Colors.white54 : Colors.black54;
}
