/// F2 최소 상태 UI — 남은 게 있을 때만, 한 줄로.
///
/// 카드·배지·통계 타일을 늘리지 않는다. 늘 떠 있는 상태 표시는 읽히지 않고,
/// 정작 문제가 생겼을 때도 눈에 안 들어온다.
///
/// 문구에 내부 용어(upsert·tombstone·revision·409)를 쓰지 않는다 — 사용자가
/// 알아야 하는 것은 "몇 건이 남았고 다시 시도할 수 있다"뿐이다.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/appliance_sync_provider.dart';
import 'package:simplelay/widgets/sync_status_line.dart';
import 'package:simplelay/screens/settings_screen.dart' show kResyncLabel;

/// 대기열을 기기에 심어 둔 채 화면만 띄운다 — 네트워크를 타지 않는다.
///
/// `runAsync`로 감싸는 이유: 위젯 테스트는 가짜 시계(fake async) 위에서
/// 도는데, 기기 저장소 읽기는 **진짜** 비동기다. 그냥 await 하면 영원히
/// 끝나지 않는다.
Future<ProviderContainer> _phoneWithQueue(
  WidgetTester tester,
  List<Map<String, dynamic>> ops, {
  bool trySync = false,
}) async {
  SharedPreferences.setMockInitialValues({
    'appliance_sync_outbox': [for (final op in ops) jsonEncode(op)],
  });
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.runAsync(() async {
    container.read(applianceSyncProvider);
    await Future<void>.delayed(Duration.zero);
    if (trySync) {
      // 서버 주소가 없어 실패한 상태를 만든다.
      await container.read(applianceSyncProvider.notifier).sync();
    }
  });
  return container;
}

Map<String, dynamic> _op(String id, String kind) => {
      'op_id': 'op-$id-$kind',
      'appliance_id': id,
      'kind': kind,
      'created_at': '2026-09-09T19:00:00+09:00',
      if (kind == 'upsert')
        'payload': {
          'id': id,
          'name': id,
          'rows': 1,
          'cols': 1,
          'buttons': [
            {'id': '$id-1', 'label': '전원', 'x': 0, 'y': 0},
          ],
        },
    };

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: SyncStatusLine(onRetry: () {})),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('다시 보내기 단추는 쉬운 말 — "동기화"를 쓰지 않는다(UI 평가 10/17)', () {
    expect(kResyncLabel, '바꾼 가전 본체로 다시 보내기');
    expect(kResyncLabel, isNot(contains('동기화')));
  });

  testWidgets('평상시에는 아무것도 띄우지 않는다', (tester) async {
    final container = await _phoneWithQueue(tester, const []);
    await _pump(tester, container);

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('대기 중이면 몇 건인지 말한다', (tester) async {
    final container = await _phoneWithQueue(tester, [_op('fan', 'upsert')]);
    await _pump(tester, container);

    expect(find.text('본체에 보낼 것 1건'), findsOneWidget);
    // 아직 시도해 보지도 않았는데 '다시 하기'를 내걸지 않는다.
    expect(find.text('다시 하기'), findsNothing);
  });

  testWidgets('여러 건이면 건수를 센다', (tester) async {
    final container = await _phoneWithQueue(tester, [
      _op('fan', 'upsert'),
      _op('humidifier', 'delete'),
    ]);
    await _pump(tester, container);

    expect(find.text('본체에 보낼 것 2건'), findsOneWidget);
  });

  testWidgets('실패한 뒤에는 다시 시도할 수 있다', (tester) async {
    final container = await _phoneWithQueue(tester, [_op('fan', 'upsert')], trySync: true);
    await _pump(tester, container);

    expect(find.text('바꾼 것 1건을 보내지 못했어요'), findsOneWidget);
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '다시 하기'),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('다시 시도 버튼은 48px 이상이다', (tester) async {
    final container = await _phoneWithQueue(tester, [_op('fan', 'upsert')], trySync: true);
    await _pump(tester, container);

    final size = tester.getSize(find.widgetWithText(TextButton, '다시 하기'));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('내부 용어를 사용자에게 노출하지 않는다', (tester) async {
    final container = await _phoneWithQueue(tester, [_op('fan', 'upsert')], trySync: true);
    await _pump(tester, container);

    for (final jargon in ['upsert', 'tombstone', 'revision', '409', 'outbox']) {
      expect(find.textContaining(jargon), findsNothing, reason: jargon);
    }
  });
}
