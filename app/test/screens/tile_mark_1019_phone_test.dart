// 가전 타일 단순화(사용자 결정 2026-10-19) — 옛 코드(상태 띠)에서 실패하는 것을 확인한 시험. 키오스크와 같은 규칙·같은 문장.
//
// 1. 평소 타일은 아이콘 + 이름만 — 아래 상태 글자 띠('준비됐어요'·'꺼져 있어요'·'확인 전이에요'·'설정이 필요해요' 등) 없음.
//    LG 가전 전원은 아이콘 자체로: 켜짐 = 밝게, 꺼짐 = 흐리게(10/19 두 번째: 강조색 대신 본문 글자색 — tile_power_1019_phone_test).
// 2. 문제가 있을 때만 오른쪽 위 작은 표시 하나: 쓸 수 없음 '!', 확인 전·모름 '?', 설정 남음 톱니.
// 3. 표시를 누르면 말풍선, 몇 초 뒤 닫힘. 타일 본체를 누르면 지금처럼 가전 화면. 누르는 자리 48dp 이상.
//    화면 읽기는 표시에서 상태 문장을 그대로 읽는다.
// 4. '못 써요' → '쓸 수 없어요'.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:simplelay/widgets/appliance_artwork.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_colors.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _appliance(String id, String name,
        {bool mapped = true,
        bool custom = true,
        String control = 'physical',
        String category = 'microwave',
        String readiness = 'operable',
        bool canExecute = true}) =>
    {
      'id': id,
      'name': name,
      'category': category,
      'rows': 1,
      'cols': 1,
      'is_custom': custom,
      'revision': 1,
      'control_path': control,
      'can_execute': canExecute,
      'readiness': readiness,
      'readiness_reasons': <String>[],
      'buttons': [
        if (control != 'thinq') {'id': '$id-1', 'label': '시작', 'x': 0, 'y': 0},
      ],
      if (mapped && control != 'thinq')
        'panel_mapping': {
          'photo': {'width': 100, 'height': 100},
        },
    };

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

Widget _home(RpiApiService api, {List<String>? opened}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(
          path: '/appliance/detail/:id',
          builder: (_, s) {
            opened?.add(s.pathParameters['id']!);
            return const Scaffold(body: Text('가전 화면'));
          }),
      GoRoute(path: '/appliance/add', builder: (_, __) => const Scaffold(body: Text('가전 추가 화면'))),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(const []),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(api),
    ],
    child: MaterialApp.router(
      theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
      routerConfig: router,
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Finder _mark(String id) => find.byKey(Key('appliance-mark-$id'));

List<String> _texts(WidgetTester tester) => [
      for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText)))
        p.text.toPlainText().replaceAll('⁠', ''),
    ];

Color? _iconColor(WidgetTester tester, String id) => tester
    .widget<ApplianceArtwork>(find.descendant(of: find.byKey(Key('appliance-icon-$id')), matching: find.byType(ApplianceArtwork)))
    .color;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('1. 평소 타일은 아이콘 + 이름만 — 상태 글자 띠·표시 없음', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_home(_hub([
      _appliance('mw', '전자레인지'),
      _appliance('air', '공기청정기', control: 'thinq', custom: false, category: 'air_purifier'),
    ], power: {'air': 'off'})));
    await _settle(tester);
    final texts = _texts(tester);
    for (final banned in ['준비됐어요', '꺼져 있어요', '켜져 있어요', '확인 전이에요', '설정이 필요해요']) {
      expect(texts, isNot(contains(banned)), reason: banned);
    }
    expect(find.byKey(const Key('appliance-band-mw')), findsNothing);
    expect(_mark('mw'), findsNothing);
    expect(_mark('air'), findsNothing, reason: '읽은 꺼짐은 문제가 아니다');
  });

  // 사용자 결정(10/19, 두 번째): 밝기 = 켜짐·작동 중 — 켜짐·실행 중은 본문 글자색(appInk), 꺼짐·모름·쉬는 중은 appTileDim. 강조색은 쓰지 않는다.
  testWidgets('1. LG 가전 전원은 아이콘 밝기 — 켜짐 밝게, 꺼짐 흐리게', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_home(_hub([
      _appliance('on', '공기청정기', control: 'thinq', custom: false, category: 'air_purifier'),
      _appliance('off', '제습기', control: 'thinq', custom: false, category: 'dehumidifier'),
    ], power: {'on': 'on', 'off': 'off'})));
    await _settle(tester);
    final ctx = tester.element(find.byKey(const Key('appliance-icon-on')));
    expect(_iconColor(tester, 'on'), ctx.appInk);
    expect(_iconColor(tester, 'off'), ctx.appTileDim);
  });

  testWidgets("2. 표시 — 전원 모름 '?', 연결 끊김 '!', 위치 미설정 톱니 — 화면 읽기는 문장", (tester) async {
    final h = tester.ensureSemantics();
    _tall(tester);
    await tester.pumpWidget(_home(_hub([
      _appliance('air', '공기청정기', control: 'thinq', custom: false, category: 'air_purifier'),
      _appliance('gone', '인터폰', readiness: 'disconnected', canExecute: false),
      _appliance('w', '세탁기', mapped: false),
    ])));
    await _settle(tester);
    expect(find.descendant(of: _mark('air'), matching: find.byIcon(Icons.question_mark_rounded)), findsOneWidget);
    expect(find.bySemanticsLabel('켜져 있는지 아직 확인하지 못했어요'), findsOneWidget);
    expect(find.descendant(of: _mark('gone'), matching: find.byIcon(Icons.priority_high_rounded)), findsOneWidget);
    expect(find.bySemanticsLabel('지금은 쓸 수 없어요. 연결을 확인해 주세요'), findsOneWidget);
    expect(find.descendant(of: _mark('w'), matching: find.byIcon(Icons.settings_rounded)), findsOneWidget);
    expect(find.bySemanticsLabel('버튼 자리를 아직 맞추지 않았어요. 가족이 휴대폰에서 설정해요'), findsOneWidget);
    h.dispose();
  });

  testWidgets('3. 표시를 누르면 말풍선, 몇 초 뒤 닫힘 — 가전 화면은 열지 않는다. 본체를 누르면 연다', (tester) async {
    _tall(tester);
    final opened = <String>[];
    await tester.pumpWidget(_home(
        _hub([_appliance('gone', '인터폰', readiness: 'disconnected', canExecute: false)]),
        opened: opened));
    await _settle(tester);
    final size = tester.getSize(_mark('gone'));
    expect(size.shortestSide, greaterThanOrEqualTo(48));
    await tester.tap(_mark('gone'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_texts(tester), contains('지금은 쓸 수 없어요. 연결을 확인해 주세요'));
    expect(opened, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    await _settle(tester);
    expect(_texts(tester), isNot(contains('지금은 쓸 수 없어요. 연결을 확인해 주세요')));
    await tester.tap(find.byKey(const Key('appliance-card-gone')));
    await _settle(tester);
    expect(opened, ['gone']);
  });

  testWidgets("4. 연습 배지는 그대로 — '?'와 겹치지 않는다", (tester) async {
    _tall(tester);
    await tester.pumpWidget(_home(_hub([
      _appliance('pw', 'LG 세탁기(연습)', control: 'thinq', custom: false, category: 'washing_machine'),
    ])));
    await _settle(tester);
    final badge = tester.getRect(find.byKey(const Key('appliance-practice-pw')));
    final mark = tester.getRect(_mark('pw'));
    expect(badge.right, lessThanOrEqualTo(mark.left + 12));
  });
}
