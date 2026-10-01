import 'package:flutter/material.dart';

class AppColors {
  // ── 다크 배경 계층 ──────────────────────────────────────────────────────
  static const background     = Color(0xFF0F1117);
  static const surfaceLow     = Color(0xFF191C24);
  static const surfaceHigh    = Color(0xFF232734);

  // ── 라이트 배경 계층 ────────────────────────────────────────────────────
  // 바탕은 **푸른 기 도는 밝은 회색**, 카드는 순백. 카드가 테두리가
  // 아니라 **밝기 차이와 그림자**로 떠오른다 -- 흰 바탕에 흰 카드를
  // 두면 테두리 말고는 깊이 단서가 없어 화면이 납작해진다.
  static const backgroundLight  = Color(0xFFF4F6FA);
  static const surfaceLowLight  = Color(0xFFFFFFFF); // 카드 = 순백
  static const surfaceHighLight = Color(0xFFEAEDF5); // 눌린 면(입력칸 등)

  // ── 주요 강조 ───────────────────────────────────────────────────────────
  // 2026-10-01 사용자 결정: 강조색을 **골드**로 되돌린다(UI 확정 문서·로고와 통일).
  // 골드는 주의(앰버)와 색조가 가깝다 -- 그래서 주의는 색만으로 말하지 않는다
  // (아이콘·문구를 함께 쓰고, 강조색은 주 행동·진행 중·선택에만 쓴다).
  //
  // 대비 기준 7:1을 지킨다. 다크 #D9A356 위 검정 글자 9.32:1(바탕 대비 8.38:1).
  // 라이트는 디자인 시스템 문서의 #8B6010이 흰 글자 5.56:1이라 기준 미달이어서
  // 명도를 내려 #6E4B0A로 둔다(흰 글자 7.85:1, 라이트 바탕 대비 7.26:1).
  static const primary      = Color(0xFFD9A356); // 다크 — 검정 글자 9.32:1
  static const primaryLight = Color(0xFF6E4B0A); // 라이트 — 흰 글자 7.85:1

  // ── 상태 색상 ───────────────────────────────────────────────────────────
  // 성공은 색을 쓰지 않는다 -- 색을 아껴야 위험·주의가 눈에 띈다.
  // "성공·재시도·확인 불가가 색 없이도 구분된다"가 이미 완료 기준이다.
  static const success = Color(0xFFF2F3F7); // 다크 — 중립
  static const warning = Color(0xFFE8B339); // 앰버
  static const danger  = Color(0xFFEF6E64); // 레드 — 면 위 검정 7.08:1

  // 긴급 정지 면(키오스크 KioskColors.stop과 같은 값). 연한 레드에 검정 글자는
  // 대비는 넉넉했지만 비상 버튼으로 읽히지 않았다(9/16 화면 평가). 흰 글자 7.3:1.
  // 두 테마 모두 같은 면을 쓴다 -- 어느 모드에서든 같은 모양이어야 급할 때 찾는다.
  static const stop    = Color(0xFFA8201A);

  // 라이트 모드에서 danger를 **글자·아이콘으로** 쓸 때. 크림 배경 위 #D9605C는
  // 3.2:1이라 읽히지 않는다 — primaryLight를 따로 둔 것과 같은 이유다.
  // 면으로 쓸 때는 danger 그대로에 onAccent 글자를 얹는다: danger 자체를 어둡게
  // 바꾸면 다크 배경 위 글자 대비가 5.31 → 3.9로 같이 깨진다.
  static const dangerLight = Color(0xFF8C1D18); // 바탕 8.42 / 눌린 면 7.78:1

  // 같은 이유로 앰버·그린도 라이트 전용 변형이 필요하다. 크림 위에서 원본은
  // 앰버 1.82:1, 그린 2.19:1로 사실상 보이지 않는다 -- 상태를 색으로 알리는
  // 자리(연결됨·방해 금지·안전 정지)가 전부 여기에 걸린다.
  static const warningLight = Color(0xFF6B4600); // 바탕 7.76 / 눌린 면 7.17:1
  static const successLight = Color(0xFF16181D); // 라이트 — 중립

  // 채도 있는 색을 **면으로** 쓸 때 얹는 글자색.
  //
  // 흰 글자는 골드 위 1.9:1, 초록 위 2.25:1, 빨강 위 3.63:1로 전부 무너진다.
  // 검정은 각각 9.32 / 9.34 / 5.78:1. 골드 버튼은 이미 이 규칙을 쓰고 있었고
  // 나머지 색만 안 따르고 있었다 — 그래서 가장 중요한 버튼(승인·긴급 정지)이
  // 가장 안 보였다.
  //
  // 주의: 이 상수는 **팔레트가 밝은 색일 때**만 맞다. 라이트 모드 전용
  // 변형(primaryLight·dangerLight)은 반대로 어두우므로 검정을 얹으면
  // 3.78:1 / 3.72:1로 도로 무너진다 -- 그쪽은 appOnAccent를 쓴다.
  static const onAccent = Color(0xFF000000);

  // ── 보조 (다크) ──────────────────────────────────────────────────────────
  static const borderSubtle      = Color(0x33FFFFFF);
  // 고령 사용자 기준으로 **AAA(7:1)**를 제품 목표로 잡는다. 본문은 테마가 이미
  // 14~17:1이라 넉넉한데 보조 텍스트만 7 언저리에서 걸쳤다 -- 캡션이 실제로는
  // "부차적"이 아니라 버튼 순서·상태 설명을 담고 있어서 여기서 아끼면 안 된다.
  static const onSurfaceMuted    = Color(0xFFAEB3C0); // 카드 8.12 / 눌린 면 7.09:1

  // ── 보조 (라이트) ─────────────────────────────────────────────────────────
  // 라이트는 카드를 **그림자**로 나누므로 테두리는 아주 옅게만 둔다.
  static const borderSubtleLight   = Color(0x14000000);
  // 크림 **배경**(#F4F1EB) 위 대비까지 확보한 값. 이전 #6B7175는 표면 위 4.82:1로
  // 아슬아슬하게 통과했지만 배경 위에서는 4.39:1로 미달이었다 — 캡션은 카드 밖
  // 배경에도 얹힌다.
  static const onSurfaceMutedLight = Color(0xFF4A4D54); // 카드 8.47 / 바탕 7.82 / 눌린 면 7.23:1
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
  Color get appWarning       => _isDark ? AppColors.warning : AppColors.warningLight;
  Color get appSuccess       => _isDark ? AppColors.success : AppColors.successLight;

  /// 강조가 아닌 **정보**를 또렷하게 칠할 때 쓰는 무채색(본문 글자와 같은 계열).
  ///
  /// 강조색은 주 행동·지금 진행 중·선택된 것에만 쓴다. 순서 번호·안내 아이콘·
  /// 보조 버튼까지 강조색으로 칠하면 무엇을 눌러야 하는지 색으로 구분되지 않고,
  /// 화면 전체가 기본 테마를 그대로 입힌 것처럼 보인다(9/16 화면 평가).
  /// 이 색을 면으로 쓸 때 얹는 글자는 [appOnAccent]다.
  Color get appInk           => _isDark ? AppColors.success : AppColors.successLight;

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

  /// 강조색을 **면으로** 쓸 때 그 위에 얹는 글자·숫자색.
  ///
  /// 다크 모드의 강조색(골드 #D9A356, 브릭 레드 #D9605C)은 밝아서 검정이
  /// 맞지만, 라이트 모드 전용 변형(#8B6010, #B93A34)은 어두워서 흰색이
  /// 맞다. `AppColors.onAccent`(검정)를 두 모드에 그대로 쓰면 라이트에서
  /// 3.7:1대로 떨어진다 -- 제안 순서 배지·알림 개수 배지·주요 실행 버튼이
  /// 실제로 그렇게 걸려 있었다. 테마의 onPrimary와 같은 규칙이다.
  Color get appOnAccent => _isDark ? Colors.black : Colors.white;
}
