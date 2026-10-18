// 평가 14차(2026-10-18, 폰 92 — 'AI 느낌' 점검).
//
// 1. 기록: 연달아 같은 일·같은 결과는 한 줄로 묶는다('3번 못 했어요', 펼치면 각 회차). 실패 줄에는 기록에 있는
//    이유 한 줄(서버 detail 첫 문장) — 근거가 없으면 지어내지 않는다. 'LG 가전'은 묶음에 한 번. 이름은 낱말 묶음으로
//    꺾는다('중간으로 하기'). 성공 줄은 칩 없이 작은 기호·글자, 회색 원 아이콘도 없다.
// 2. 루틴 탭: 시각 루틴에 붙은 자동 규칙은 '자동 규칙' 탭에 따로 두지 않고 루틴 줄의 '자동' 표시를 누르면 그 스위치.
//    루틴에 닿지 않는 규칙은 탭에 그대로 남는다(자동 실행을 끄는 길은 늘 한 군데 이상).
// 3. 이름: 폰 홈·루틴 줄은 '자동', 탭은 '자동 규칙'. '자동으로 해요'·'자동으로 하기'는 화면에 없다.
// 4. 장식: 루틴 묶음 머리 아이콘·규칙 카드 순환 아이콘·이름을 되풀이하는 설명 없음. 설정의 하트·해 아이콘 바꿈.
// 5. 홈: '지금 우리 집'은 면 없이, '확인이 필요해요'는 할 일이 있을 때만 색, 가전 카드의 'LG 가전'은 작은 글자.
// 6. 말투: 설정 LG 가전 부제·규칙 탭 안내는 '~해요'를 잇달아 쓰지 않는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/auto_rule.dart';
import 'package:simplelay/models/line_break.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_icons.dart';
import 'package:simplelay/widgets/route_badge.dart';
import 'package:simplelay/widgets/status_badge.dart';

import '../helpers/test_helpers.dart';

const _air = {
  'id': 'air',
  'name': '공기청정기',
  'category': 'air_purifier',
  'rows': 1,
  'cols': 1,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
  'readiness_reasons': <String>[],
};

List<ApplianceMap> get _installed => [ApplianceMap.fromJson(_air)];

const _offDetail = '가전이 꺼져 있어 이 명령을 받을 수 없어요. 먼저 켜 주세요.';

Map<String, dynamic> _hist(String id, String purpose, String at,
        {bool ok = true, String detail = '', String day = '18'}) =>
    {
      'job_id': id,
      'finished_at': '2026-10-${day}T$at:00',
      'status': ok ? 'succeeded' : 'failed',
      'outcome': ok ? 'success' : 'failed',
      'retry_count': 0,
      'buttons': const [],
      'execution_mode': 'real',
      'route': 'thinq',
      'receipt': ok ? 'accepted' : 'rejected',
      'confirmation': ok ? 'state_confirmed' : 'none',
      'purpose': purpose,
      'detail': detail,
      'appliance_id': 'air',
    };

final _history = [
  _hist('h-on', '공기청정기 켜줘', '13:06'),
  _hist('f-1', '공기청정기 바람 중간으로 해줘', '13:00', ok: false, detail: _offDetail),
  _hist('f-2', '공기청정기 바람 중간으로 해줘', '13:00', ok: false, detail: _offDetail),
  _hist('f-3', '공기청정기 바람 중간으로 해줘', '12:59', ok: false, detail: _offDetail),
  // 같은 일이지만 결과가 다르다 — 묶지 않는다.
  _hist('h-mid', '공기청정기 바람 중간으로 해줘', '12:58'),
  // 이유가 기록에 없는 실패 — 이유 줄을 지어내지 않는다.
  _hist('f-bare', '공기청정기 꺼줘', '12:00', ok: false),
  // 다른 날의 같은 일 — 날짜를 넘어 묶지 않는다.
  _hist('f-old', '공기청정기 꺼줘', '12:00', ok: false, day: '17'),
];

Map<String, dynamic> _timeRoutine(String id, String name, String time) => {
      'schema_version': 1,
      'id': id,
      'name': name,
      'steps': [
        {
          'kind': 'thinq_command',
          'appliance_id': 'air',
          'action': 'set_power',
          'args': {'power': 'POWER_ON'},
        },
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

Map<String, dynamic> _rule(String id, String name,
        {String kind = 'time', String? time, bool enabled = true, String value = 'POWER_ON'}) =>
    {
      'id': id,
      'scenario_id': kind == 'time' ? 'routine_time' : 'cook_done_air',
      'name': name,
      'condition_kind': kind,
      'condition_time': time,
      'condition_text': kind == 'time' ? '매일 밤 10시에' : '전자레인지가 데우기를 멈추면',
      'action_text': kind == 'time' ? '공기청정기를 켜요' : '공기청정기 바람을 세게 해요',
      'action': kind == 'time' ? 'set_power' : 'set_wind_strength',
      'value': value,
      'allowed_values': kind == 'time'
          ? const []
          : const [
              {'value': 'MID', 'label': '중'},
              {'value': 'HIGH', 'label': '강'},
            ],
      'enabled': enabled,
      'status_label': enabled ? '자동 실행 켜짐' : '자동 실행 꺼짐',
      'disabled_reason': null,
      'fingerprint': 'fp-$id',
    };

class _Hub {
  List<Map<String, dynamic>> rules = [
    _rule('ar-t', '저녁 공기청정기 켜기', time: '22:00'),
    _rule('ar-s', '데우기가 끝나면 공기청정기 세게', kind: 'event', value: 'HIGH'),
  ];
  final requests = <String>[];
  final bodies = <String, Map<String, dynamic>>{};

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)), status,
      headers: {'content-type': 'application/json'});

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          requests.add('${req.method} $path');
          if (req.bodyBytes.isNotEmpty) {
            bodies['${req.method} $path'] = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>;
          }
          if (path.startsWith('/execute') || path.endsWith('/approve')) {
            fail('실행 경로를 불렀어요: ${req.method} $path');
          }
          if (path == '/appliances') return _json([_air]);
          if (req.method == 'GET' && path == '/routines') {
            return _json([
              _timeRoutine('rt-eve', '저녁 공기청정기 켜기', '22:00'),
            ]);
          }
          if (path == '/routines/templates') return _json(const []);
          if (path == '/routines/next') {
            return _json([
              {
                'routine_id': 'rt-eve',
                'name': '저녁 공기청정기 켜기',
                'at': '2026-10-18T22:00:00+09:00',
                'when': '매일 22:00',
                'mode': 'approve',
                'mode_label': '승인 후 실행',
                'auto': true,
                'day_label': '오늘',
              },
            ]);
          }
          if (req.method == 'GET' && path == '/routines/auto-rules') return _json(rules);
          final enable = RegExp(r'^/routines/auto-rules/([^/]+)/enable$').firstMatch(path);
          if (req.method == 'POST' && enable != null) {
            final id = enable.group(1)!;
            final on = bodies['POST $path']!['enabled'] == true;
            rules = [
              for (final r in rules) r['id'] == id ? {...r, 'enabled': on} : r,
            ];
            return _json(rules.firstWhere((r) => r['id'] == id));
          }
          if (path == '/quiet-hours') {
            return _json({'enabled': false, 'start': '22:00', 'end': '07:00', 'active': false});
          }
          if (path == '/history') return _json(_history);
          if (path == '/care-events') return _json(const []);
          if (path == '/suggestions') return _json(const []);
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _app(Widget screen, _Hub hub) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    GoRoute(path: '/routine/edit', builder: (_, __) => const Scaffold(body: Text('루틴 편집기'))),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(hub.api()),
    ],
    child: MaterialApp.router(theme: ThemeData.light(), routerConfig: router),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester tester, Widget screen, _Hub hub, {double width = 411}) async {
  tester.view.physicalSize = Size(width, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, hub));
  await _settle(tester);
}

Finder _in(Finder parent, Finder child) => find.descendant(of: parent, matching: child);

/// 화면 글자(결합 문자·줄바꿈 없는 빈칸은 그대로).
String _raw(WidgetTester tester, Finder f) {
  final t = tester.widget<Text>(f);
  return t.data ?? t.textSpan!.toPlainText();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('1. 기록 — 같은 일·같은 결과는 한 줄, 실패에는 이유', () {
    testWidgets("연달아 세 번 못 한 일은 한 줄 '3번 못 했어요', 펼치면 각 회차", (tester) async {
      await _pump(tester, const HistoryScreen(), _Hub());
      final row = find.byKey(const ValueKey('history-f-1'));
      expect(row, findsOneWidget);
      expect(find.byKey(const ValueKey('history-f-2')), findsNothing);
      expect(find.byKey(const ValueKey('history-f-3')), findsNothing);
      expect(_in(row, findPlainText('3번 못 했어요')), findsOneWidget);
      // 'LG 가전'은 묶음에 한 번.
      expect(_in(row, findPlainText('LG 가전', contains: true)), findsOneWidget);
      // 결과가 다른 같은 일·다른 날은 따로.
      expect(find.byKey(const ValueKey('history-h-mid')), findsOneWidget);
      expect(find.byKey(const ValueKey('history-f-old')), findsOneWidget);

      await tester.tap(find.byKey(const Key('history-tap-f-1')));
      await _settle(tester);
      for (final id in ['f-1', 'f-2', 'f-3']) {
        expect(find.byKey(Key('history-sub-$id')), findsOneWidget, reason: id);
      }
      // 펼쳐도 'LG 가전'을 회차마다 되풀이하지 않는다.
      expect(_in(row, findPlainText('LG 가전', contains: true)), findsOneWidget);
    });

    testWidgets('실패 줄의 이유는 기록 문장 그대로, 없으면 지어내지 않는다', (tester) async {
      await _pump(tester, const HistoryScreen(), _Hub());
      final reason = find.byKey(const Key('history-reason-f-1'));
      expect(reason, findsOneWidget);
      // 평가 15차(10/18): 기록 문장의 근거(꺼짐 거절)를 쉬운 말로 — '명령' 없이(eval15_phone_test 4).
      expect(tester.widget<Text>(reason).semanticsLabel, '공기청정기가 꺼져 있어서 바람 세기를 바꿀 수 없었어요');
      expect(find.byKey(const Key('history-reason-f-bare')), findsNothing);
    });

    testWidgets("이름은 낱말 묶음으로 꺾는다 — '하기'만 홀로 다음 줄에 가지 않는다", (tester) async {
      await _pump(tester, const HistoryScreen(), _Hub());
      final title = _raw(tester, find.byKey(const Key('history-title-f-1')));
      expect(title.replaceAll(kWordJoiner, ''), contains('중간으로 하기'));
    });

    testWidgets('성공 줄은 칩 없이 조용히, 실패 줄만 칩 — 회색 원 아이콘 없음', (tester) async {
      await _pump(tester, const HistoryScreen(), _Hub());
      final ok = find.byKey(const ValueKey('history-h-on'));
      expect(_in(ok, find.byType(StatusBadge)), findsNothing);
      // 성공 줄도 무엇을 확인했는지 짧게 — 상태를 다시 읽은 켜기는 '켜짐 확인'(낭독은 '됐어요, 켜짐 확인').
      expect(_in(ok, findPlainText('켜짐 확인')), findsOneWidget);
      expect(tester.widget<Text>(_in(ok, findPlainText('켜짐 확인'))).semanticsLabel, '됐어요, 켜짐 확인');
      expect(_in(find.byKey(const ValueKey('history-h-mid')), findPlainText('바뀐 상태 확인')), findsOneWidget);
      expect(_in(find.byKey(const ValueKey('history-f-1')), find.byType(StatusBadge)), findsOneWidget);
      final circles = find.ancestor(
        of: find.byKey(const Key('history-icon-h-on')),
        matching: find.byWidgetPredicate((w) =>
            w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).shape == BoxShape.circle),
      );
      expect(circles, findsNothing);
    });
  });

  group('1-2. 성공 줄의 확인 말 — 기록의 확인 수준에서만', () {
    RpiHistoryEntry h(String purpose,
            {String route = 'thinq', String confirmation = 'state_confirmed', String mode = 'real', String outcome = 'success'}) =>
        RpiHistoryEntry.fromJson({
          'job_id': 'j',
          'finished_at': '2026-10-18T22:00:00',
          'status': outcome == 'success' ? 'succeeded' : 'failed',
          'outcome': outcome,
          'retry_count': 0,
          'buttons': const [],
          'execution_mode': mode,
          'route': route,
          'confirmation': confirmation,
          'purpose': purpose,
        });

    test('확인한 것만 확인했다고 말한다', () {
      expect(historyConfirmedPhrase(h('자동 실행 · 공기청정기 켜기')), '켜짐 확인');
      expect(historyConfirmedPhrase(h('공기청정기 꺼줘', confirmation: 'state_confirmed_unknown_before')), '꺼짐 확인');
      expect(historyConfirmedPhrase(h('공기청정기 바람 세게 해줘')), '바뀐 상태 확인');
      expect(historyConfirmedPhrase(h('공기청정기 꺼줘', confirmation: 'already_at_target')), '이미 그 상태');
      // 루틴은 이름이 한 일을 다 말하지 않을 수 있다.
      expect(historyConfirmedPhrase(h("자동 실행 · '저녁 공기청정기 켜기' 루틴")), '상태 확인');
      expect(historyConfirmedPhrase(h('즉석밥 데워줘', route: 'physical', confirmation: 'operation_confirmed')), '동작 확인');
      expect(historyConfirmedPhrase(h('즉석밥 데워줘', route: 'physical', confirmation: 'press_confirmed')), '눌림 확인');
      // 확인하지 않은 것 — 접수만·보고만·연습·실패는 말하지 않는다.
      expect(historyConfirmedPhrase(h('공기청정기 켜줘', confirmation: 'accepted')), isNull);
      expect(historyConfirmedPhrase(h('즉석밥 데워줘', route: 'physical', confirmation: 'none')), isNull);
      expect(historyConfirmedPhrase(h('공기청정기 켜줘', mode: 'mock')), isNull);
      expect(historyConfirmedPhrase(h('공기청정기 켜줘', outcome: 'failed')), isNull);
    });
  });

  group('2·3. 루틴 탭 — 시각 루틴 규칙은 루틴 줄에서, 탭은 자동 규칙만', () {
    testWidgets("탭 이름은 '자동 규칙', 시각 루틴 규칙은 탭에 따로 없다", (tester) async {
      await _pump(tester, const RoutinesScreen(), _Hub());
      expect(findPlainText('자동 규칙'), findsOneWidget);
      expect(findPlainText('자동으로 하기'), findsNothing);
      await tester.tap(findPlainText('자동 규칙'));
      await _settle(tester);
      expect(find.byKey(const Key('auto-rule-ar-s')), findsOneWidget);
      expect(find.byKey(const Key('auto-rule-ar-t')), findsNothing);
    });

    testWidgets("루틴 줄 '자동'을 누르면 그 규칙 스위치 — 끄면 본체에 끄기를 보낸다", (tester) async {
      final hub = _Hub();
      await _pump(tester, const RoutinesScreen(), hub);
      final mark = find.byKey(const Key('routine-auto-badge-rt-eve'));
      expect(mark, findsOneWidget);
      await tester.tap(mark);
      await _settle(tester);
      expect(findPlainText('루틴 편집기'), findsNothing, reason: "'자동'은 편집이 아니라 스위치로");
      final sw = find.byKey(const Key('auto-rule-switch-ar-t'));
      expect(sw, findsOneWidget);
      await tester.tap(sw);
      await _settle(tester);
      expect(hub.requests, contains('POST /routines/auto-rules/ar-t/enable'));
      expect(hub.bodies['POST /routines/auto-rules/ar-t/enable']?['enabled'], false);
    });

    testWidgets('루틴에 닿지 않는 시각 규칙은 탭에 남는다(끄는 길을 잃지 않게)', (tester) async {
      final hub = _Hub()..rules = [_rule('ar-x', '자동 실행', time: '06:00')];
      await _pump(tester, const RoutinesScreen(), hub);
      await tester.tap(findPlainText('자동 규칙'));
      await _settle(tester);
      expect(find.byKey(const Key('auto-rule-switch-ar-x')), findsOneWidget);
    });

    testWidgets("꺼 둔 시각 루틴 규칙도 루틴 줄에서 닿는다('자동 꺼짐')", (tester) async {
      final hub = _Hub()..rules = [_rule('ar-t', '저녁 공기청정기 켜기', time: '22:00', enabled: false)];
      await _pump(tester, const RoutinesScreen(), hub);
      // /routines/next가 auto라고 해도 규칙이 꺼져 있으면 꺼짐을 말한다 — 규칙 값이 먼저.
      final mark = find.byKey(const Key('routine-auto-badge-rt-eve'));
      expect(_in(mark, findPlainText('자동 꺼짐')), findsOneWidget);
      await tester.tap(mark);
      await _settle(tester);
      expect(find.byKey(const Key('auto-rule-switch-ar-t')), findsOneWidget);
    });
  });

  group('4·6. 장식·말투', () {
    testWidgets('루틴 묶음 머리에 아이콘이 없다', (tester) async {
      await _pump(tester, const RoutinesScreen(), _Hub());
      final head = find.byKey(const Key('routines-group-time'));
      expect(head, findsOneWidget);
      expect(_in(head, find.byType(Icon)), findsNothing);
    });

    testWidgets('규칙 카드에 순환 아이콘이 없고, 이름을 되풀이하는 설명도 없다', (tester) async {
      await _pump(tester, const RoutinesScreen(), _Hub());
      await tester.tap(findPlainText('자동 규칙'));
      await _settle(tester);
      final card = find.byKey(const Key('auto-rule-ar-s'));
      expect(_in(card, find.byIcon(AppIcons.auto)), findsNothing);
      expect(_in(card, findPlainText('공기청정기 바람을 세게 해요', contains: true)), findsNothing);
      // 안내 한 줄에 '~요.'를 잇달아 쓰지 않는다.
      final intro = tester.widget<Text>(find.byKey(const Key('auto-rules-intro-text'))).semanticsLabel!;
      expect('요.'.allMatches(intro).length, lessThanOrEqualTo(1), reason: intro);
    });

    test('값을 바꿔 이름과 달라진 규칙은 설명을 남긴다', () {
      // 이름은 '세게'인데 값이 중간 — 이름만 보면 틀린다.
      AutoRule wind(String value) => AutoRule(
          id: 'x',
          name: '데우기가 끝나면 공기청정기 세게',
          conditionText: '전자레인지가 데우기를 멈추면',
          actionText: '공기청정기 바람을 ${value == 'MID' ? '중간으로' : '세게'} 해요',
          enabled: true,
          statusLabel: '',
          action: 'set_wind_strength',
          value: value);
      expect(autoRuleNameSaysAll(wind('MID')), isFalse);
      expect(autoRuleNameSaysAll(wind('HIGH')), isTrue);
    });

    test("설정의 LG 가전 부제는 '~해요'로 끝나지 않는 짧은 말", () {
      for (final line in kThinqSubtitleLines) {
        expect(line.endsWith('해요'), isFalse, reason: line);
      }
    });

    testWidgets('설정: 집 비우는 날에 하트, 어두운 화면에 해 아이콘을 쓰지 않는다', (tester) async {
      await _pump(tester, const SettingsScreen(), _Hub());
      expect(find.byIcon(Icons.favorite_outline), findsNothing);
      expect(find.byIcon(Icons.light_mode), findsNothing);
    });
  });

  group('3·5. 홈', () {
    testWidgets("'지금 우리 집'은 면 없이, 다음 루틴 자동 표시는 '자동'", (tester) async {
      await _pump(tester, const HomeScreen(), _Hub());
      final now = find.byKey(const Key('home-now'));
      expect(now, findsOneWidget);
      final box = tester.widget<Container>(now);
      final deco = box.decoration as BoxDecoration?;
      expect(deco?.color, isNull);
      expect(findPlainText('자동으로 해요'), findsNothing);
      expect(_in(now, find.byKey(const Key('home-next-auto'))), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('home-next-auto'))).data, '자동');
      // 제목이 주인공 — 작은 회색 글자가 아니다.
      final title = tester.widget<Text>(_in(now, findPlainText('지금 우리 집')));
      expect(title.style?.fontWeight, FontWeight.w700);
    });

    testWidgets("가전 카드의 'LG 가전'은 테두리 칩이 아니라 작은 글자", (tester) async {
      await _pump(tester, const HomeScreen(), _Hub());
      final card = find.byKey(const Key('appliance-card-air'));
      expect(_in(card, find.byType(RouteBadge)), findsNothing);
      expect(_in(card, findPlainText('LG 가전')), findsOneWidget);
    });
  });

  test('줄바꿈 도우미: 짧은 끝 낱말은 앞 낱말에 붙는다', () {
    String plain(String t) => keepActionNameTogether(t).replaceAll(kWordJoiner, '');
    expect(plain('공기청정기 바람 중간으로 하기'), '공기청정기 바람 중간으로 하기');
    expect(plain('문 열기'), '문 열기');
    // 끝 낱말이 길면 그대로(앞 낱말과 붙이지 않는다).
    expect(plain('공기청정기 켜기 시작하기'), '공기청정기 켜기 시작하기');
  });
}
