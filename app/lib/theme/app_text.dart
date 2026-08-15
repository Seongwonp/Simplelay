import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppText {
  static const heading = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
  );

  static const title = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w600,
  );

  static const body = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
  );

  static const caption = TextStyle(
    fontSize: 12,
    color: AppColors.onSurfaceMuted,
  );

  // 센서 수치 표시 — 숫자 너비 고정(탭형 수치)으로 흔들림 방지
  static const sensor = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w800,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}
