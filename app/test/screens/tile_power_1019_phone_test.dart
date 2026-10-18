// 가전 타일 밝기 = 켜짐·작동 중(사용자 결정 2026-10-19, 두 번째, 키오스크 `kiosk_tile_power_1019_test`와 같은 규칙) —
// 옛 코드에서 실패하는 것을 확인한 시험.
//
// - 흐린 모양(회색 아이콘·회색 이름) = 꺼짐·아무 작동 없음. 밝은 모양(본문 글자색 아이콘·이름) = 켜짐·작동 중.
// - LG 가전: 읽은 켜짐 → 밝게, 읽은 꺼짐·모름 → 흐리게. 누름 장치 가전: 평소 흐리게, 지금 그 가전에서 실행 중일 때만 밝게.
// - 문제 표시('!'·'?'·톱니)는 밝기와 별개. 흐린 이름도 카드 위 4.5:1 이상(다크·라이트).
// - 화면 읽기는 상태를 이름과 함께 읽는다(색만으로 말하지 않는다).
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_colors.dart';
import 'package:simplelay/theme/app_theme.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _appliance(String id, String name,
        {String control = 'physical',
        String category = 'microwave',
        String readiness = 'operable',
        bool canExecute = true}) =>
    {
      'id': id,
      'name': name,
      'category': category,
      'rows': 1,
      'cols': 1,
      'is_custom': control != 'thinq',
      'revision': 1,
      'control_path': control,
      'can_execute': canExecute,
      'readiness': readiness,
      'readiness_reasons': <String>[],
      'buttons': [
        if (control != 'thinq') {'id': '$id-1', 'label': '시작', 'x': 0, 'y': 0},
      ],
      if (control != 'thinq')
        'panel_mapping': {
          'photo': {'width': 100, 'height': 100},
        },
    };

final _mw = _appliance('mw', '전자레인지');
final _air = _appliance('air', '공기청정기', control: 'thinq', category: 'air_purifier');
final _gone = _appliance('gone', '인터폰', category: 'intercom', readiness: 'disconnected', canExecute: false);

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

RpiApiService _hub(List<Map<String, dynamic>> appliances, {Map<String, String> power = const {}}) => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (req.method == 'GET' && path == '/appliances') return _json(appliances);
        if (req.method == 'GET' && path == '/routines') return _json(const []);
        if (path == '/suggestions') return _json(const []);
        if (path == '/thinq/power') {
          return _json({
            'appliances': [
              for (final e in power.entries) {'appliance_id': e.key, 'power': e.value},
            ],
          });
        }
        if (req.method == 'GET' && path.endsWith('/verify-pass')) {
          return _json({'state': 'done', 'execution_mode': 'real'});
        }
        return _json({'detail': 'not found'}, 404);
      }),
    );

Future<void> _pump(WidgetTester tester, List<Map<String, dynamic>> list,
    {Map<String, String> power = const {}, ExecutionStatus? execution, bool light = false}) async {
  tester.view.physicalSize = const Size(412, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/appliance/detail/:id', builder: (_, __) => const Scaffold(body: Text('가전 화면'))),
      GoRoute(path: '/appliance/add', builder: (_, __) => const Scaffold(body: Text('가전 추가 화면'))),
    ],
  );
  // 새 provider 상태로 — 같은 자리에 다시 그리면 앞 상태(전원·실행)가 남는다.
  await tester.pumpWidget(KeyedSubtree(key: UniqueKey(), child: buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(const []),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_hub(list, power: power)),
    ],
    executionStatus: execution,
    child: MaterialApp.router(
      theme: light ? AppTheme.light : AppTheme.dark,
      routerConfig: router,
    ),
  )));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _tile(String id) => find.byKey(Key('appliance-tile-$id'));

Color? _icon(WidgetTester tester, String id) => tester
    .widget<Icon>(find.descendant(of: find.byKey(Key('appliance-icon-$id')), matching: find.byType(Icon)))
    .color;

/// 이름 글자색 — 스타일에 없으면 물려받은 기본 글자색.
Color? _name(WidgetTester tester, String id, String name) {
  final f = find.descendant(of: _tile(id), matching: find.text(name));
  return tester.widget<Text>(f).style?.color ?? DefaultTextStyle.of(tester.element(f)).style.color;
}

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double _ratio(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void _expectLit(WidgetTester tester, String id, String name) {
  final ctx = tester.element(_tile(id));
  expect(_icon(tester, id), ctx.appInk, reason: '$id 아이콘 밝게');
  expect(_name(tester, id, name), ctx.appInk, reason: '$id 이름 밝게');
}

void _expectDim(WidgetTester tester, String id, String name) {
  final ctx = tester.element(_tile(id));
  final icon = _icon(tester, id);
  final text = _name(tester, id, name);
  expect(icon, isNot(ctx.appInk), reason: '$id 아이콘 흐리게');
  expect(text, isNot(ctx.appInk), reason: '$id 이름 흐리게');
  expect(icon, text, reason: '아이콘·이름 같은 회색');
  expect(_ratio(text!, ctx.appSurfaceLow), greaterThanOrEqualTo(4.5), reason: '$id 흐린 이름도 카드 위 4.5:1 이상');
}

const _running = ExecutionStatus(
  phase: ExecutionPhase.running,
  applianceId: 'mw',
  executionMode: 'real',
  totalSteps: 2,
  label: '데우기',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final light in [false, true]) {
    final mode = light ? '라이트' : '다크';

    testWidgets('$mode: LG 가전 — 읽은 켜짐은 밝게, 읽은 꺼짐·모름은 흐리게', (tester) async {
      await _pump(tester, [_air], power: {'air': 'on'}, light: light);
      _expectLit(tester, 'air', '공기청정기');
      await _pump(tester, [_air], power: {'air': 'off'}, light: light);
      _expectDim(tester, 'air', '공기청정기');
      await _pump(tester, [_air], light: light);
      _expectDim(tester, 'air', '공기청정기');
    });

    testWidgets('$mode: 누름 장치 가전 — 평소 흐리게, 지금 그 가전에서 실행 중일 때만 밝게', (tester) async {
      await _pump(tester, [_mw], light: light);
      _expectDim(tester, 'mw', '전자레인지');
      await _pump(tester, [_mw], execution: _running, light: light);
      _expectLit(tester, 'mw', '전자레인지');
    });
  }

  testWidgets("문제 '!'는 표시만 — 밝기는 켜짐·작동 중 규칙대로", (tester) async {
    await _pump(tester, [_gone, _air], power: {'air': 'on'});
    expect(find.byKey(const Key('appliance-mark-gone')), findsOneWidget);
    _expectDim(tester, 'gone', '인터폰');
    _expectLit(tester, 'air', '공기청정기');
  });

  testWidgets('화면 읽기 — 상태를 이름과 함께(켜짐·꺼짐·작동 중 아님)', (tester) async {
    final h = tester.ensureSemantics();
    await _pump(tester, [_mw, _air], power: {'air': 'on'});
    expect(find.bySemanticsLabel(RegExp(r'^공기청정기, LG 가전, 켜져 있어요')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^전자레인지, 작동 중 아님')), findsOneWidget);
    await _pump(tester, [_air], power: {'air': 'off'});
    expect(find.bySemanticsLabel(RegExp(r'^공기청정기, LG 가전, 꺼져 있어요')), findsOneWidget);
    h.dispose();
  });
}
