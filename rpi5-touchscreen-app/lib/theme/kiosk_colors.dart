import 'package:flutter/material.dart';

// 앱(AppColors)과 동일한 골드 팔레트 — 두 화면 간 시각적 통일감 유지
class KioskColors {
  const KioskColors._();

  static const primary = Color(0xFFD9A356); // 앱 primary와 동일 — 골드(2026-10-01), 검정 글자 9.32:1
  static const success = Color(0xFFF2F3F7); // 기존 중립 결과용

  /// 중립 채움(흰 면·검은 글자) — 확인 필요·실패 화면의 주 단추(화면 구조 개편 10/18). 앰버 띠 위에 골드 면
  /// 단추를 두면 '잘 됐으니 다음으로'처럼 읽혔다. 강조색(골드)은 할 일이 정해진 주 행동에만 쓴다.
  static const neutralFill = Color(0xFFF2F3F7);
  static const danger  = Color(0xFFEF6E64); // 레드 — 면 위 검정 7.08:1
  static const warning = Color(0xFFE8B339); // 앰버

  // 긴급 정지 면. 연한 붉은색(danger)에 검정 글자는 대비는 넉넉했지만 비상
  // 버튼으로 읽히지 않았다(9/16 화면 평가). 짙은 빨강에 흰 글자 7.3:1.
  static const stop    = Color(0xFFA8201A);

  // 연습(모의) 표시 전용 청록(2026-10-16 디자인 규격 §1-4·§4 결정). 앰버는 주요 행동·주의에만 쓰고
  // 연습에는 쓰지 않는다. 바탕(bg) 위 약 7.3:1 — 아이콘·띠 줄무늬에 쓰고 글자는 흰색으로 둔다.
  static const practice = Color(0xFF2BB3A6);

  // 실행 진행과 실제 확인 완료 전용 — 연습 청록·주의 앰버와 구분한다.
  static const running = Color(0xFF77A7FF);
  static const confirmed = Color(0xFF8DD49A);

  static const bg      = Color(0xFF0F1117); // 앱 background와 동일
  static const surface = Color(0xFF191C24); // 앱 surfaceLow와 동일
  static const surface2 = Color(0xFF232734); // 앱 surfaceHigh와 동일
  static const muted   = Color(0xFFAEB3C0); // 앱 onSurfaceMuted와 동일
  static const border  = Color(0x33FFFFFF); // 앱 borderSubtle와 동일

  // 설명 그림(버튼판) 칸 글자. 50% 회색이던 때는 버튼판이 꺼진 것처럼 보였다(지도교수 의견 10/17) — 불투명한
  // 밝은 회색으로 올린다. 실제 조작 단추와는 칸 테두리·면 유무로 구분한다(그림 칸은 테두리 없음).
  static const panelText = Color(0xFFC4C8D2);

  // 채도 있는 색을 **면으로** 쓸 때 얹는 글자색 (앱 AppColors.onAccent와 동일).
  // 초록 위 흰 글자는 2.25:1로 큰 글씨여도 미달이었다 — 검정이면 9.34:1이다.
  static const onAccent = Color(0xFF000000);
}
