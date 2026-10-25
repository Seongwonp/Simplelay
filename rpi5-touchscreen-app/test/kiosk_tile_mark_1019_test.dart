// 가전 타일 단순화(사용자 결정 2026-10-19) — 옛 코드(상태 띠)에서 실패하는 것을 확인한 시험.
//
// 1. 평소 타일은 아이콘 + 이름만 — 아래 상태 글자 띠('준비됐어요'·'꺼져 있어요'·'확인 전이에요' 등) 없음.
//    LG 가전 전원은 아이콘 자체로: 켜짐 = 밝게, 꺼짐 = 흐리게(10/19 두 번째: 강조색 대신 흰색 — kiosk_tile_power_1019_test). 연습 배지는 그대로.
// 2. 문제가 있을 때만 오른쪽 위 작은 표시 하나: 쓸 수 없음 '!', 확인 전·모름 '?', 설정 남음 톱니.
// 3. 표시를 누르면 말풍선(부드러운 한두 문장), 몇 초 뒤 닫힘. 타일 본체를 누르면 지금처럼 가전 화면.
//    누르는 자리 60px 이상. 화면 읽기는 표시에서 상태 문장을 그대로 읽는다.
// 4. '못 써요' → '쓸 수 없어요'.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_art.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_top.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

ApplianceMap _server(String id, String name, String category,
    {bool? custom, String control = 'physical', String readiness = 'operable', bool canExecute = true}) {
  return applianceFromServerJson({
    'id': id,
    'name': name,
    'category': category,
    'rows': 1,
    'cols': 1,
    'buttons': <dynamic>[],
    if (custom != null) 'is_custom': custom,
    'control_path': control,
    'can_execute': canExecute,
    'readiness': readiness,
  });
}

final _mw = _server('mw', '전자레인지', 'microwave', custom: false);
final _air = _server('air', '공기청정기', 'air_purifier', custom: false, control: 'thinq');
final _washer = _server('washer', '세탁기', 'washing_machine', custom: true);
final _practice = _server('pw', 'LG 세탁기(연습)', 'washing_machine', control: 'thinq');
final _gone = _server('gone', '인터폰', 'intercom', custom: false, readiness: 'disconnected', canExecute: false);

Future<void> _pump(WidgetTester tester, Widget strip) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(backgroundColor: KioskColors.bg, body: Center(child: strip)),
  ));
  await tester.pump();
}

KioskApplianceStrip _strip(List<ApplianceMap> list,
        {Set<String> on = const {},
        Set<String> off = const {},
        Set<String> unavailable = const {},
        bool estop = false,
        ValueChanged<ApplianceMap>? onSelect}) =>
    KioskApplianceStrip(
      appliances: list,
      running: const {},
      attention: const {},
      on: on,
      off: off,
      unavailable: unavailable,
      unavailableByEstop: estop,
      onSelect: onSelect ?? (_) {},
      itemWidth: 240,
      tileHeight: 140,
    );

List<String> _texts(WidgetTester tester) => [
      for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText))) p.text.toPlainText(),
    ];

Finder _mark(String id) => find.byKey(ValueKey('tile-mark-$id'));

// 가전 그림(시안 B 10/24)의 선 색.
Color? _iconColor(WidgetTester tester, String id, IconData icon) =>
    tester.widget<KioskApplianceArt>(find.byKey(ValueKey('tile-icon-$id'))).color;

void main() {
  testWidgets('1. 평소 타일은 아이콘 + 이름만 — 상태 글자 띠 없음, 표시 없음', (tester) async {
    await _pump(tester, _strip([_mw, _air], off: {'air'}));
    final texts = _texts(tester);
    for (final banned in ['준비됐어요', '꺼져 있어요', '켜져 있어요', '확인 전이에요', '가족이 설정해요', '지금 못 써요']) {
      expect(texts, isNot(contains(banned)), reason: banned);
    }
    expect(_mark('mw'), findsNothing);
    expect(_mark('air'), findsNothing, reason: '읽은 꺼짐은 문제가 아니다 — 아이콘이 흐릴 뿐');
    expect(texts, contains('전자레인지'));
  });

  // 사용자 결정(10/19, 두 번째): 밝기 = 켜짐·작동 중 — 켜짐은 흰 아이콘(밝게), 꺼짐·모름·쉬는 중은 tileDim(흐리게). 강조색은 쓰지 않는다.
  testWidgets('1. LG 가전 전원은 아이콘 밝기 — 켜짐 밝게, 꺼짐 흐리게', (tester) async {
    await _pump(tester, _strip([_air], on: {'air'}));
    expect(_iconColor(tester, 'air', _air.icon), KioskColors.ink);
    await _pump(tester, _strip([_air], off: {'air'}));
    expect(_iconColor(tester, 'air', _air.icon), KioskColors.tileDim);
  });

  testWidgets("2. 전원을 모르는 LG 가전은 '?' — 화면 읽기는 문장 그대로", (tester) async {
    final h = tester.ensureSemantics();
    await _pump(tester, _strip([_air]));
    expect(_mark('air'), findsOneWidget);
    expect(find.descendant(of: _mark('air'), matching: find.byIcon(Icons.question_mark_rounded)), findsOneWidget);
    expect(find.bySemanticsLabel('켜져 있는지 아직 확인하지 못했어요'), findsOneWidget);
    h.dispose();
  });

  testWidgets("2. 누름 장치 끊김은 '!' — 문장 '지금은 쓸 수 없어요…', 비상 버튼은 그 이유", (tester) async {
    final h = tester.ensureSemantics();
    await _pump(tester, _strip([_mw], unavailable: {'mw'}));
    expect(find.descendant(of: _mark('mw'), matching: find.byIcon(Icons.priority_high_rounded)), findsOneWidget);
    expect(find.bySemanticsLabel('지금은 쓸 수 없어요. 누름 장치 연결을 확인해 주세요'), findsOneWidget);
    await _pump(tester, _strip([_mw], unavailable: {'mw'}, estop: true));
    expect(find.bySemanticsLabel('지금은 쓸 수 없어요. 비상 버튼이 눌려 있어요'), findsOneWidget);
    expect(_texts(tester).where((t) => t.contains('못 써요')), isEmpty);
    h.dispose();
  });

  testWidgets("2. 연결이 안 된 가전도 '!', 위치를 맞추지 않은 가전은 톱니", (tester) async {
    final h = tester.ensureSemantics();
    await _pump(tester, _strip([_gone, _washer]));
    expect(find.descendant(of: _mark('gone'), matching: find.byIcon(Icons.priority_high_rounded)), findsOneWidget);
    expect(find.bySemanticsLabel('지금은 쓸 수 없어요. 연결을 확인해 주세요'), findsOneWidget);
    expect(find.descendant(of: _mark('washer'), matching: find.byIcon(Icons.settings_rounded)), findsOneWidget);
    expect(find.bySemanticsLabel('버튼 자리를 아직 맞추지 않았어요. 휴대폰 앱에서 맞춰 주세요'), findsOneWidget);
    h.dispose();
  });

  testWidgets('3. 표시를 누르면 말풍선, 몇 초 뒤 닫힘 — 타일 화면은 열지 않는다. 본체를 누르면 연다', (tester) async {
    final opened = <String>[];
    await _pump(tester, _strip([_mw], unavailable: {'mw'}, onSelect: (a) => opened.add(a.id)));
    final size = tester.getSize(_mark('mw'));
    expect(size.width, greaterThanOrEqualTo(60));
    expect(size.height, greaterThanOrEqualTo(60));
    await tester.tap(_mark('mw'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_texts(tester), contains('지금은 쓸 수 없어요. 누름 장치 연결을 확인해 주세요'));
    expect(opened, isEmpty, reason: '표시를 누르면 말풍선만');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(_texts(tester), isNot(contains('지금은 쓸 수 없어요. 누름 장치 연결을 확인해 주세요')));
    await tester.tap(find.text('전자레인지'));
    await tester.pump();
    expect(opened, ['mw']);
  });

  testWidgets("4. 연습 배지는 그대로 — 모르면 '?'와 나란히, 'LG 가전'은 이름 아래", (tester) async {
    await _pump(tester, _strip([_practice, _air]));
    expect(find.byKey(const ValueKey('tile-practice')), findsOneWidget);
    expect(_mark('pw'), findsOneWidget);
    final badge = tester.getRect(find.byKey(const ValueKey('tile-practice')));
    final mark = tester.getRect(_mark('pw'));
    expect(badge.right, lessThanOrEqualTo(mark.left + 16), reason: '연습 배지와 표시가 겹치지 않는다');
    final lg = tester.getRect(find.byKey(const ValueKey('tile-lg-air')));
    final name = tester.getRect(find.text('공기청정기'));
    expect(lg.top, greaterThanOrEqualTo(name.bottom - 1), reason: "'LG 가전'은 이름 아래 작은 글자");
  });

  test("5. 문제 칩 원인 문장도 '쓸 수 없어요'", () {
    const press = ConnectionItem(id: 'press', state: 'error', title: '', message: '');
    expect(connectionCauseLine(press, pressImpact: 4), '누름 장치 연결이 끊겨 가전 4대를 쓸 수 없어요');
  });

  testWidgets('5. 대기 화면에서도 상태 띠 글자 없음', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: KioskIdleView(
        now: DateTime(2026, 10, 19, 9, 0),
        connected: true,
        connections: const [
          ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
          ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
        ],
        appliances: [_mw, _air],
        onSelectAppliance: (_) {},
        onOpenConnection: (_) {},
        onDndGesture: () {},
      )),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_texts(tester), isNot(contains('준비됐어요')));
    expect(_mark('air'), findsOneWidget);
  });
}
