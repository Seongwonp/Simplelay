import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 주 사용자가 고령자다. 기본 크기를 Material 기본값 언저리에 두면 "큰 글씨 모드를
/// 켜야만 읽히는 앱"이 된다 -- 그 모드를 찾아 켜는 것부터가 장벽이다.
/// 그래서 **평소 크기 자체를 한 단계 올린다**(본문 15 -> 18, 보조 12 -> 16).
/// 200% 확대에서도 무너지지 않는 것은 골든 렌더로 확인한다.
class AppText {
  static const heading = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
  );

  static const title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
  );

  static const body = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w400,
  );

  // **색을 여기서 정하지 않는다.** 예전에는 다크용 회색을 상수로 물고 있어서
  // 라이트 모드의 크림 배경 위에서 2.48:1이었다 — app_colors.dart의 "하드코딩 금지"
  // 주석이 가리키던 바로 그 실수를 타이포 토큰 자신이 저지르고 있었다.
  // 색이 필요하면 `context.appCaption`을 쓸 것.
  static const caption = TextStyle(fontSize: 16);

  // 센서 수치 표시 — 숫자 너비 고정(탭형 수치)으로 흔들림 방지
  static const sensor = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w800,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

extension AppTextX on BuildContext {
  /// 보조 설명용 작은 글씨 — 배경 밝기에 맞는 색까지 얹어서 돌려준다.
  TextStyle get appCaption => AppText.caption.copyWith(color: appMuted);
}
