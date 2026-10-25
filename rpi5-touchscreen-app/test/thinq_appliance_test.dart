// G5(화면) — /appliances의 control_path로 ThinQ 가전을 가른다(2026-09-29).
// 가전 선택 화면은 ThinQ 배지를 달고, ThinQ 가전에는 버튼판 대신 상태·조작 상세를 그린다(2026-10-16).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_art.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_select_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/route_badge.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/thinq_panel.dart';

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
    expect(find.widgetWithText(KioskRouteBadge, 'LG 가전'), findsOneWidget);
    expect(find.byType(KioskRouteBadge), findsOneWidget);
    await tester.tap(find.text('공기청정기(모의)'));
    expect(picked?.id, 'air_purifier');
  });

  // 2026-10-16(사용자 요청): 예전에는 '휴대폰에서 바꿀 수 있어요' 안내만 있었다. 이제 ThinQ 가전은 버튼판 대신
  // 지금 상태 + 큰 조작 단추 상세(KioskThinqPanel)다 — 자세한 규칙은 kiosk_thinq_detail_test.dart.
  testWidgets('ThinQ 가전은 버튼판 없이 경로와 상태·조작 상세를 보인다(허브 없으면 이유만)', (tester) async {
    await _pump(
      tester,
      KioskManualView(
        appliance: _purifier,
        onExecute: (_) => fail('ThinQ 가전에는 누를 버튼이 없다'),
        onCancel: () {},
      ),
    );
    await tester.pump();

    expect(find.text('공기청정기(모의)'), findsOneWidget);
    expect(find.widgetWithText(KioskRouteBadge, 'LG 가전'), findsOneWidget);
    expect(find.byType(KioskThinqPanel), findsOneWidget);
    // 상태를 읽을 길이 없으면 값·조작을 지어내지 않고 이유를 말한다.
    expect(find.textContaining('지금 상태를 불러오지 못했어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('thinq-set-set_power-POWER_ON')), findsNothing);
    expect(find.textContaining('누를 버튼이 없어요'), findsNothing);
    expect(find.textContaining('말로 맡겨'), findsNothing);
    expect(find.textContaining('버튼 누르기'), findsNothing);
    expect(tester.takeException(), isNull);
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

  testWidgets('가전 줄: 켜져 있다고 확인된 ThinQ 가전은 앞에 서고 "켜져 있어요"을 말한다(큰 글씨 칸도)', (tester) async {
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
      // 사용자 결정(10/19): 글자 대신 아이콘, 화면 읽기는 그대로 '켜져 있어요'.
      // 사용자 결정(10/19, 두 번째): 밝기 = 켜짐·작동 중 — 켜짐은 흰 아이콘(밝게), 꺼짐·모름·쉬는 중은 tileDim(흐리게). 강조색은 쓰지 않는다.
      expect(tester.widget<KioskApplianceArt>(find.byKey(const ValueKey('tile-icon-air_purifier'))).color, KioskColors.ink);
      expect(find.bySemanticsLabel(RegExp(r'LG 가전, 켜져 있어요, 자세히 보기')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    handle.dispose();
  });

  testWidgets('가전 줄: ThinQ 가전에만 ThinQ 배지가 붙고, 읽는 이름에 경로를 말한다', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, Center(child: strip(const {})));

    // 사용자 결정(10/19): 'LG 가전'은 오른쪽 위 배지가 아니라 이름 아래 작은 글자(오른쪽 위는 문제 표시 자리).
    expect(find.byKey(const ValueKey('tile-lg-air_purifier')), findsOneWidget);
    expect(find.byKey(const ValueKey('tile-lg-microwave')), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'공기청정기\(모의\), LG 가전')), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  // 타일 4개 한 줄에서도 한 줄에 들어가게 짧게(평가 4차 10/18) — 상태 띠의 '바꾸고 있어요'(평가 6차 10/18).
  // 사용자 결정(10/19): 화면 글자는 없고 화면 읽기 이름이 말한다.
  testWidgets('가전 줄: ThinQ 작업 중이면 "작동 중"이 아니라 "바꾸고 있어요"', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, Center(child: strip({'air_purifier', 'microwave'})));
    expect(find.bySemanticsLabel(RegExp(r'^공기청정기.*바꾸고 있어요')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^공기청정기.*작동하고 있어요')), findsNothing);
    // 물리 가전은 종전대로.
    expect(find.bySemanticsLabel(RegExp(r'^전자레인지.*작동하고 있어요')), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

}
