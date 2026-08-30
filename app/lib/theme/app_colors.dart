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

  // ── 상태 색상 ───────────────────────────────────────────────────────────
  static const success = Color(0xFF5FBF8F); // 세이지 그린
  static const warning = Color(0xFFF0B429); // 앰버 — 골드(#D9A356)와 색조 뚜렷이 구분
  static const danger  = Color(0xFFD9605C); // 브릭 레드

  // 라이트 모드에서 danger를 **글자·아이콘으로** 쓸 때. 크림 배경 위 #D9605C는
  // 3.2:1이라 읽히지 않는다 — primaryLight를 따로 둔 것과 같은 이유다.
  // 면으로 쓸 때는 danger 그대로에 onAccent 글자를 얹는다: danger 자체를 어둡게
  // 바꾸면 다크 배경 위 글자 대비가 5.31 → 3.9로 같이 깨진다.
  static const dangerLight = Color(0xFFB93A34); // 크림 표면 5.5:1 / 배경 5.0:1

  // 채도 있는 색을 **면으로** 쓸 때 얹는 글자색.
  //
  // 흰 글자는 골드 위 1.9:1, 초록 위 2.25:1, 빨강 위 3.63:1로 전부 무너진다.
  // 검정은 각각 9.32 / 9.34 / 5.78:1. 골드 버튼은 이미 이 규칙을 쓰고 있었고
  // 나머지 색만 안 따르고 있었다 — 그래서 가장 중요한 버튼(승인·긴급 정지)이
  // 가장 안 보였다.
  static const onAccent = Color(0xFF000000);

  // ── 보조 (다크) ──────────────────────────────────────────────────────────
  static const borderSubtle      = Color(0x33FFFFFF);
  static const onSurfaceMuted    = Color(0xFF9CA3AA);

  // ── 보조 (라이트) ─────────────────────────────────────────────────────────
  static const borderSubtleLight   = Color(0x1A000000);
  // 크림 **배경**(#F4F1EB) 위 대비까지 확보한 값. 이전 #6B7175는 표면 위 4.82:1로
  // 아슬아슬하게 통과했지만 배경 위에서는 4.39:1로 미달이었다 — 캡션은 카드 밖
  // 배경에도 얹힌다.
  static const onSurfaceMutedLight = Color(0xFF54585C); // 표면 6.99:1 / 배경 6.36:1
}

// BuildContext 확장 — 현재 밝기에 따라 올바른 색상을 반환
extension AppColorsX on BuildContext {
  bool get _isDark => Theme.of(this).brightness == Brightness.dark;

  Color get appPrimary       => _isDark ? AppColors.primary      : AppColors.primaryLight;
  Color get appBackground    => _isDark ? AppColors.background   : AppColors.backgroundLight;
  Color get appSurfaceLow    => _isDark ? AppColors.surfaceLow   : AppColors.surfaceLowLight;
  Color get appBorderSubtle  => _isDark ? AppColors.borderSubtle : AppColors.borderSubtleLight;
  Color get appMuted         => _isDark ? AppColors.onSurfaceMuted : AppColors.onSurfaceMutedLight;

  /// 경고·삭제·정지를 **글자나 아이콘으로** 표시할 때. 면으로 쓸 때는 이게 아니라
  /// `AppColors.danger` 배경 + `AppColors.onAccent` 글자다.
  Color get appDanger        => _isDark ? AppColors.danger : AppColors.dangerLight;

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
