// 인터폰 종류(시연 v3 갭 S6, 2026-10-06) — ③ 방문자 문 열기의 인터폰이 `other`로 떨어지지 않는다.
//
// 서버(`ApplianceCategory.INTERCOM`)·키오스크(`applianceIconFor('intercom')`)와 같은 값 `intercom`을 쓴다.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/widgets/appliance_portrait.dart';

void main() {
  test('intercom을 인터폰으로 읽고 저장 값도 intercom이다', () {
    final c = ApplianceCategory.parse('intercom');

    expect(c.value, 'intercom');
    expect(c.label, '인터폰');
    expect(c.icon, Icons.doorbell);
  });

  test('가전 추가 화면이 고르는 종류 목록에 인터폰이 있다', () {
    expect(ApplianceCategory.values.map((c) => c.value), contains('intercom'));
  });

  testWidgets('인터폰 실루엣을 그린다(사진 없음)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppliancePortrait(
          appliance: ApplianceMap(
            id: 'intercom',
            name: '인터폰',
            category: ApplianceCategory.parse('intercom'),
            rows: 1,
            cols: 1,
            buttons: const [],
          ),
          size: 160,
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
