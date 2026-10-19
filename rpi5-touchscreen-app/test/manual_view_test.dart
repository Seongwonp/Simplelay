// 수동 조작 — 어느 가전의 판인지가 먼저 읽히고, 버튼 글자는 멀리서도 보인다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

Future<List<String>> _pump(
  WidgetTester tester,
  ApplianceMap appliance, {
  double textScale = 1.0,
}) async {
  final pressed = <String>[];
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: KioskManualView(
          appliance: appliance,
          onExecute: (b) => pressed.add(b.label),
          onCancel: () {},
        ),
      ),
    ),
  ));
  return pressed;
}

void main() {
  testWidgets('가전 이름이 크게, 버튼 라벨은 멀리서 읽히는 크기로', (tester) async {
    await _pump(tester, kMicrowaveAppliance);

    final name = tester.widget<Text>(find.text('전자레인지'));
    expect(name.style!.fontSize, greaterThanOrEqualTo(28));
    final label = tester.widget<Text>(find.text('즉석밥'));
    expect(label.style!.fontSize, greaterThanOrEqualTo(20));
    // 내부 버튼 id는 나오지 않는다.
    expect(find.textContaining('BT-'), findsNothing);
  });

  testWidgets('버튼은 최소 터치 크기를 넘고, 누르면 그 버튼을 맡긴다', (tester) async {
    final pressed = await _pump(tester, kMicrowaveAppliance);

    final cell = find.ancestor(
      of: find.text('시작'),
      matching: find.byType(InkWell),
    );
    final size = tester.getSize(cell);
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));

    // 누르기 전에 한 번 묻는다 — 판을 스친 것만으로 실물 가전이 움직이지 않게.
    await tester.tap(find.text('시작'));
    await tester.pump();
    expect(pressed, isEmpty);
    expect(find.text("'시작' 버튼을 눌러 드릴까요?"), findsOneWidget);
    await tester.tap(find.text('누르기'));
    await tester.pump();
    expect(pressed, ['시작']);
  });

  testWidgets('남는 자리만큼 판을 키운다 — 3열 판이 가운데 좁게만 차지 않는다',
      (tester) async {
    await _pump(tester, kMicrowaveAppliance);

    final cell = tester.getSize(find.ancestor(
      of: find.text('시작'),
      matching: find.byType(InkWell),
    ));
    // 예전 고정 크기(124x66)보다 크고, 상한(260x96)을 넘지 않는다(폭 상한 결선 모의 평가 10/18).
    expect(cell.width, greaterThan(124));
    expect(cell.height, greaterThan(66));
    expect(cell.width, lessThanOrEqualTo(260));
    expect(cell.height, lessThanOrEqualTo(96));
    // 판이 화면 폭의 절반을 넘게 쓴다(예전 3열 판은 약 400/800).
    final left = tester.getTopLeft(find.text('10초')).dx;
    final right = tester.getTopRight(find.text('냉동식품')).dx;
    expect(right - left, greaterThan(460));
  });

  testWidgets('스크린리더에 버튼으로 읽힌다', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, kMicrowaveAppliance);

    expect(find.bySemanticsLabel('시작 버튼 누르기'), findsOneWidget);
    handle.dispose();
  });

  // 첫 사용 검토 10/19 #17 — 누르기 확인 창이 판 위에 색만 덮어, 화면 읽기가 창 뒤 판 버튼까지 읽고 누를 수 있었다.
  testWidgets('누르기 확인 창은 화면 읽기에도 창이다 — 뒤 판은 읽히지 않고, 그만두기에 먼저 머문다', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, kMicrowaveAppliance);
    await tester.tap(find.text('시작'));
    await tester.pump();

    // 창 뒤 판 버튼은 읽히지 않는다.
    expect(find.semantics.byLabel('10초 버튼 누르기'), findsNothing);
    // 창은 이름이 있는 한 화면으로 읽힌다.
    final node = tester.getSemantics(find.byKey(const ValueKey('manual-press-confirm')));
    expect(node.label, contains("'시작' 버튼을 눌러 드릴까요?"));
    expect(node.flagsCollection.scopesRoute, isTrue);
    expect(node.flagsCollection.namesRoute, isTrue);
    // 실물을 움직이지 않는 쪽에 먼저 머문다.
    expect(Focus.of(tester.element(find.text('그만두기'))).hasPrimaryFocus, isTrue);
    handle.dispose();
  });

  testWidgets('준비 안 된 가전은 이유를 말하고 눌러도 맡기지 않는다', (tester) async {
    final pressed = await _pump(
      tester,
      const ApplianceMap(
        id: 'microwave',
        name: '전자레인지',
        category: 'microwave',
        rows: 4,
        cols: 3,
        buttons: [ApplianceButton(id: 'BT-05', label: '시작', x: 2, y: 3)],
        canExecute: false,
        readiness: 'needs_setup',
        readinessReasons: ['버튼 자리를 아직 맞추지 않았어요'],
      ),
      textScale: 1.22,
    );

    expect(find.text('아직 준비가 끝나지 않았어요'), findsOneWidget);
    expect(find.text('버튼 자리를 아직 맞추지 않았어요'), findsOneWidget);
    // 사유마다 할 일 한 줄(2026-10-15).
    expect(find.text('휴대폰 앱에서 이 가전 버튼 자리 맞추기를 해 주세요'), findsOneWidget);
    await tester.tap(find.text('시작'), warnIfMissed: false);
    expect(pressed, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
