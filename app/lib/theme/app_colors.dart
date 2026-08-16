import 'package:flutter/material.dart';

class AppColors {
  // ── 배경 계층 ── 차분한 중성 다크 (파란기 도는 흔한 "깃허브 다크"에서 탈피) ──
  static const background     = Color(0xFF0C0E12); // Scaffold 전체
  static const surfaceLow     = Color(0xFF15181D); // Card, ListTile
  static const surfaceHigh    = Color(0xFF1D2126); // BottomSheet

  // ── 주요 강조 ── 따뜻한 골드 — 뻔한 시안 대신, 가전/온기를 은은하게 연상 ──
  static const primary        = Color(0xFFD9A356);

  // ── 상태 신호등 ── primary(골드)와 색상환에서 뚜렷이 구분되도록 조정 ──
  static const success        = Color(0xFF5FBF8F); // 실행 완료 — 세이지 그린
  static const warning        = Color(0xFFE2793D); // 센서 임계값 초과 — 번트 오렌지
  static const danger         = Color(0xFFD9605C); // 비상 정지 / 에러 — 브릭 레드

  // ── 보조 ─────────────────────────────────────────────────────────────────
  static const borderSubtle   = Color(0x33FFFFFF); // 카드 테두리 20% 불투명도
  static const onSurfaceMuted = Color(0xFF9CA3AA); // 보조 텍스트
}
