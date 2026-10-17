// 디자인 토큰 지킴(화면 구조 개편 4단계, 2026-10-18) — 키오스크 글자 크기는 KioskType 4단계(40·30·21·17)와
// 대기 시계만 쓴다. 숫자를 바로 쓴 fontSize가 다시 늘어나면(폰은 15종이었다) 위계가 무너진다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/theme/kiosk_tokens.dart';

void main() {
  test('글자 크기 4단계 값', () {
    expect([KioskType.key, KioskType.status, KioskType.body, KioskType.caption], [40, 30, 21, 17]);
  });

  test('간격 5단계 값', () {
    expect([KioskSpace.xs, KioskSpace.sm, KioskSpace.md, KioskSpace.lg, KioskSpace.xl],
        [8, 12, 20, 28, 36]);
  });

  test('lib 안에 숫자를 바로 쓴 fontSize가 없다(토큰만)', () {
    final literal = RegExp(r'fontSize:\s*\d');
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (literal.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
