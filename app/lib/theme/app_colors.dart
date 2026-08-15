import 'package:flutter/material.dart';

class AppColors {
  // ── 배경 계층 ────────────────────────────────────────────────────────────
  static const background     = Color(0xFF0D1117); // Scaffold 전체
  static const surfaceLow     = Color(0xFF171D25); // Card, ListTile
  static const surfaceHigh    = Color(0xFF1E2733); // BottomSheet

  // ── 주요 강조 ────────────────────────────────────────────────────────────
  static const primary        = Color(0xFF4FC3F7); // 시안

  // ── 상태 신호등 ──────────────────────────────────────────────────────────
  static const success        = Color(0xFF22C55E); // 실행 완료
  static const warning        = Color(0xFFF59E0B); // 센서 임계값 초과
  static const danger         = Color(0xFFEF4444); // 비상 정지 / 에러

  // ── 보조 ─────────────────────────────────────────────────────────────────
  static const borderSubtle   = Color(0x40FFFFFF); // 카드 테두리 25% 불투명도
  static const onSurfaceMuted = Color(0xFFB0BEC5); // 보조 텍스트
}
