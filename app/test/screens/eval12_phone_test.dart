// 평가 12차(2026-10-18, 폰 91).
//
// 1. 기록: 누름 장치가 다 눌렀지만 가전 동작을 확인 못 한 기록 — '다 눌렀다고 알려 왔어요'(기계 보고 말투) 대신
//    '버튼은 다 눌렀어요. 움직였는지는 집에서 확인이 필요해요'. 배지는 그대로 '확인 필요'(초록 아님).
// 2. 기록: 사람이 시작한 LG 가전(클라우드) 기록은 손 아이콘·'사람이 직접' 대신 가전 아이콘과 'LG 가전'.
//    (폰·본체 화면 어디서 보냈는지는 /history에 가를 필드가 없어 'LG 가전'까지만.) 누름 장치 기록은 그대로.
// 3. 홈 가전 칸: 자리 확인을 모르면 '버튼 자리를 다시 맞춰 주세요'(설정 '버튼 자리를 맞춰 주세요'와 같은 말 계열).
// 4. 설정: LG 가전 부제는 두 줄 — '켜기·끄기는 여기서 해요' / '등록은 LG 앱에서 해요'('LG / 앱에서' 끊김 없음).
//    본체 반영 단추는 이름이 '본체 화면에 반영하기', 보낼 것이 있을 때만 보인다.
// 5. 홈 안 본 알림 줄: 본체가 실제로 보내는 종류(auto_rule·routine_notice 등)도 무슨 알림인지 말한다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/line_break.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_icons.dart';
import 'package:simplelay/widgets/status_badge.dart';

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

List<Map<String, dynamic>> get _rawAppliances => [_mw, _air];
List<ApplianceMap> get _installed => [for (final j in _rawAppliances) ApplianceMap.fromJson(j)];

Map<String, dynamic> _hist(String id, String purpose,
        {String outcome = 'success',
        String route = 'thinq',
        String confirmation = 'state_confirmed',
        String? appliance}) =>
    {
      'job_id': id,
      'finished_at': '2026-10-18T10:51:00',
      'status': 'succeeded',
      'outcome': outcome,
      'retry_count': 0,
      'buttons': const [],
      'execution_mode': 'real',
      'route': route,
      'confirmation': confirmation,
      'purpose': purpose,
      if (appliance != null) 'appliance_id': appliance,
    };

final _history = [
  // 사람이 폰·본체 화면에서 켠 LG 공기청정기(클라우드).
  _hist('j-lg', '공기청정기를 켜요', appliance: 'air'),
  // 자동 실행으로 끈 LG 공기청정기 — 출처는 그대로 '자동'.
  _hist('j-auto', "자동 실행 · '아침 공기청정기 끄기' 루틴", appliance: 'air'),
  // 누름 장치가 다 눌렀다고 보고했지만 가전 동작은 확인하지 못함.
  {
    ..._hist('j-rep', '즉석밥 데워줘', route: 'physical', confirmation: 'unknown', appliance: 'mw'),
    'buttons': [
      {'button': '시작', 'success': true, 'attempts': 1},
    ],
  },
];

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
    child: MaterialApp.router(
      theme: _noKoreanFont == null
          ? ThemeData.light().copyWith(textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Malgun'))
          : ThemeData.light(),
      routerConfig: router,
    ),
  );
}

// 폭 411은 평가 실기기(1080 px, 밀도 2.625)의 논리 폭.
Future<void> _pump(WidgetTester tester, Widget screen, {List<ApplianceMap>? installed}) async {
  tester.view.physicalSize = const Size(411, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, installed: installed));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _in(Finder parent, Finder child) => find.descendant(of: parent, matching: child);

final _koreanFont = File('C:/Windows/Fonts/malgun.ttf');
final _noKoreanFont = _koreanFont.existsSync() ? null : '맑은 고딕 글꼴이 없어 줄 수 검사를 건너뛰어요';

RpiCareEvent _ev(int id, String kind) =>
    RpiCareEvent(id: id, kind: kind, message: '알림 $id', occurredAt: DateTime(2026, 10, 18, 8, id));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (_noKoreanFont != null) return;
    final bytes = _koreanFont.readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('1·2. 기록', () {
    testWidgets("다 눌렀지만 확인 못 한 기록은 사람 말 — '버튼은 다 눌렀어요. 움직였는지는 집에서 확인이 필요해요'", (tester) async {
      await _pump(tester, const HistoryScreen());
      expect(findPlainText('알려 왔어요', contains: true), findsNothing);
      final row = find.byKey(const ValueKey('history-j-rep'));
      final reason = find.byKey(const Key('history-reason-j-rep'));
      expect(_in(row, reason), findsOneWidget);
      expect(find.descendant(of: reason, matching: findPlainText('버튼은 다 눌렀어요. 가전이 움직였는지는 몰라요'), matchRoot: true),
          findsOneWidget);
      // 확인 수준은 그대로 — 초록 '됐어요'가 아니라 '확인 필요'.
      final badge = tester.widget<StatusBadge>(_in(row, find.byType(StatusBadge)));
      expect(badge.label, '확인 필요');
      // 누름 장치 기록은 손 아이콘 그대로(출처 말은 평가 13차에 '바로 실행' — eval13_phone_test 3).
      expect(_in(row, findPlainText('바로 실행', contains: true)), findsOneWidget);
      expect(tester.widget<Icon>(find.byKey(const Key('history-icon-j-rep'))).icon, AppIcons.manual);
    });

    testWidgets("사람이 시작한 LG 가전 기록은 가전 아이콘과 'LG 가전' — 손·'사람이 직접'이 아니다", (tester) async {
      await _pump(tester, const HistoryScreen());
      final row = find.byKey(const ValueKey('history-j-lg'));
      expect(row, findsOneWidget);
      expect(_in(row, findPlainText('사람이 직접', contains: true)), findsNothing);
      expect(_in(row, findPlainText('오전 10:51 · LG 가전')), findsOneWidget);
      final icon = tester.widget<Icon>(find.byKey(const Key('history-icon-j-lg')));
      expect(icon.icon, ApplianceCategory.airPurifier.icon);
      expect(_in(row, find.byIcon(AppIcons.manual)), findsNothing);
      // 자동 실행 기록은 출처 그대로.
      expect(tester.widget<Icon>(find.byKey(const Key('history-icon-j-auto'))).icon, AppIcons.auto);
    });

    test('출처 말 — LG 가전 직접만 바뀐다', () {
      RpiHistoryEntry e(Map<String, dynamic> j) => RpiHistoryEntry.fromJson(_hist('x', '', appliance: 'air')..addAll(j));
      expect(historySourceLabel(e({'purpose': '공기청정기를 켜요'})), 'LG 가전');
      expect(historySourceLabel(e({'purpose': '즉석밥 데워줘', 'route': 'physical'})), '바로 실행');
      expect(historySourceLabel(e({'purpose': "자동 실행 · '저녁 공기청정기 켜기' 루틴"})), '루틴 · 자동으로');
      expect(historySourceLabel(e({'purpose': "'아침 공기청정기 끄기' 루틴"})), '루틴 · 물어보고');
    });
  });

  group('3. 홈 가전 칸', () {
    testWidgets("자리 확인을 모르면 '버튼 자리를 다시 맞춰 주세요'", (tester) async {
      await _pump(tester, const HomeScreen(), installed: const []);
      final band = find.byKey(const Key('appliance-band-mw'));
      expect(_in(band, findPlainText('버튼 자리를 다시 맞춰 주세요')), findsOneWidget);
      expect(findPlainText('자리 확인을 했는지 몰라요'), findsNothing);
      expect(_in(find.byKey(const Key('appliance-card-mw')), findPlainText('준비됐어요')), findsNothing);
    });
  });

  group('4. 설정', () {
    testWidgets("LG 가전 부제는 두 줄 — '등록은 LG 앱에서 해요'가 한 줄", (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(findPlainText('켜기·끄기는 여기서, 등록은 LG 앱에서'), findsNothing);
      final sub = find.byKey(const Key('settings-thinq-subtitle'));
      expect(sub, findsOneWidget);
      final data = tester.widget<Text>(sub).data!;
      final lines = data.replaceAll(kWordJoiner, '').split('\n');
      // 평가 17차(10/18): 한 문장 '등록은 LG 앱에서 해요'(eval17_phone_test 5).
      expect(lines.map((l) => l.replaceAll(kNoBreakSpace, ' ')).toList(), ['등록은 LG 앱에서 해요']);
      // 'LG'와 '앱에서'는 떨어지지 않는다.
      expect(lines[0], contains('LG$kNoBreakSpace앱에서'));
      if (_noKoreanFont == null) {
        final t = tester.widget<Text>(sub);
        final lineH = (t.style?.fontSize ?? 14) * 1.6;
        expect(tester.getSize(sub).height, lessThan(lineH * 2), reason: '${tester.getSize(sub)}');
      }
    });

    testWidgets('바꾼 것이 없으면 본체 반영 단추가 없다', (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(findPlainText(kResyncLabel), findsNothing);
      expect(findPlainText('다시 보내기', contains: true), findsNothing);
    });

    testWidgets("이 폰의 가전이 본체에 없으면 '본체 화면에 반영하기'", (tester) async {
      final local = ApplianceMap.fromJson(_appliance('fan', '선풍기', 'other'));
      await _pump(tester, const SettingsScreen(), installed: [..._installed, local]);
      await tester.scrollUntilVisible(findPlainText('본체 화면에 반영하기'), 200);
      expect(findPlainText('본체 화면에 반영하기'), findsOneWidget);
    });

    test('단추 이름은 얻는 결과', () {
      expect(kResyncLabel, '본체 화면에 반영하기');
      expect(kResyncLabel, isNot(contains('보내기')));
    });
  });

  group('5. 홈 안 본 알림 줄', () {
    test('본체가 실제로 보내는 종류도 말한다', () {
      // 평가 13차(10/18): 자동으로 한 일·루틴 안내뿐이면 건수만, 볼 것이 섞이면 가장 무거운 것 한 마디.
      expect(careAttentionText([_ev(4, 'auto_rule'), _ev(3, 'auto_rule'), _ev(2, 'routine_notice'), _ev(1, 'auto_rule')]),
          '안 본 알림 4건');
      // 평가 15차(10/18): 볼 것은 그 갈래·건수, 나머지는 따로(eval15_phone_test 5).
      expect(careAttentionText([_ev(2, 'routine_stopped'), _ev(1, 'appliance_done_undelivered')]),
          '못 한 일 1번, 안 본 알림 2건');
      expect(careAttentionText([_ev(2, 'routine_announce'), _ev(1, 'routine_notice')]), '안 본 알림 2건');
      expect(careAttentionText([_ev(2, 'execution_failed'), _ev(1, 'appliance_done_undelivered')]),
          '못 한 일 2번, 안 본 알림 2건');
      expect(careAttentionText([_ev(1, 'something_new')]), '안 본 알림 1건');
    });
  });
}
