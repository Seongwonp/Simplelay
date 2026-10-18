// 결선 심사 모의 평가(10/18, 합의 78점)에서 나온 폰 문제 — 단정 시험.
//
// 8. 홈 가전: 연습 가전은 '연습해 보기' 머리말 아래 따로 — 실제 '세탁기'(누름 장치용, 설정 필요)와 'LG 세탁기'(연습)가
//    나란히 있어 헷갈렸다. 이름 데이터는 그대로 둔다.
// 9. 루틴 탭: 줄마다 '지금 하기 / 고치기' 단추가 같은 무게로 되풀이됐다 — '고치기'는 줄 누르기(>)로만, '지금 하기'만 작은
//    단추. 목록 위에 표지 뜻 한 줄([다음] 다음에 할 루틴 · [자동] 묻지 않고 해요 — 줄의 표지와 같은 모양).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _custom(String id, String name, String category, {bool mapped = true}) => {
      'id': id,
      'name': name,
      'category': category,
      'rows': 1,
      'cols': 1,
      'is_custom': true,
      'revision': 1,
      'can_execute': true,
      'readiness': 'operable',
      'readiness_reasons': const <String>[],
      'buttons': [
        {'id': '$id-1', 'label': '시작', 'x': 0, 'y': 0},
      ],
      if (mapped)
        'panel_mapping': {
          'photo': {'width': 100, 'height': 100},
        },
    };

Map<String, dynamic> _thinq(String id, String name, String category) => {
      'id': id,
      'name': name,
      'category': category,
      'rows': 0,
      'cols': 0,
      'buttons': <dynamic>[],
      'control_path': 'thinq',
      'can_execute': true,
      'readiness': 'operable',
      'readiness_reasons': const <String>[],
    };

final _raw = [
  _custom('mw', '전자레인지', 'microwave'),
  _thinq('pwash', 'LG 세탁기(연습)', 'washing_machine'),
  _custom('washer', '세탁기', 'washing_machine', mapped: false),
  _thinq('air', '공기청정기', 'air_purifier'),
];
List<ApplianceMap> get _installed => [for (final j in _raw) ApplianceMap.fromJson(j)];

Map<String, dynamic> _press(String id, String name, String appliance) => {
      'schema_version': 1,
      'id': id,
      'name': name,
      'steps': [
        {'kind': 'press_sequence', 'appliance_id': appliance, 'buttons': ['$appliance-1']},
      ],
      'trigger': {'kind': 'manual'},
      'mode': 'approve',
      'enabled': true,
    };

Map<String, dynamic> _timed(String id, String name, String time) => {
      'schema_version': 1,
      'id': id,
      'name': name,
      'steps': [
        {'kind': 'thinq_command', 'appliance_id': 'air', 'action': 'set_power', 'args': {'power': 'POWER_ON'}},
      ],
      'trigger': {
        'kind': 'time',
        'days': [0, 1, 2, 3, 4, 5, 6],
        'time': time,
      },
      'when': '매일 $time',
      'mode': 'approve',
      'enabled': true,
    };

final _routines = [
  _press('r-mw', '30초 데우기', 'mw'),
  _timed('rt-eve', '저녁 공기청정기 켜기', '22:00'),
];

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

RpiApiService _api() => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (path == '/appliances') return _json(_raw);
        if (path == '/routines') return _json(_routines);
        if (path == '/routines/templates') return _json(const []);
        if (path == '/routines/next') {
          return _json([
            {
              'routine_id': 'rt-eve',
              'name': '저녁 공기청정기 켜기',
              'at': '2026-09-09T22:00:00+09:00',
              'when': '매일 22:00',
              'mode': 'approve',
              'mode_label': '자동 실행',
              'auto': true,
              'day_label': '오늘',
            },
          ]);
        }
        if (path == '/routines/auto-rules') return _json(const []);
        if (path == '/quiet-hours') {
          return _json({'enabled': false, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/history') return _json(const []);
        if (path == '/care-events') return _json(const []);
        if (path == '/suggestions') return _json(const []);
        if (path == '/thinq/power') return _json({'execution_mode': 'real', 'appliances': const []});
        return _json({'detail': 'not found'}, 404);
      }),
    );

Widget _app(Widget screen) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    GoRoute(path: '/routine/edit', builder: (_, __) => const Scaffold(body: Text('루틴 고치기 화면'))),
    GoRoute(
        path: '/appliance/detail/:id',
        builder: (_, s) => Scaffold(body: Text('가전 상세 ${s.pathParameters['id']}'))),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_api()),
    ],
    child: MaterialApp.router(theme: ThemeData.light(), routerConfig: router),
  );
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(411, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group("8. 홈 — 연습 가전은 '연습해 보기' 아래 따로", () {
    testWidgets('실제 가전은 위 가전 구역, 연습 가전은 연습해 보기 머리말 아래', (tester) async {
      await _pump(tester, const HomeScreen());
      final head = find.byKey(const Key('home-practice-section'));
      expect(head, findsOneWidget);
      expect(find.descendant(of: head, matching: findPlainText('연습해 보기')), findsOneWidget);
      final headY = tester.getTopLeft(head).dy;
      // 실제 가전(누름 장치 세탁기 포함)은 머리말 위, 연습 세탁기는 아래.
      for (final id in ['mw', 'washer', 'air']) {
        expect(tester.getTopLeft(find.byKey(Key('appliance-card-$id'))).dy, lessThan(headY), reason: id);
      }
      expect(tester.getTopLeft(find.byKey(const Key('appliance-card-pwash'))).dy, greaterThan(headY));
      // 같은 줄에 실제 세탁기와 연습 세탁기가 나란히 있지 않다.
      expect(tester.getTopLeft(find.byKey(const Key('appliance-card-washer'))).dy,
          isNot(closeTo(tester.getTopLeft(find.byKey(const Key('appliance-card-pwash'))).dy, 1)));
    });
  });

  group('9. 루틴 탭 — 고치기는 줄 누르기, 지금 하기만 작은 단추, 표지 뜻 한 줄', () {
    testWidgets("'고치기' 단추가 줄마다 되풀이되지 않는다 — 줄 누르기(>)로 고친다", (tester) async {
      await _pump(tester, const RoutinesScreen());
      expect(find.byKey(const Key('routine-row-r-mw')), findsOneWidget);
      expect(find.byKey(const Key('routine-edit-r-mw')), findsNothing);
      expect(find.byKey(const Key('routine-edit-rt-eve')), findsNothing);
      expect(findPlainText('고치기'), findsNothing);
      // 스위치가 있는 줄도 오른쪽 끝에 > 가 있다(줄을 누르면 고친다).
      final eveRow = find.byKey(const Key('routine-rt-eve'));
      expect(find.descendant(of: eveRow, matching: find.byIcon(Icons.chevron_right)), findsOneWidget);
      // 지금 하기는 그대로 — 작은 단추.
      expect(find.byKey(const Key('routine-run-r-mw')), findsOneWidget);
      await tester.tap(find.byKey(const Key('routine-r-mw')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('루틴 고치기 화면'), findsOneWidget);
    });

    testWidgets("목록 위 표지 뜻 한 줄 — [다음] 다음에 할 루틴 · [자동] 묻지 않고 해요", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final legend = find.byKey(const Key('routines-mark-legend'));
      expect(legend, findsOneWidget);
      for (final t in ['다음', '다음에 할 루틴', '자동', '묻지 않고 해요']) {
        expect(find.descendant(of: legend, matching: findPlainText(t)), findsOneWidget, reason: t);
      }
      // 첫 묶음 머리말보다 위.
      final firstGroup = find.byKey(const Key('routines-group-time'));
      expect(firstGroup, findsOneWidget);
      expect(tester.getTopLeft(legend).dy, lessThan(tester.getTopLeft(firstGroup).dy));
    });
  });
}
