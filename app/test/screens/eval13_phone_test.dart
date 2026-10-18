// 평가 13차(2026-10-18, 폰 92.5).
//
// 1. 홈 '확인이 필요해요'의 안 본 알림 줄: '자동으로 한 일·루틴 안내 알림 4건, 아직 안 봤어요'(분류 나열·어절 끊김·
//    문제 아닌데 주황) → '안 본 알림 4건' 하나의 이름. 설정 줄·탭 접근성 이름도 같은 말. 경고색은 실제로 볼 것이
//    있을 때만(설정이 남았어요, 실패·정지 같은 알림이 섞였을 때) — 그때만 '못 한 일이 있어요' 같은 짧은 말을 붙인다.
// 2. 기록: LG 가전 자동 실행은 가전 아이콘 + '자동 · LG 가전'. 누름 장치 가전의 자동 실행은 기존대로(자동 아이콘·'자동').
// 3. 기록 시각 줄: 가운뎃점이 줄 머리에 오지 않는다. '사람이 직접' 대신 사실에 맞는 말 — 목적 없이 버튼을 고른
//    실행(/execute-buttons)은 '화면에서 골라 누름', 그 밖(말·제안)은 '바로 실행'.
// 4. 시각 표기: 본체 알림 문장의 '밤 10시'도 '오후 10:00' 꼴로.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/clock_text.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/line_break.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/care_events_screen.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_colors.dart';
import 'package:simplelay/theme/app_icons.dart';
import 'package:simplelay/theme/app_tokens.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _appliance(String id, String name, String category) => {
      'id': id,
      'name': name,
      'category': category,
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
      'panel_mapping': {
        'photo': {'width': 100, 'height': 100},
      },
    };

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

final _mw = _appliance('mw', '전자레인지', 'microwave');

List<Map<String, dynamic>> _rawAppliances = [_mw, _air];
List<ApplianceMap> get _installed => [for (final j in _rawAppliances) ApplianceMap.fromJson(j)];

Map<String, dynamic> _hist(String id, String? purpose,
        {String route = 'thinq', String confirmation = 'state_confirmed', String? appliance, String at = '10:51'}) =>
    {
      'job_id': id,
      'finished_at': '2026-10-18T$at:00',
      'status': 'succeeded',
      'outcome': 'success',
      'retry_count': 0,
      'buttons': route == 'physical'
          ? [
              {'button': '시작', 'success': true, 'attempts': 1},
            ]
          : const [],
      'execution_mode': 'real',
      'route': route,
      'confirmation': confirmation,
      'purpose': purpose,
      if (appliance != null) 'appliance_id': appliance,
    };

final _history = [
  // 시각 규칙이 묻지 않고 끈 LG 공기청정기(루틴 없이 가전 동작).
  _hist('j-auto-lg', '자동 실행 · 공기청정기 끄기', appliance: 'air', at: '07:00'),
  // 누름 장치 가전의 자동 실행 — 기존대로 '자동'.
  _hist('j-auto-arm', '자동 실행 · 전자레인지 시작 누르기', route: 'physical', appliance: 'mw', at: '09:00'),
  // 수동 조작 화면에서 버튼을 골라 누름(/execute-buttons — 목적 없음).
  _hist('j-manual', null, route: 'physical', appliance: 'mw', at: '12:05'),
  // 말·제안으로 시작(목적 문장 있음).
  _hist('j-voice', '즉석밥 데워줘', route: 'physical', appliance: 'mw', at: '08:40'),
];

List<Map<String, dynamic>> _careJson = const [];

Map<String, dynamic> _care(int id, String kind, [String? message]) => {
      'id': id,
      'kind': kind,
      'message': message ?? '알림 $id',
      'occurred_at': '2026-10-18T08:0$id:00',
    };

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

RpiApiService _api() => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (path.startsWith('/execute') || path.endsWith('/approve')) {
          fail('실행 경로를 불렀어요: ${req.method} $path');
        }
        if (path == '/appliances') return _json(_rawAppliances);
        if (path == '/routines') return _json(const []);
        if (path == '/routines/next') return _json(const []);
        if (path == '/routines/auto-rules') return _json(const []);
        if (path == '/quiet-hours') {
          return _json({'enabled': true, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/history') return _json(_history);
        if (path == '/care-events') return _json(_careJson);
        if (path == '/suggestions') return _json(const []);
        return _json({'detail': 'not found'}, 404);
      }),
    );

Widget _app(Widget screen, {List<ApplianceMap>? installed}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(installed ?? _installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_api()),
    ],
    child: MaterialApp.router(theme: ThemeData.light(), routerConfig: router),
  );
}

Future<void> _pump(WidgetTester tester, Widget screen, {List<ApplianceMap>? installed, double width = 411}) async {
  tester.view.physicalSize = Size(width, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, installed: installed));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _in(Finder parent, Finder child) => find.descendant(of: parent, matching: child);

RpiCareEvent _ev(int id, String kind) =>
    RpiCareEvent(id: id, kind: kind, message: '알림 $id', occurredAt: DateTime(2026, 10, 18, 8, id));

/// 안 본 알림 줄의 글자 색.
Color? _careRowColor(WidgetTester tester) {
  final row = find.byKey(const Key('home-attention-care'));
  final text = tester.widget<Text>(_in(row, findPlainText('안 본 알림', contains: true)));
  return text.style?.color;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _careJson = const [];
    _rawAppliances = [_mw, _air];
  });

  group('1. 안 본 알림 — 이름 하나, 경고색은 볼 것이 있을 때만', () {
    test("자동으로 한 일·루틴 안내뿐이면 '안 본 알림 N건'만", () {
      expect(careAttentionText([_ev(4, 'auto_rule'), _ev(3, 'auto_rule'), _ev(2, 'routine_notice'), _ev(1, 'auto_rule')]),
          '안 본 알림 4건');
      expect(careNeedsLook([_ev(2, 'auto_rule'), _ev(1, 'routine_announce')]), isFalse);
      expect(careAttentionText([_ev(1, 'something_new')]), '안 본 알림 1건');
    });

    test('실패·정지가 섞이면 짧은 말 하나를 붙인다(가장 무거운 것)', () {
      // 평가 15차(10/18): 볼 것은 그 갈래·건수, 나머지는 따로 '안 본 알림 N건'(eval15_phone_test 5).
      expect(careAttentionText([_ev(3, 'auto_rule'), _ev(2, 'execution_failed'), _ev(1, 'routine_notice')]),
          '못 한 일 1번, 그 밖에 안 본 알림 2건');
      expect(careAttentionText([_ev(2, 'routine_stopped'), _ev(1, 'danger_sound')]), '위험 소리 1번, 그 밖에 안 본 알림 1건');
      expect(careAttentionText([_ev(1, 'emergency_stop')]), '멈춘 일 1번');
      expect(careAttentionText([_ev(1, 'routine_stopped')]), '멈춘 루틴 1번');
      expect(careNeedsLook([_ev(1, 'appliance_done_undelivered')]), isTrue);
    });

    testWidgets('홈: 자동·루틴 안내뿐이고 설정할 것도 없으면 주황이 아니다', (tester) async {
      _careJson = [_care(4, 'auto_rule'), _care(3, 'auto_rule'), _care(2, 'routine_notice'), _care(1, 'auto_rule')];
      // 위치까지 맞춘 가전만 — 설정이 남은 줄이 없다.
      _rawAppliances = [_air];
      await _pump(tester, const HomeScreen());
      final row = find.byKey(const Key('home-attention-care'));
      expect(row, findsOneWidget);
      expect(_in(row, findPlainText('안 본 알림 4건')), findsOneWidget);
      expect(findPlainText('아직 안 봤어요', contains: true), findsNothing);
      expect(findPlainText('자동으로 한 일', contains: true), findsNothing);
      final ctx = tester.element(row);
      expect(_careRowColor(tester), isNot(ctx.appWarning));
      final header = tester.widget<Icon>(find.byKey(const Key('home-attention-icon')));
      expect(header.color, isNot(ctx.appWarning));
      // 한 줄에 다 들어간다(어절 중간에서 꺾이지 않게 짧게).
      final text = _in(row, findPlainText('안 본 알림 4건'));
      expect(tester.getSize(text).height, lessThan(AppFont.caption * 2));
    });

    testWidgets('홈: 실패가 섞이면 짧은 말과 경고색', (tester) async {
      _careJson = [_care(2, 'execution_failed'), _care(1, 'auto_rule')];
      await _pump(tester, const HomeScreen(), installed: [ApplianceMap.fromJson(_air)]);
      // 평가 15차(10/18): 못 한 일은 경고색 한 줄, 나머지 알림은 중립 한 줄.
      final look = find.byKey(const Key('home-attention-care-look'));
      expect(_in(look, findPlainText('못 한 일 1번')), findsOneWidget);
      expect(tester.widget<Text>(_in(look, findPlainText('못 한 일 1번'))).style?.color, tester.element(look).appWarning);
      final row = find.byKey(const Key('home-attention-care'));
      expect(_in(row, findPlainText('그 밖에 안 본 알림 1건')), findsOneWidget);
      expect(_careRowColor(tester), isNot(tester.element(row).appWarning));
    });

    // 평가 15차(10/18): 숫자 칩은 글자와 같은 말이라 없앴다 — 볼 것이 섞였을 때만 그 글자를 경고색(eval15_phone_test 3).
    testWidgets("설정 줄도 같은 말 '안 본 알림 N건', 볼 것이 없으면 경고색이 아니다", (tester) async {
      _careJson = [_care(2, 'auto_rule'), _care(1, 'routine_notice')];
      await _pump(tester, const SettingsScreen());
      final value = findPlainText('안 본 알림 2건');
      expect(value, findsOneWidget);
      expect(findPlainText('읽지 않은 알림', contains: true), findsNothing);
      expect(tester.widget<Text>(value).style?.color, isNot(tester.element(value).appWarning));
    });

    testWidgets('설정 줄: 실패가 섞이면 그 글자가 경고색', (tester) async {
      _careJson = [_care(2, 'execution_failed'), _care(1, 'routine_notice')];
      await _pump(tester, const SettingsScreen());
      final value = findPlainText('안 본 알림 2건');
      expect(tester.widget<Text>(value).style?.color, tester.element(value).appWarning);
    });
  });

  group('2·3. 기록 출처', () {
    test('출처 말', () {
      RpiHistoryEntry e(String id) => RpiHistoryEntry.fromJson(_history.firstWhere((h) => h['job_id'] == id));
      expect(historySourceLabel(e('j-auto-lg')), '자동 · LG 가전');
      expect(historySourceLabel(e('j-auto-arm')), '자동');
      expect(historySourceLabel(e('j-manual')), '화면에서 골라 누름');
      expect(historySourceLabel(e('j-voice')), '바로 실행');
    });

    testWidgets("LG 가전 자동 실행은 가전 아이콘과 '자동 · LG 가전', 누름 장치 자동은 그대로", (tester) async {
      await _pump(tester, const HistoryScreen());
      final row = find.byKey(const ValueKey('history-j-auto-lg'));
      expect(_in(row, findPlainText('오전 7:00 · 자동 · LG 가전')), findsOneWidget);
      expect(tester.widget<Icon>(find.byKey(const Key('history-icon-j-auto-lg'))).icon, ApplianceCategory.airPurifier.icon);
      expect(tester.widget<Icon>(find.byKey(const Key('history-icon-j-auto-arm'))).icon, AppIcons.auto);
      expect(findPlainText('사람이 직접', contains: true), findsNothing);
      expect(_in(find.byKey(const ValueKey('history-j-manual')), findPlainText('화면에서 골라 누름', contains: true)),
          findsOneWidget);
    });

    testWidgets('시각 줄의 가운뎃점은 앞 낱말에 붙는다 — 줄 머리에 오지 않는다', (tester) async {
      await _pump(tester, const HistoryScreen(), width: 300);
      final t = tester.widget<Text>(find.byKey(const Key('history-time-j-manual')));
      final data = t.data!;
      expect(data.replaceAll(kWordJoiner, ''), contains('$kNoBreakSpace· '));
      expect(data, isNot(contains(' ·')), reason: '보통 빈칸 뒤 가운뎃점은 줄 머리로 넘어갈 수 있다');
      expect(t.semanticsLabel, startsWith('오후 12:05 · 화면에서 골라 누름'));
    });
  });

  group('4. 시각 표기', () {
    test("본체 알림 문장의 '밤 10시'는 '오후 10:00'", () {
      expect(withAmPmInSentence('밤 10시가 되어 묻지 않고 가전에 전했어요.'), '오후 10:00에 묻지 않고 가전에 전했어요.');
      expect(withAmPmInSentence("아침 7시 30분이 되어 '아침' 루틴을 묻지 않고 시작했어요."),
          "오전 7:30에 '아침' 루틴을 묻지 않고 시작했어요.");
      expect(withAmPmInSentence('매일 밤 12시에 꺼요'), '매일 오전 12:00에 꺼요');
      expect(withAmPmInSentence('낮 1시에'), '오후 1:00에');
      // 본체 규칙과 맞지 않는 말은 그대로(뜻을 추측하지 않는다).
      expect(withAmPmInSentence('아침 9시간 동안'), '아침 9시간 동안');
      expect(withAmPmInSentence('밤 7시에'), '밤 7시에');
    });

    testWidgets("알림함 문장도 '오후 10:00' 꼴", (tester) async {
      _careJson = [_care(1, 'auto_rule', '밤 10시가 되어 묻지 않고 가전에 전했어요.')];
      await _pump(tester, const CareEventsScreen());
      expect(findPlainText('오후 10:00에 묻지 않고 가전에 전했어요.'), findsOneWidget);
      expect(findPlainText('밤 10시', contains: true), findsNothing);
    });
  });
}
