// 홈 가전 타일의 '시험 이동' 보조 줄(2026-10-13) — 화면·접근성 이름·큰 글씨.
// 표시만 한다. 실행 경로를 부르지 않는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/appliance_setup_card.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _appliance(String id, String name, {bool mapped = true}) => {
      'id': id,
      'name': name,
      'category': 'microwave',
      'rows': 1,
      'cols': 1,
      'is_custom': true,
      'revision': 1,
      'can_execute': true,
      'readiness': 'operable',
      'readiness_reasons': <String>[],
      'buttons': [
        {'id': '$id-1', 'label': '시작', 'x': 0, 'y': 0},
      ],
      if (mapped)
        'panel_mapping': {
          'photo': {'width': 100, 'height': 100},
        },
    };

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

/// [verify]: 가전 id → verify-pass 응답. 없으면 일반 404.
RpiApiService _hub(
  List<Map<String, dynamic>> appliances,
  Map<String, http.Response> verify, {
  List<Map<String, dynamic>> routines = const [],
}) =>
    RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (path.startsWith('/execute') || path.endsWith('/approve')) {
          fail('홈이 실행 경로를 불렀어요: ${req.method} $path');
        }
        if (req.method == 'GET' && path == '/appliances') return _json(appliances);
        if (req.method == 'GET' && path == '/routines') return _json(routines);
        if (path == '/suggestions') return _json(const []);
        if (req.method == 'GET' && path.endsWith('/verify-pass')) {
          final id = path.split('/')[2];
          return verify[id] ?? _json({'detail': 'Not Found'}, 404);
        }
        return _json({'detail': 'not found'}, 404);
      }),
    );

Widget _home(RpiApiService api,
    {RpiConnectionState hub = RpiConnectionState.connected, double scale = 1}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(
          path: '/suggestion/:id',
          builder: (_, __) => const Scaffold(body: Text('승인 화면'))),
      GoRoute(
          path: '/appliance/add',
          builder: (_, __) => const Scaffold(body: Text('가전 추가 화면'))),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(const []),
      rpiServerOverride(hub),
      rpiApiServiceProvider.overrideWithValue(api),
    ],
    // 이 노트북 Flutter의 잉크 셰이더 판 불일치를 피한다(동작과 무관).
    child: MaterialApp.router(
      theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 타일이 그 말을 하는가 — 사용자 결정(10/19)부터 자리 확인 문장은 오른쪽 위 설정 표시의 문장이다.
Finder _inTile(String id, String text) => findTileSays(id, text);

/// 화면 가운데를 눌렀을 때 [target]의 그림 객체에 닿는가(다른 것에 가리지 않음).
bool _hits(WidgetTester tester, Finder target) {
  final box = tester.renderObject<RenderBox>(target);
  final center = box.localToGlobal(box.size.center(Offset.zero));
  final result = HitTestResult();
  tester.binding.hitTestInView(result, center, tester.view.viewId);
  return result.path.any((e) => e.target == box);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('근거별 보조 줄 — 모의 완료·실제 실패·명시적 기록 없음·실제 완료', (tester) async {
    _tall(tester);
    final api = _hub([
      _appliance('a', '전자레인지'),
      _appliance('b', '세탁기'),
      _appliance('c', '인터폰'),
      _appliance('d', '밥솥'),
    ], {
      'a': _json({'state': 'done', 'execution_mode': 'mock'}),
      'b': _json({'state': 'failed', 'execution_mode': 'real'}),
      'c': _json({'detail': '확인 주행 기록이 없어요'}, 404),
      'd': _json({'state': 'done', 'execution_mode': 'real'}),
    });
    await tester.pumpWidget(_home(api));
    await _settle(tester);

    expect(_inTile('a', '연습으로만 자리 확인했어요'), findsOneWidget);
    expect(_inTile('b', '자리 확인을 마치지 못했어요'), findsOneWidget);
    expect(_inTile('c', '아직 자리 확인을 안 했어요'), findsOneWidget);
    for (final t in [
      '연습으로만 자리 확인했어요',
      '자리 확인을 마치지 못했어요',
      '아직 자리 확인을 안 했어요',
      '버튼 자리를 다시 맞춰 주세요',
    ]) {
      expect(_inTile('d', t), findsNothing, reason: '실제 완료는 보조 줄 없음: $t');
    }
    // 평가 10차(10/18): 보조 줄이 있으면 띠가 그 한 문장 — 위 보조 줄과 아래 '준비됐어요'가 엇갈리지 않게.
    expect(_inTile('a', '준비됐어요'), findsNothing);
    // 사용자 결정(10/19): 자리 확인 문장은 오른쪽 위 설정 톱니 표시의 문장 — 띠는 없다.
    expect(tileMarkIcon(tester, 'a'), Icons.settings_rounded);
    // 실제로 자리 확인을 마친 가전은 표시 없음(평소).
    expect(tileMarkText(tester, 'd'), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('일반 404·해석 실패는 "확인 주행 전"이라 하지 않는다', (tester) async {
    _tall(tester);
    final api = _hub([
      _appliance('a', '전자레인지'),
      _appliance('b', '세탁기'),
    ], {
      'b': http.Response('<html>oops', 200),
    });
    await tester.pumpWidget(_home(api));
    await _settle(tester);
    expect(_inTile('a', '버튼 자리를 다시 맞춰 주세요'), findsOneWidget);
    expect(_inTile('b', '버튼 자리를 다시 맞춰 주세요'), findsOneWidget);
    expect(find.text('아직 자리 확인을 안 했어요'), findsNothing);
  });

  testWidgets('위치 미설정·허브 장애 타일에는 보조 줄을 붙이지 않는다', (tester) async {
    _tall(tester);
    final api = _hub([_appliance('w', '세탁기', mapped: false)], {
      'w': _json({'state': 'done', 'execution_mode': 'mock'}),
    });
    await tester.pumpWidget(_home(api));
    await _settle(tester);
    // 사용자 결정(10/19): 위치 미설정은 설정 톱니 표시 하나(자리 확인 문장을 겹치지 않는다).
    expect(tileMarkText(tester, 'w'), kTilePanelSetup);
    expect(_inTile('w', '연습으로만 자리 확인했어요'), findsNothing);
    expect(_inTile('w', '버튼 자리를 다시 맞춰 주세요'), findsNothing);
  });

  testWidgets('허브에 닿지 않으면 연결 문구만 — 보조 줄 없음', (tester) async {
    _tall(tester);
    final api = _hub([_appliance('a', '전자레인지')], const {});
    // 이 폰에 저장된 가전으로 타일을 그린다(서버 목록은 못 받는다).
    await tester.pumpWidget(buildWithProviderState(
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides(
            [ApplianceMap.fromJson(_appliance('a', '전자레인지'))]),
        rpiServerOverride(RpiConnectionState.unreachable),
        rpiApiServiceProvider.overrideWithValue(api),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
        home: const HomeScreen(),
      ),
    ));
    await _settle(tester);
    // 사용자 결정(10/19): 쓸 수 없음 '!' 표시의 문장.
    expect(tileMarkText(tester, 'a'), kTileUnusableHub);
    expect(_inTile('a', '버튼 자리를 다시 맞춰 주세요'), findsNothing);
  });

  testWidgets('타일 접근성 이름에 보조 줄이 들어간다', (tester) async {
    final handle = tester.ensureSemantics();
    _tall(tester);
    final api = _hub([
      _appliance('a', '전자레인지'),
      _appliance('b', '세탁기'),
      _appliance('d', '밥솥'),
    ], {
      'a': _json({'state': 'done', 'execution_mode': 'mock'}),
      'd': _json({'state': 'done', 'execution_mode': 'real'}),
    });
    await tester.pumpWidget(_home(api));
    await _settle(tester);
    // 사용자 결정(10/19): 타일은 이름, 오른쪽 위 표시가 자리 확인 문장을 그대로 읽는다(한 번씩).
    // 10/19 두 번째: 쉬는 누름 장치 가전은 이름과 함께 '지금 누르고 있지 않아요'(밝기만으로 말하지 않는다).
    expect(find.bySemanticsLabel('전자레인지, 지금 누르고 있지 않아요'), findsOneWidget);
    expect(find.bySemanticsLabel('연습으로만 자리 확인했어요'), findsOneWidget);
    expect(find.bySemanticsLabel('버튼 자리를 다시 맞춰 주세요'), findsOneWidget);
    expect(find.bySemanticsLabel('밥솥, 지금 누르고 있지 않아요'), findsOneWidget);
    handle.dispose();
  });

  // 검토 M4(2026-10-13): 같은 홈의 타일과 설정 카드가 같은 근거 수준으로 말한다.
  // '연습 주행을 확인했어요'는 모의 확인 주행을 **마친** 경우(done/mock)에만.
  for (final c in [
    (state: 'failed', label: '모의 실패'),
    (state: 'running', label: '모의 진행 중'),
  ]) {
    testWidgets('${c.label}이면 타일·설정 카드 모두 "확인하지 못했어요" — 확인했다고 하지 않는다',
        (tester) async {
      _tall(tester);
      final api = _hub([_appliance('a', '전자레인지')], {
        'a': _json({'state': c.state, 'execution_mode': 'mock'}),
      });
      await tester.pumpWidget(_home(api));
      await _settle(tester);
      final card = find.byType(ApplianceSetupCard);
      expect(card, findsOneWidget);
      expect(_inTile('a', '버튼 자리를 다시 맞춰 주세요'), findsOneWidget);
      expect(find.textContaining('주행을 확인했어요'), findsNothing,
          reason: '마치지 않은 모의 주행을 확인했다고 하지 않는다');
      expect(
          find.descendant(
              of: card, matching: findPlainText('버튼 자리를 다시 맞춰 주세요')),
          findsOneWidget);
    });
  }

  testWidgets('모의 확인 주행을 마쳤으면 설정 카드가 모의 확인을 말한다(보존)', (tester) async {
    _tall(tester);
    final api = _hub([_appliance('a', '전자레인지')], {
      'a': _json({'state': 'done', 'execution_mode': 'mock'}),
    });
    await tester.pumpWidget(_home(api));
    await _settle(tester);
    expect(_inTile('a', '연습으로만 자리 확인했어요'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(ApplianceSetupCard),
            matching: findPlainText('연습으로만 자리 확인했어요. 실제 자리는 아직 몰라요.')),
        findsOneWidget);
  });

  testWidgets('360×780·글씨 200%에서 보조 줄 타일이 넘치지 않고 다른 버튼을 가리지 않는다',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _hub([
      _appliance('a', '주방 전자레인지'),
      _appliance('b', '세탁기'),
    ], {
      'a': _json({'state': 'done', 'execution_mode': 'mock'}),
      'b': _json({'state': 'failed', 'execution_mode': 'real'}),
    }, routines: [
      {
        'id': 'r-b',
        'name': '저녁 데우기',
        'steps': [
          {'kind': 'press_sequence', 'appliance_id': 'a', 'buttons': ['시작']},
        ],
        'trigger': {'kind': 'manual'},
        'when': '직접 실행할 때',
        'mode': 'approve',
        'enabled': true,
      },
    ]);
    await tester.pumpWidget(_home(api, scale: 2.0));
    await _settle(tester);
    expect(tester.takeException(), isNull, reason: '넘침(overflow) 없음');

    final tileA = find.byKey(const Key('appliance-card-a'));
    final tileB = find.byKey(const Key('appliance-card-b'));
    final add = find.byKey(const Key('appliance-add-card'));
    final run = find.byKey(const Key('home-routine-tile-r-b'));
    expect(_inTile('a', '연습으로만 자리 확인했어요'), findsOneWidget);
    expect(_inTile('b', '자리 확인을 마치지 못했어요'), findsOneWidget);

    // 겹침 없음: 보조 줄 타일과 가전 추가가 서로 겹치지 않는다(루틴 타일은 가전 아래 다른 구획 — 아래에서 따로 누른다).
    for (final tile in [tileA, tileB]) {
      for (final other in [add]) {
        final overlap = tester.getRect(tile).intersect(tester.getRect(other));
        expect(overlap.width <= 0 || overlap.height <= 0, isTrue,
            reason: '$tile 과 $other 가 겹친다');
      }
    }
    // 각 버튼을 화면에 올려 가운데를 누르면 그 버튼에 닿는다.
    await tester.scrollUntilVisible(run, 200);
    await tester.pump();
    for (final target in [run, tileA, tileB, add]) {
      await tester.ensureVisible(target);
      await tester.pump();
      expect(_hits(tester, target), isTrue, reason: '$target 이 가려졌다');
    }
    expect(tester.takeException(), isNull);
  });
}
