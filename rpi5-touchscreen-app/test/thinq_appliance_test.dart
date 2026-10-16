// G5(화면) — /appliances의 control_path로 ThinQ 가전을 가른다(2026-09-29).
// 가전 선택 화면은 ThinQ 배지를 달고, ThinQ 가전에는 버튼판을 그리지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/route_badge.dart';

final _purifier = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기(모의)',
  'category': 'other',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

Future<void> _pump(WidgetTester tester, Widget view) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
}

void main() {
  test('control_path가 없으면 물리, thinq면 ThinQ 가전이다', () {
    expect(_purifier.isThinq, isTrue);
    final legacy = applianceFromServerJson({
      'id': 'microwave',
      'name': '전자레인지',
      'category': 'microwave',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'BT-08', 'label': '즉석밥', 'x': 0, 'y': 0},
      ],
    });
    expect(legacy.controlPath, 'physical');
    expect(legacy.isThinq, isFalse);
  });

  testWidgets('가전 선택: ThinQ 가전에만 ThinQ 배지가 붙는다', (tester) async {
    ApplianceMap? picked;
    await _pump(
      tester,
      KioskApplianceSelectView(
        appliances: [kMicrowaveAppliance, _purifier],
        lastUsedId: null,
        onSelect: (a) => picked = a,
        onCancel: () {},
      ),
    );

    expect(find.text('공기청정기(모의)'), findsOneWidget);
    expect(find.widgetWithText(KioskRouteBadge, 'ThinQ'), findsOneWidget);
    expect(find.byType(KioskRouteBadge), findsOneWidget);
    await tester.tap(find.text('공기청정기(모의)'));
    expect(picked?.id, 'air_purifier');
  });

  testWidgets('ThinQ 가전은 버튼판 없이 경로와 안내만 보인다', (tester) async {
    await _pump(
      tester,
      KioskManualView(
        appliance: _purifier,
        onExecute: (_) => fail('ThinQ 가전에는 누를 버튼이 없다'),
        onCancel: () {},
      ),
    );

    expect(find.text('내 공기청정기(모의)'), findsOneWidget);
    expect(find.widgetWithText(KioskRouteBadge, 'ThinQ'), findsOneWidget);
    expect(find.textContaining('ThinQ로 조작해요'), findsOneWidget);
    // 휴대폰 가전 화면에서 보고 바꿀 수 있다 — '누를 버튼이 없다'·'말로 맡겨'만 말하지 않는다(10/15).
    expect(find.textContaining('휴대폰의 가전 화면에서 지금 상태를 보고 설정을 바꿀 수 있어요'),
        findsOneWidget);
    expect(find.textContaining('누를 버튼이 없어요'), findsNothing);
    expect(find.textContaining('말로 맡겨'), findsNothing);
    expect(find.textContaining('버튼 누르기'), findsNothing);
  });

  testWidgets('물리 가전의 조작판은 종전대로 배지 없이 버튼을 그린다', (tester) async {
    await _pump(
      tester,
      KioskManualView(
        appliance: kMicrowaveAppliance,
        onExecute: (_) {},
        onCancel: () {},
      ),
    );

    expect(find.byType(KioskRouteBadge), findsNothing);
    expect(find.text('즉석밥'), findsOneWidget);
  });

  // ── 평소 화면 가전 줄(2026-10-15 외부 검토 L2) ─────────────────────────

  Widget strip(Set<String> running, {double itemWidth = 128}) => KioskApplianceStrip(
        appliances: [kMicrowaveAppliance, _purifier],
        running: running,
        attention: const {},
        onSelect: (_) {},
        itemWidth: itemWidth,
      );

  testWidgets('가전 줄: 켜져 있다고 확인된 ThinQ 가전은 앞에 서고 "켜짐"을 말한다(큰 글씨 칸도)', (tester) async {
    final handle = tester.ensureSemantics();
    for (final width in [128.0, 230.0]) {
      await _pump(
          tester,
          Center(
              child: KioskApplianceStrip(
            appliances: [kMicrowaveAppliance, _purifier],
            running: const {},
            attention: const {},
            on: const {'air_purifier'},
            onSelect: (_) {},
            itemWidth: width,
            perPage: 2,
          )));
      final purifier = tester.getRect(find.byKey(const ValueKey('strip-air_purifier')));
      final microwave = tester.getRect(find.byKey(const ValueKey('strip-microwave')));
      expect(purifier.left, lessThan(microwave.left));
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('strip-air_purifier')),
              matching: find.text('켜짐')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'경로 ThinQ, 켜짐\. 자세히 보기')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    handle.dispose();
  });

  testWidgets('가전 줄: ThinQ 가전에만 ThinQ 배지가 붙고, 읽는 이름에 경로를 말한다', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, Center(child: strip(const {})));

    expect(find.widgetWithText(KioskRouteBadge, 'ThinQ'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('strip-air_purifier')),
            matching: find.byType(KioskRouteBadge)),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('strip-microwave')),
            matching: find.byType(KioskRouteBadge)),
        findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'공기청정기\(모의\)\. 경로 ThinQ')), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('가전 줄: ThinQ 작업 중이면 "동작 중"이 아니라 허브가 "설정 변경 중"', (tester) async {
    await _pump(tester, Center(child: strip({'air_purifier', 'microwave'})));

    expect(
        find.descendant(
            of: find.byKey(const ValueKey('strip-air_purifier')),
            matching: find.text('설정 변경 중')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('strip-air_purifier')),
            matching: find.text('동작 중')),
        findsNothing);
    // 물리 가전은 종전대로.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('strip-microwave')),
            matching: find.text('동작 중')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
