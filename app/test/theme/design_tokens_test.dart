/// 디자인 토큰 강제(UI 개편안 2026-10-17 §5) — 글자 5단계·간격 4의 배수.
///
/// 토큰을 만들어 두고도 코드가 숫자를 직접 써서 글자 15종·간격 14종이 됐다(감사 10/17).
/// 그래서 **소스 자체**를 읽어 숫자 리터럴을 막고, 테마의 글자 크기 바닥(16)도 고정한다.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/theme/app_text.dart';
import 'package:simplelay/theme/app_theme.dart';
import 'package:simplelay/theme/app_tokens.dart';

List<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

/// 토큰 파일만 숫자를 가진다.
bool _isTokenFile(File f) => f.path.replaceAll('\\', '/').endsWith('theme/app_tokens.dart');

/// `EdgeInsets.xxx(...)` 인자 안의 **값 자리** 숫자(괄호·쉼표·콜론·물음표 바로 뒤).
/// `rows - 1` 같은 계산 속 숫자는 값 자리가 아니라 세지 않는다. 0은 허용.
final _edgeCall = RegExp(r'EdgeInsets\.[a-zA-Z]+\(([^;]*?)\)');
final _valueLiteral = RegExp(r'(?<=[(:,?]\s*)(\d+(?:\.\d+)?)\b(?!\s*[-+*/])');

/// 한 방향 간격으로 쓰는 SizedBox(크기 지정 두 개는 크기라 제외).
final _gapBox = RegExp(r'SizedBox\(\s*(?:height|width):\s*(\d+(?:\.\d+)?)\s*\)');
final _spacingProp = RegExp(r'\b(?:[a-zA-Z]*[sS]pacing):\s*(\d+(?:\.\d+)?)\b');
final _fontLiteral = RegExp(r'fontSize:\s*[^,)]*?\b\d');

void main() {
  test('글자 크기를 숫자로 쓰지 않는다 — AppFont 토큰만', () {
    final offenders = <String>[];
    for (final f in _libFiles()) {
      if (_isTokenFile(f)) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_fontLiteral.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('간격을 숫자로 쓰지 않는다 — AppSpace 토큰만(0 제외, 32 넘는 크기 상자 제외)', () {
    final offenders = <String>[];
    for (final f in _libFiles()) {
      if (_isTokenFile(f)) continue;
      final src = f.readAsStringSync();
      for (final m in _edgeCall.allMatches(src)) {
        for (final v in _valueLiteral.allMatches('(${m.group(1)!})')) {
          if (double.parse(v.group(1)!) != 0) offenders.add('${f.path}: ${m.group(0)}');
        }
      }
      for (final m in _gapBox.allMatches(src)) {
        final v = double.parse(m.group(1)!);
        if (v != 0 && v <= 32) offenders.add('${f.path}: ${m.group(0)}');
      }
      for (final m in _spacingProp.allMatches(src)) {
        if (double.parse(m.group(1)!) != 0) offenders.add('${f.path}: ${m.group(0)}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('토큰은 5단계 글자(32·24·20·18·16)와 4의 배수 간격', () {
    expect(AppFont.all, [32, 24, 20, 18, 16]);
    expect(AppSpace.all, [4, 8, 12, 16, 20, 24, 32]);
    for (final s in [AppText.heading, AppText.title, AppText.body, AppText.caption, AppText.sensor]) {
      expect(AppFont.all, contains(s.fontSize), reason: '$s');
    }
  });

  test('테마의 글자 스타일은 모두 16 이상 — 기본 Text도', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final t = theme.textTheme;
      final styles = <String, TextStyle?>{
        'displayLarge': t.displayLarge, 'displayMedium': t.displayMedium,
        'displaySmall': t.displaySmall, 'headlineLarge': t.headlineLarge,
        'headlineMedium': t.headlineMedium, 'headlineSmall': t.headlineSmall,
        'titleLarge': t.titleLarge, 'titleMedium': t.titleMedium,
        'titleSmall': t.titleSmall, 'bodyLarge': t.bodyLarge,
        'bodyMedium': t.bodyMedium, 'bodySmall': t.bodySmall,
        'labelLarge': t.labelLarge, 'labelMedium': t.labelMedium,
        'labelSmall': t.labelSmall,
      };
      styles.forEach((name, s) {
        expect(s?.fontSize, isNotNull, reason: name);
        expect(s!.fontSize!, greaterThanOrEqualTo(16), reason: name);
      });
      expect(theme.appBarTheme.titleTextStyle?.fontSize, AppFont.cardTitle);
    }
  });
}
