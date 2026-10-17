// 하위 화면 제목('할까요?'·'실행 상태' 등)도 탭 제목처럼 굵게(UI 평가 2026-10-17 — 가는 글씨라 위계가 약했다).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/theme/app_theme.dart';

void main() {
  test('앱바 제목은 두 테마 모두 굵은 글씨', () {
    for (final theme in [AppTheme.dark, AppTheme.light]) {
      final style = theme.appBarTheme.titleTextStyle;
      expect(style, isNotNull);
      expect(style!.fontWeight, FontWeight.w700);
      expect(style.fontSize, greaterThanOrEqualTo(22));
    }
  });
}
