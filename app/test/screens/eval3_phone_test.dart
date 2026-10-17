// 평가 3차(2026-10-18, 종합 76) 지적 — 폰 홈·루틴·기록·설정.
//
// 1. '설정이 필요해요'는 홈에서 **확인 카드 한 곳**만. 가전 타일은 아이콘 점(+ 접근성 이름), 루틴 타일·루틴 탭 행의
//    경고 문장은 없다(행에는 '설정하기' 단추만). 다음 실행 큰 시각은 홈에만.
// 2. 문장: '본체와 다시 맞추기', 조용한 시간을 못 읽으면 '확인 못 했어요 · 새로 보기', 루틴 단위는 '버튼 N번'·'LG 가전 설정 N번'.
// 3. 루틴 아이콘은 대상 가전 아이콘(여러 가전이면 첫 가전 + 겹침 표시).
// 4. 기록 제목은 한 규칙 — '무엇을 하기'(행동 이름). 루틴·자동 규칙 이름은 부제.
// 5. 회색 배지 대비, 가전 타일 높이는 내용대로·상태 줄은 늘 한 줄.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/display_status.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simplelay/providers/clock_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_icons.dart';
import 'package:simplelay/theme/app_tokens.dart';

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

Map<String, dynamic> _thinq(String id, String name) => {
      'id': id,
      'name': name,
      'category': 'air_purifier',
      'rows': 1,
      'cols': 1,
      'buttons': const [],
      'control_path': 'thinq',
      'can_execute': true,
      'readiness': 'operable',
      'readiness_reasons': <String>[],
    };

Map<String, dynamic> _routine(String id, String name, {List<Map<String, dynamic>>? steps}) => {
      'id': id,
      'name': name,
      'steps': steps ??
          [
            {'kind': 'press_sequence', 'appliance_id': 'mw', 'buttons': ['시작']},
          ],
      'trigger': const {'kind': 'manual'},
      'when': '직접 실행할 때',
      'mode': 'approve',
      'enabled': true,
    };

const _next = {
  'routine_id': 'r-n',
  'name': '아침 공기청정기 끄기',
  'at': '2026-10-19T07:00:00+09:00',
  'when': '매일 07:00',
  'mode': 'approve',
  'mode_label': '자동 실행',
  'auto': true,
  'day_label': '내일',
};

class _Hub {
  _Hub({required this.appliances, required this.routines});
  List<Map<String, dynamic>> appliances;
  List<Map<String, dynamic>> routines;
  List<Map<String, dynamic>> next = const [];

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          if (path.startsWith('/execute') || path.endsWith('/approve')) {
            fail('실행 경로를 불렀어요: ${req.method} $path');
          }
          if (req.method == 'GET' && path == '/appliances') return _json(appliances);
          if (req.method == 'GET' && path == '/routines') return _json(routines);
          if (req.method == 'GET' && path == '/routines/next') return _json(next);
          if (req.method == 'GET' && path == '/thinq/power') {
            return _json({'execution_mode': 'real', 'appliances': const []});
          }
          if (req.method == 'GET' && path == '/thinq/air') {
            return _json({'execution_mode': 'real', 'appliances': const []});
          }
          if (path == '/suggestions') return _json(const []);
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _app(_Hub hub, Widget screen, {List<ApplianceMap> installed = const []}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, __) => screen),
      GoRoute(
        path: '/appliance/detail/:id',
        builder: (_, state) => Scaffold(body: Text('가전 상세 ${state.pathParameters['id']}')),
      ),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(hub.api()),
    ],
    child: MaterialApp.router(
        theme: ThemeData.light().copyWith(splashFactory: InkRipple.splashFactory),
        routerConfig: router),
  );
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final _mw = _appliance('mw', '전자레인지');
final _mw2 = _appliance('mw2', '오븐');
final _washer = _appliance('washer', '세탁기', mapped: false);
final _air = _thinq('air', '공기청정기');

List<ApplianceMap> get _installed =>
    [for (final j in [_mw, _mw2, _washer, _air]) ApplianceMap.fromJson(j)];

_Hub _hub() => _Hub(appliances: [_mw, _mw2, _washer, _air], routines: [
      _routine('r-b', '30초 데우기'),
      _routine('r-w', '빨래 시작', steps: [
        {'kind': 'press_sequence', 'appliance_id': 'washer', 'buttons': ['시작']},
      ]),
      _routine('r-m', '저녁 준비', steps: [
        {'kind': 'press_sequence', 'appliance_id': 'mw', 'buttons': ['시작', '시작']},
        {
          'kind': 'thinq_command',
          'appliance_id': 'air',
          'action': 'set_power',
          'args': {'power': 'on'},
        },
      ]),
    ])
      ..next = [_next];

Finder _iconIn(Finder parent, IconData icon) =>
    find.descendant(of: parent, matching: find.byWidgetPredicate((w) => w is Icon && w.icon == icon));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('홈 — 설정 안내는 확인 카드 한 곳', () {
    testWidgets('루틴 타일에는 "설정이 필요해요" 글자가 없고, 가전 타일은 아이콘 점 + 띠 문장 + 접근성 이름', (tester) async {
      final handle = tester.ensureSemantics();
      _tall(tester);
      await tester.pumpWidget(_app(_hub(), const HomeScreen(), installed: _installed));
      await _settle(tester);

      expect(find.byKey(const Key('home-attention')), findsOneWidget);
      // 가전 타일 띠 한 곳에만(평가 7차 10/18: 띠는 문장 '설정이 필요해요') — 무엇이 남았는지는 확인 카드가 한 번 말한다.
      expect(findPlainText('설정이 필요해요', contains: true), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('appliance-band-washer')), matching: findPlainText('설정이 필요해요')),
          findsOneWidget);
      final dot = find.byKey(const Key('appliance-setup-dot-washer'));
      expect(dot, findsOneWidget);
      expect(find.descendant(of: dot, matching: find.byType(Icon), matchRoot: true), findsOneWidget,
          reason: '색만이 아니라 아이콘 점');
      expect(find.bySemanticsLabel(RegExp('^세탁기, .*설정이 필요해요')), findsOneWidget);
      // 루틴 타일은 경고 문장 대신 무엇을 하는지(평가 5차 10/18: '누를 버튼 N개').
      final tile = find.byKey(const Key('home-routine-tile-r-w'));
      expect(find.descendant(of: tile, matching: findPlainText('세탁기 · 누를 버튼 1개')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('가전 타일은 늘 상태 한 줄 — 모르면 할 일, 높이는 내용대로', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(_hub(), const HomeScreen(), installed: _installed));
      await _settle(tester);

      for (final (id, text) in [('mw', '준비됐어요'), ('mw2', '준비됐어요'), ('washer', '설정이 필요해요')]) {
        final line = find.byKey(Key('appliance-status-$id'));
        expect(line, findsOneWidget, reason: id);
        expect(find.descendant(of: line, matching: findPlainText(text)), findsOneWidget, reason: id);
      }
      // 같은 줄의 두 타일(전자레인지·오븐, 내용이 같다) — 마지막 글자 아래에는 안쪽 여백만 남는다.
      final card = find.byKey(const Key('appliance-card-mw'));
      final lastText = find
          .descendant(of: card, matching: find.byType(Text))
          .evaluate()
          .map((e) => tester.getBottomLeft(find.byWidget(e.widget)).dy)
          .reduce((a, b) => a > b ? a : b);
      expect(tester.getBottomLeft(card).dy - lastText, lessThanOrEqualTo(AppSpace.lg + 1));
    });

    testWidgets('루틴 타일 아이콘은 대상 가전 아이콘, 여러 가전이면 겹침 표시', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(_hub(), const HomeScreen(), installed: _installed));
      await _settle(tester);
      final mwIcon = ApplianceMap.fromJson(_mw).icon;
      final single = find.byKey(const Key('home-routine-tile-r-b'));
      expect(_iconIn(single, mwIcon), findsOneWidget);
      expect(_iconIn(single, AppIcons.routine), findsNothing);
      final multi = find.byKey(const Key('home-routine-tile-r-m'));
      expect(_iconIn(multi, mwIcon), findsOneWidget);
      expect(find.descendant(of: multi, matching: find.byKey(const Key('routine-icon-more'))), findsOneWidget);
      expect(find.descendant(of: multi, matching: findPlainText('전자레인지 · 누를 버튼 2개 · 공기청정기 켜기')),
          findsOneWidget);
    });
  });

  group('루틴 탭', () {
    testWidgets('설정이 필요한 루틴은 "설정 필요" 배지만 — 경고 두 줄 없음, 단위는 누를 버튼 N개', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(_hub(), const RoutinesScreen(), installed: _installed));
      await _settle(tester);
      expect(find.byKey(const Key('routine-setup-r-w')), findsOneWidget);
      expect(findPlainText('설정이 필요해요', contains: true), findsNothing);
      expect(findPlainText('할 일', contains: true), findsNothing);
      expect(findPlainText('전자레인지 · 누를 버튼 1개'), findsOneWidget);
    });

    testWidgets('다음 실행 큰 시각은 홈에만 — 루틴 탭에는 위 다음 줄도 큰 숫자도 없다(평가 6차 10/18)', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(_hub(), const RoutinesScreen(), installed: _installed));
      await _settle(tester);
      expect(find.byKey(const Key('routines-next')), findsNothing);
      final big = find.byWidgetPredicate((w) => w is Text && (w.style?.fontSize ?? 0) >= AppFont.number);
      expect(big, findsNothing);
    });

    testWidgets('루틴 줄 아이콘도 대상 가전 아이콘', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_app(_hub(), const RoutinesScreen(), installed: _installed));
      await _settle(tester);
      final row = find.byKey(const Key('routine-row-r-b'));
      expect(_iconIn(row, ApplianceMap.fromJson(_mw).icon), findsOneWidget);
      expect(_iconIn(row, AppIcons.routine), findsNothing);
    });
  });

  group('루틴 부제 단위', () {
    test('누를 버튼 N개 · LG 가전은 결과 말(평가 5차 10/18)', () {
      final r = Routine.fromJson(_routine('r', '저녁', steps: [
        {'kind': 'press_sequence', 'appliance_id': 'mw', 'buttons': ['a', 'b', 'c']},
        {'kind': 'thinq_command', 'appliance_id': 'air', 'action': 'set_power', 'args': {'power': 'on'}},
      ]));
      expect(routineSubtitle(r, const {'mw': '전자레인지', 'air': '공기청정기'}).replaceAll(kWordJoiner, ''),
          '전자레인지 · 누를 버튼 3개 · 공기청정기 켜기');
    });
  });

  group('기록 제목 — 한 규칙: 무엇을 하기', () {
    RpiHistoryEntry e(Map<String, dynamic> extra) => RpiHistoryEntry.fromJson({
          'job_id': 'j',
          'finished_at': '2026-10-18T10:00:00',
          'status': 'succeeded',
          'retry_count': 0,
          'buttons': const [],
          ...extra,
        });
    List<Map<String, dynamic>> buttons(List<String> labels) => [
          for (final l in labels) {'button': l, 'success': true, 'attempts': 1},
        ];

    test('말로 한 명령·질문·해요체·자동 동작문 모두 행동 이름으로', () {
      expect(historyTitle(e({'purpose': '공기청정기 켜줘'})), '공기청정기 켜기');
      expect(historyTitle(e({'purpose': '즉석밥 데워줘'})), '즉석밥 데우기');
      expect(historyTitle(e({'purpose': '공기청정기 꺼 줘'})), '공기청정기 끄기');
      expect(historyTitle(e({'purpose': '공기청정기 풍량을 강으로 바꿀까요?'})), '공기청정기 바람 세게 하기');
      expect(historyTitle(e({'purpose': '자동 실행 · 공기청정기를 켜요'})), '공기청정기 켜기');
      expect(historyTitle(e({'purpose': '자동 실행 · 공기청정기 전원 끄기'})), '공기청정기 끄기');
    });

    test('루틴은 한 일이 제목, 루틴 이름은 부제(historyOrigin)', () {
      final r = e({
        'purpose': "'아침 데우기' 루틴을 실행할까요?",
        'route': 'physical',
        'buttons': buttons(['즉석밥', '시작']),
      });
      expect(historyTitle(r, applianceName: '전자레인지'), '전자레인지 버튼 2번 누르기');
      expect(historySource(r), '루틴');
      expect(historyOrigin(r, applianceName: '전자레인지'), '아침 데우기');
      // 한 일을 기록이 말하지 않으면(LG 가전 루틴) 루틴 이름이 곧 한 일 — 부제에 되풀이하지 않는다.
      final t = e({'purpose': "자동 실행 · '아침 공기청정기 끄기' 루틴", 'route': 'thinq'});
      expect(historyTitle(t, applianceName: '공기청정기'), '아침 공기청정기 끄기');
      expect(historyOrigin(t, applianceName: '공기청정기'), isNull);
    });

    test('목적이 없으면 가전·버튼으로, 그것도 없으면 버튼 누르기 / 가전 설정 바꾸기', () {
      expect(historyTitle(e({'buttons': buttons(['즉석밥', '시작'])})), '버튼 2번 누르기');
      expect(historyTitle(e(const {'route': 'thinq'}), applianceName: '세탁기'), '세탁기 설정 바꾸기');
      expect(historyTitle(e(const {'route': 'physical'})), '버튼 누르기');
    });
  });

  group('설정 문장', () {
    test('가전 다시 불러오기(평가 4차·6차 10/18에 이름 바꿈)', () => expect(kResyncLabel, '가전 다시 불러오기'));
    test('조용한 시간을 못 읽으면 "확인 못 했어요 · 새로 보기"', () {
      expect(quietRowValue(null, hasApi: true), '확인 못 했어요 · 새로 보기');
      expect(quietRowValue(null, hasApi: false), '연결 전이에요');
    });
    testWidgets('안부 확인 쉬기·기본 가전 같은 말이 없다', (tester) async {
      tester.view.physicalSize = const Size(400, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(buildScreen(const SettingsScreen(),
          overrides: [...installedOverrides([kTestAppliance])]));
      await tester.pump();
      expect(findPlainText('안부 확인 쉬기'), findsNothing);
      expect(findPlainText('기본 가전'), findsNothing);
      expect(findPlainText('집 비우는 날'), findsOneWidget);
    });
  });

  // 코디네이터 10/18: 서버의 오프셋 붙은 시각(…T07:00:05+09:00)을 toLocal()로 바꿔, UTC 에뮬레이터에서 07:00 끄기가
  // 전날 22:00으로 보였다('22:00 켜기' 규칙과 반대로 읽혔다). 서버 시각은 본체 벽시계(오프셋 그대로)로 읽는다.
  // 이 기기 시간대와 다른 오프셋(-03:00)을 써서, 어느 시간대에서 돌려도 toLocal로 되돌리면 실패한다.
  group('서버 시각은 본체 벽시계 그대로', () {
    test('기록·보호자 알림 시각은 오프셋을 떼고 벽시계 그대로', () {
      final h = RpiHistoryEntry.fromJson({
        'job_id': 'j',
        'finished_at': '2026-10-18T07:00:05-03:00',
        'status': 'succeeded',
        'retry_count': 0,
        'buttons': const [],
      });
      expect([h.finishedAt.year, h.finishedAt.month, h.finishedAt.day, h.finishedAt.hour, h.finishedAt.minute],
          [2026, 10, 18, 7, 0]);
      final c = RpiCareEvent.fromJson({
        'id': 1,
        'kind': 'execution_failed',
        'message': 'x',
        'occurred_at': '2026-10-18T23:30:00-03:00',
      });
      expect([c.occurredAt.day, c.occurredAt.hour, c.occurredAt.minute], [18, 23, 30]);
    });

    testWidgets('기록 화면: 07:00 자동 끄기는 07:00, 날짜 구획도 본체 날짜', (tester) async {
      final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
        if (req.url.path == '/history') {
          return http.Response.bytes(
              utf8.encode(jsonEncode([
                {
                  'job_id': 'j',
                  'finished_at': '2026-10-18T07:00:05-03:00',
                  'purpose': '자동 실행 · 공기청정기를 꺼요',
                  'status': 'succeeded',
                  'retry_count': 0,
                  'buttons': const [],
                },
              ])),
              200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 404);
      }));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          rpiApiServiceProvider.overrideWithValue(api),
          nowProvider.overrideWithValue(() => DateTime(2026, 10, 18, 12)),
        ],
        child: const MaterialApp(home: HistoryScreen()),
      ));
      await _settle(tester);
      expect(find.text('공기청정기 끄기'), findsOneWidget);
      expect(findPlainText('07:00 · 자동'), findsOneWidget);
      expect(find.text('오늘'), findsOneWidget);
    });
  });
}
