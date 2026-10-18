// 접근성 감사(KWCAG/WCAG, 10/18 — 폰 84점)에서 나온 폰 문제 — 단정 시험.
//
// 6. 표기 통일: 연습 가전 화면 이름은 '연습 세탁기'(서버 이름 'LG 세탁기(연습)'은 데이터로만, 키오스크와 같은 규칙).
//    '확인 전이에요' 띠 아이콘은 본체와 같은 물음표(연습 가전도).
// 7. 루틴 스위치 바로 아래에 '켜짐'/'꺼짐' 글자(색만으로 말하지 않는다) — 내 루틴·자동 규칙 둘 다.
//    설정 탭은 점이 아니라 숫자 배지. 선택된 탭(내 루틴/자동 규칙)은 색 말고도 굵은 글자 + 밑줄.
//    자동 규칙 줄 ⋮ 단추의 누르는 자리 48dp 이상.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _custom(String id, String name, String category) => {
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
  _thinq('air', '공기청정기', 'air_purifier'),
];
List<ApplianceMap> get _installed => [for (final j in _raw) ApplianceMap.fromJson(j)];

Map<String, dynamic> _timed(String id, String name, String time, {required bool enabled}) => {
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
      'enabled': enabled,
    };

final _routines = [
  _timed('rt-eve', '저녁 공기청정기 켜기', '22:00', enabled: true),
  _timed('rt-morn', '아침 공기청정기 끄기', '07:00', enabled: false),
];

Map<String, dynamic> _rule({required bool enabled}) => {
      'id': 'ar-1',
      'scenario_id': 'cook_done_air',
      'name': '전자레인지가 멈추면 공기청정기 세게',
      'condition_text': '전자레인지가 멈추면',
      'action_text': '공기청정기 풍량 강으로',
      'action': 'set_wind_strength',
      'value': 'HIGH',
      'allowed_values': [
        {'value': 'LOW', 'label': '약'},
        {'value': 'HIGH', 'label': '강'},
      ],
      'enabled': enabled,
      'status_label': enabled ? '자동 실행 켜짐' : '자동 실행 꺼짐',
      'fingerprint': 'fp-1',
    };

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

RpiApiService _api({bool ruleEnabled = true}) => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (path == '/appliances') return _json(_raw);
        if (path == '/routines') return _json(_routines);
        if (path == '/routines/templates') return _json(const []);
        if (path == '/routines/next') return _json(const []);
        if (path == '/routines/auto-rules') return _json([_rule(enabled: ruleEnabled)]);
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

Widget _app(Widget screen, {bool ruleEnabled = true}) {
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
      rpiApiServiceProvider.overrideWithValue(_api(ruleEnabled: ruleEnabled)),
    ],
    child: MaterialApp.router(theme: ThemeData.light(), routerConfig: router),
  );
}

Future<void> _pump(WidgetTester tester, Widget screen, {bool ruleEnabled = true}) async {
  tester.view.physicalSize = const Size(411, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, ruleEnabled: ruleEnabled));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 탭 이름 글자의 모양(굵기·밑줄).
TextStyle _segmentStyle(WidgetTester tester, String label) {
  final text = tester.widget<Text>(findPlainText(label).first);
  final rich = tester.widget<RichText>(find.descendant(of: findPlainText(label).first, matching: find.byType(RichText)));
  return (rich.text.style ?? const TextStyle()).merge(text.style);
}

class _SeededCare extends CareEventsNotifier {
  _SeededCare(super.ref, CareEventsState seed) {
    state = seed;
  }

  @override
  Future<void> refresh() async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('6. 표기 통일', () {
    test("연습 가전 화면 이름은 '연습 세탁기' — 서버 이름은 그대로, 실제 가전 이름은 그대로", () {
      final practice = _installed.firstWhere((a) => a.id == 'pwash');
      expect(practice.name, 'LG 세탁기(연습)');
      expect(applianceTileName(practice), '연습 세탁기');
      expect(applianceTileName(_installed.firstWhere((a) => a.id == 'air')), '공기청정기');
    });

    testWidgets("홈 가전 카드에 '연습 세탁기'", (tester) async {
      await _pump(tester, const HomeScreen());
      final card = find.byKey(const Key('appliance-card-pwash'));
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: findPlainText('연습 세탁기')), findsOneWidget);
      expect(find.descendant(of: card, matching: findPlainText('LG 세탁기')), findsNothing);
    });

    testWidgets("연습 가전 '확인 전이에요' 띠는 물음표 아이콘(본체와 같은 모양)", (tester) async {
      await _pump(tester, const HomeScreen());
      final status = find.byKey(const Key('appliance-status-pwash'));
      expect(find.descendant(of: status, matching: findPlainText(kThinqUncheckedText)), findsOneWidget);
      expect(find.descendant(of: status, matching: find.byIcon(Icons.help_outline)), findsOneWidget);
      expect(find.descendant(of: status, matching: find.byIcon(Icons.science_outlined)), findsNothing);
    });
  });

  group('7. 루틴 탭', () {
    testWidgets("정해진 시각 루틴 스위치 바로 아래 '켜짐'/'꺼짐' 글자", (tester) async {
      await _pump(tester, const RoutinesScreen());
      for (final (id, word) in [('rt-eve', '켜짐'), ('rt-morn', '꺼짐')]) {
        final sw = find.byKey(Key('routine-switch-$id'));
        expect(sw, findsOneWidget, reason: id);
        final text = find.byKey(Key('routine-switch-text-$id'));
        expect(text, findsOneWidget, reason: id);
        expect(tester.widget<Text>(text).data, word, reason: id);
        // 스위치 바로 아래(가로 가운데가 같고, 스위치 아래 끝에 붙어 있다).
        expect((tester.getCenter(text).dx - tester.getCenter(sw).dx).abs(), lessThan(2), reason: id);
        expect(tester.getTopLeft(text).dy - tester.getBottomLeft(sw).dy, inInclusiveRange(-1, 4), reason: id);
      }
    });

    testWidgets('선택된 탭은 굵은 글자 + 밑줄 — 고르지 않은 탭은 밑줄 없음', (tester) async {
      await _pump(tester, const RoutinesScreen());
      var mine = _segmentStyle(tester, '내 루틴');
      var rules = _segmentStyle(tester, '자동 규칙');
      expect(mine.decoration, TextDecoration.underline);
      expect(mine.fontWeight!.value, greaterThanOrEqualTo(FontWeight.w700.value));
      expect(rules.decoration ?? TextDecoration.none, TextDecoration.none);
      await tester.tap(findPlainText('자동 규칙'));
      await _settle(tester);
      mine = _segmentStyle(tester, '내 루틴');
      rules = _segmentStyle(tester, '자동 규칙');
      expect(rules.decoration, TextDecoration.underline);
      expect(rules.fontWeight!.value, greaterThanOrEqualTo(FontWeight.w700.value));
      expect(mine.decoration ?? TextDecoration.none, TextDecoration.none);
    });

    for (final enabled in [true, false]) {
      testWidgets("자동 규칙 스위치 바로 아래 '${enabled ? '켜짐' : '꺼짐'}' 글자, ⋮ 누르는 자리 48dp 이상", (tester) async {
        await _pump(tester, const RoutinesScreen(), ruleEnabled: enabled);
        await tester.tap(findPlainText('자동 규칙'));
        await _settle(tester);
        final sw = find.byKey(const Key('auto-rule-switch-ar-1'));
        expect(sw, findsOneWidget);
        final text = find.byKey(const Key('auto-rule-switch-text-ar-1'));
        expect(text, findsOneWidget);
        expect(tester.widget<Text>(text).data, enabled ? '켜짐' : '꺼짐');
        expect((tester.getCenter(text).dx - tester.getCenter(sw).dx).abs(), lessThan(2));
        expect(tester.getTopLeft(text).dy - tester.getBottomLeft(sw).dy, inInclusiveRange(-1, 4));
        final menu = tester.getSize(find.byKey(const Key('auto-rule-menu-ar-1')));
        expect(menu.width, greaterThanOrEqualTo(48));
        expect(menu.height, greaterThanOrEqualTo(48));
      });
    }
  });

  group('7. 설정 탭 — 점이 아니라 숫자 배지', () {
    GoRouter router() => GoRouter(
          initialLocation: '/',
          routes: [
            StatefulShellRoute.indexedStack(
              builder: (_, __, shell) => AppShell(navigationShell: shell),
              branches: [
                for (final p in ['/', '/routines', '/history', '/settings'])
                  StatefulShellBranch(routes: [
                    GoRoute(path: p, builder: (_, __) => Text('body $p')),
                  ]),
              ],
            ),
          ],
        );

    Future<void> pumpShell(WidgetTester tester, CareEventsState s) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          developerModeProvider.overrideWithValue(false),
          careEventsProvider.overrideWith((ref) => _SeededCare(ref, s)),
        ],
        child: MaterialApp.router(routerConfig: router()),
      ));
      await tester.pump();
      await tester.pump();
    }

    List<RpiCareEvent> events(int n) => [
          for (var i = n; i >= 1; i--)
            RpiCareEvent(id: i, kind: 'execution_failed', message: '실패 $i', occurredAt: DateTime(2026, 10, 13, 8, i)),
        ];

    testWidgets('안 본 알림 3건이면 설정 탭에 숫자 3 배지(색만으로 말하지 않는다)', (tester) async {
      await pumpShell(tester, CareEventsState(events: events(3), status: CareInboxStatus.ready));
      final badge = find.byKey(const Key('settings-unread-badge'));
      expect(badge, findsOneWidget);
      expect(find.descendant(of: badge, matching: find.text('3')), findsOneWidget);
    });

    testWidgets('100건 이상은 99+', (tester) async {
      await pumpShell(tester, CareEventsState(events: events(120), status: CareInboxStatus.ready));
      expect(find.descendant(of: find.byKey(const Key('settings-unread-badge')), matching: find.text('99+')),
          findsOneWidget);
    });

    testWidgets('0건이면 배지가 없다', (tester) async {
      await pumpShell(tester, const CareEventsState(events: [], status: CareInboxStatus.ready));
      expect(find.byKey(const Key('settings-unread-badge')), findsNothing);
    });
  });
}
