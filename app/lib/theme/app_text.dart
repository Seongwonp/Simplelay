import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_tokens.dart';

/// 주 사용자가 고령자다. 기본 크기를 Material 기본값 언저리에 두면 "큰 글씨 모드를
/// 켜야만 읽히는 앱"이 된다 -- 그 모드를 찾아 켜는 것부터가 장벽이다.
/// 그래서 **평소 크기 자체를 한 단계 올린다**(본문 15 -> 18, 보조 12 -> 16).
/// 200% 확대에서도 무너지지 않는 것은 골든 렌더로 확인한다.
class AppText {
  static const heading = TextStyle(
    fontSize: AppFont.tabTitle,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
  );

  static const title = TextStyle(
    fontSize: AppFont.cardTitle,
    fontWeight: FontWeight.w600,
  );

  static const body = TextStyle(
    fontSize: AppFont.body,
    fontWeight: FontWeight.w400,
  );

  // 글자색은 테마에서 정한다. 기존 다크용 회색 상수는 라이트 모드의 크림 배경에서 대비가 2.48:1이었다.
  // 색이 필요하면 context.appCaption을 쓴다(app_colors.dart 참조).
  static const caption = TextStyle(fontSize: AppFont.caption);

  // 센서 수치 표시 — 숫자 너비 고정(탭형 수치)으로 흔들림 방지
  static const sensor = TextStyle(
    fontSize: AppFont.number,
    fontWeight: FontWeight.w800,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

extension AppTextX on BuildContext {
  /// 보조 설명용 작은 글씨 — 배경 밝기에 맞는 색까지 얹어서 돌려준다.
  TextStyle get appCaption => AppText.caption.copyWith(color: appMuted);
}
