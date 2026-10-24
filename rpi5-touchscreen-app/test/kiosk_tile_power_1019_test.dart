// 가전 타일 밝기 = 켜짐·작동 중(사용자 결정 2026-10-19, 두 번째) — 옛 코드에서 실패하는 것을 확인한 시험.
//
// 실패널에서 회색으로 흐린 타일이 '!' 문제 타일이었다(옛 규칙: 쓸 수 없으면 흐리게). 사용자 결정:
// - 흐린 모양(회색 아이콘·회색 이름) = 꺼짐·아무 작동 없음. 밝은 모양(흰 아이콘·흰 이름) = 켜짐·작동 중.
// - 카드 배경은 그대로 — 바뀌는 건 아이콘·이름 글자 밝기뿐. 문제('!'·'?'·톱니)는 오른쪽 위 표시만, 따로 흐리게 하지 않는다.
// - LG 가전: 읽은 켜짐 → 밝게, 읽은 꺼짐·모름 → 흐리게. 누름 장치 가전: 켜짐을 알 수 없으니 평소 흐리게, 지금 실행 중일 때만 밝게.
// - 고대비에서도 흐린 이름 글자 4.5:1 이상. 화면 읽기는 상태를 이름과 함께 읽는다(색만으로 말하지 않는다).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_art.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';

ApplianceMap _server(String id, String name, String category,
    {String control = 'physical', String readiness = 'operable', bool canExecute = true}) {
  return applianceFromServerJson({
    'id': id,
    'name': name,
    'category': category,
    'rows': 1,
    'cols': 1,
    'buttons': <dynamic>[],
    'is_custom': false,
    'control_path': control,
    'can_execute': canExecute,
    'readiness': readiness,
  });
}

final _mw = _server('mw', '전자레인지', 'microwave');
final _air = _server('air', '공기청정기', 'air_purifier', control: 'thinq');
final _gone = _server('gone', '인터폰', 'intercom', readiness: 'disconnected', canExecute: false);

Future<void> _pump(
  WidgetTester tester,
  List<ApplianceMap> list, {
  Set<String> running = const {},
  Set<String> attention = const {},
  Set<String> on = const {},
  Set<String> off = const {},
  Set<String> unavailable = const {},
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: KioskColors.bg,
      body: Center(
        child: KioskApplianceStrip(
          appliances: list,
          running: running,
          attention: attention,
          on: on,
          off: off,
          unavailable: unavailable,
          onSelect: (_) {},
          itemWidth: 240,
          tileHeight: 140,
        ),
      ),
    ),
  ));
  await tester.pump();
}

Finder _tile(String id) => find.byKey(ValueKey('strip-$id'));

// 가전 그림(시안 B 10/24, 폰과 같은 그림)의 선 색 — 예전 아이콘 색과 같은 밝기 규칙.
Color? _icon(WidgetTester tester, ApplianceMap a) =>
    tester.widget<KioskApplianceArt>(find.byKey(ValueKey('tile-icon-${a.id}'))).color;

Color? _name(WidgetTester tester, ApplianceMap a) =>
    tester.widget<Text>(find.descendant(of: _tile(a.id), matching: find.text(a.tileName))).style?.color;

/// 타일 면 색 — 타일 안 첫 Material.
Color _face(WidgetTester tester, String id) =>
    tester.widget<Material>(find.descendant(of: _tile(id), matching: find.byType(Material)).first).color!;

/// 이름 글자 위 불투명도 곱(1이면 흐리게 덮지 않음).
double _opacity(WidgetTester tester, ApplianceMap a) {
  var o = 1.0;
  for (final w in tester.widgetList<Opacity>(find.ancestor(
      of: find.descendant(of: _tile(a.id), matching: find.text(a.tileName)), matching: find.byType(Opacity)))) {
    o *= w.opacity;
  }
  return o;
}

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _ratio(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void _expectLit(WidgetTester tester, ApplianceMap a) {
  expect(_icon(tester, a), KioskColors.ink, reason: '${a.id} 아이콘 밝게(글자색)');
  expect(_name(tester, a), KioskColors.ink, reason: '${a.id} 이름 밝게(글자색)');
}

void _expectDim(WidgetTester tester, ApplianceMap a) {
  final icon = _icon(tester, a);
  final name = _name(tester, a);
  expect(icon, isNot(KioskColors.ink), reason: '${a.id} 아이콘 흐리게');
  expect(name, isNot(KioskColors.ink), reason: '${a.id} 이름 흐리게');
  expect(icon, name, reason: '아이콘·이름 같은 회색');
  expect(_ratio(name!, _face(tester, a.id)), greaterThanOrEqualTo(4.5), reason: '${a.id} 흐린 이름도 4.5:1 이상');
}

void main() {
  tearDown(() => KioskColors.setHighContrast(false));

  testWidgets('LG 가전 — 읽은 켜짐은 밝게(흰 아이콘·흰 이름), 읽은 꺼짐·모름은 흐리게', (tester) async {
    await _pump(tester, [_air], on: {'air'});
    _expectLit(tester, _air);
    await _pump(tester, [_air], off: {'air'});
    _expectDim(tester, _air);
    await _pump(tester, [_air]);
    _expectDim(tester, _air);
  });

  testWidgets('누름 장치 가전 — 평소 흐리게, 지금 그 가전에서 실행 중일 때만 밝게', (tester) async {
    await _pump(tester, [_mw]);
    _expectDim(tester, _mw);
    await _pump(tester, [_mw], running: {'mw'});
    _expectLit(tester, _mw);
  });

  testWidgets("문제 '!'는 표시만 — 따로 덮어 흐리게 하지 않고 카드 배경도 그대로", (tester) async {
    await _pump(tester, [_mw, _gone, _air], unavailable: {'mw'}, on: {'air'});
    expect(find.byKey(const ValueKey('tile-mark-mw')), findsOneWidget);
    expect(find.byKey(const ValueKey('tile-mark-gone')), findsOneWidget);
    for (final a in [_mw, _gone]) {
      expect(_opacity(tester, a), 1.0, reason: '${a.id} 문제 상태라고 덮어 흐리게 하지 않는다');
      expect(_face(tester, a.id), KioskColors.surface, reason: '${a.id} 카드 배경 그대로');
      _expectDim(tester, a);
    }
    // 같은 줄의 켜진 LG 가전과 흐린 모양이 확실히 다르다.
    _expectLit(tester, _air);
  });

  testWidgets('고대비에서도 흐린 모양은 밝은 모양과 다르고 이름 4.5:1 이상', (tester) async {
    KioskColors.setHighContrast(true);
    await _pump(tester, [_mw, _air], on: {'air'});
    _expectDim(tester, _mw);
    _expectLit(tester, _air);
    // 10/24 시각 QA — 고대비 검정 바탕에서 흐린 회색이 어둡게 읽혔다. 고대비는 흐린 이름도 10:1 이상.
    expect(_ratio(_name(tester, _mw)!, _face(tester, _mw.id)), greaterThanOrEqualTo(10));
  });

  testWidgets('화면 읽기 — 상태를 이름과 함께(켜짐·꺼짐·작동 중·작동 중 아님)', (tester) async {
    final h = tester.ensureSemantics();
    await _pump(tester, [_mw, _air], on: {'air'});
    expect(find.bySemanticsLabel(RegExp(r'^공기청정기, LG 가전, 켜져 있어요')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^전자레인지, 지금 누르고 있지 않아요')), findsOneWidget);
    await _pump(tester, [_mw, _air], off: {'air'}, running: {'mw'});
    expect(find.bySemanticsLabel(RegExp(r'^공기청정기, LG 가전, 꺼져 있어요')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^전자레인지, 작동하고 있어요')), findsOneWidget);
    h.dispose();
  });
}
