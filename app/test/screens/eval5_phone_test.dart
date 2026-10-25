// 평가 5차(2026-10-18, 종합 81) — "말은 사람 말에 가까워졌지만 화면 문법이 '흰 카드 + 회색 설명 + 테두리 버튼' 하나다."
//
// A. 가전 타일: 상태 띠(아이콘 + 짧은 말 + 색). 초록은 본체가 **읽은** 켜짐일 때만, 설정 필요는 주황, 그 밖은 회색.
//    가전마다 제 아이콘(공기청정기는 바람, 세탁기는 세탁기). 본체 아이콘은 네트워크 허브 그림이 아니다.
// B. 루틴: 시간축 목록(정해진 시각 묶음 + 행 왼쪽 큰 시각, '필요할 때' 묶음). '버튼 N번' 대신 '누를 버튼 N개',
//    LG 가전 단계는 결과 말('공기청정기 켜기'). 행 버튼은 '지금 하기' 하나, 설정이 남았으면 회색 '설정 필요' 배지.
//    홈 '내 루틴'은 가전 타일(카드)과 다른 모양(줄 목록).
// C. 기록 배지는 넷만: 됐어요·봐 주세요·못 했어요·연습. '전기와 소리 기록'은 개발자 모드일 때만.
// D. 읽지 않은 보호자 알림은 홈 '확인이 필요해요'에도 한 줄.
// E. 줄바꿈: 수동 조작·실행 상태·할까요? 화면도 낱말 중간에서 꺾이지 않는다.
// F. 설정 가전 줄: ⋮와 > 를 함께 두지 않는다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:simplelay/widgets/appliance_artwork.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/care_events_provider.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_colors.dart';

import '../helpers/line_check.dart';
import '../helpers/test_helpers.dart';

Map<String, dynamic> _appliance(String id, String name, String category, {bool mapped = true}) => {
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
        {'id': '$id-2', 'label': '30초', 'x': 0, 'y': 0},
      ],
      if (mapped)
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
final _washer = _appliance('washer', '세탁기', 'washing_machine', mapped: false);

List<ApplianceMap> get _installed => [for (final j in [_mw, _washer, _air]) ApplianceMap.fromJson(j)];

Map<String, dynamic> _press(String id, String name, String appliance, int n,
        {Map<String, dynamic> trigger = const {'kind': 'manual'}, String when = '직접 실행할 때'}) =>
    {
      'id': id,
      'name': name,
      'steps': [
        {'kind': 'press_sequence', 'appliance_id': appliance, 'buttons': List.filled(n, '시작')},
      ],
      'trigger': trigger,
      'when': when,
      'mode': 'approve',
      'enabled': true,
    };

Map<String, dynamic> _thinq(String id, String name, String time, String action, Map<String, dynamic> args) => {
      'id': id,
      'name': name,
      'steps': [
        {'kind': 'thinq_command', 'appliance_id': 'air', 'action': action, 'args': args},
      ],
      'trigger': {'kind': 'time', 'days': [0, 1, 2, 3, 4, 5, 6], 'time': time},
      'when': '매일 $time',
      'mode': 'approve',
      'enabled': true,
    };

final _routines = [
  _thinq('r-eve', '저녁 공기청정기 켜기', '22:00', 'set_power', {'power': 'POWER_ON'}),
  _thinq('r-morn', '아침 공기청정기 끄기', '07:00', 'set_power', {'power': 'POWER_OFF'}),
  _press('r-heat', '30초 데우기', 'mw', 2),
  _press('r-wash', '빨래 시작', 'washer', 3),
  {
    'id': 'r-notify',
    'name': '세탁 끝 알림',
    'steps': <dynamic>[],
    'trigger': {'kind': 'event', 'event': 'wash_complete'},
    'when': '세탁이 끝나면',
    'mode': 'notify',
    'enabled': true,
  },
];

RpiApiService _api() => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        http.Response json(Object body, [int status = 200]) => http.Response.bytes(
            utf8.encode(jsonEncode(body)), status,
            headers: {'content-type': 'application/json'});
        final path = req.url.path;
        if (path.startsWith('/execute') || path.endsWith('/approve')) {
          fail('실행 경로를 불렀어요: ${req.method} $path');
        }
        if (path == '/appliances') return json([_mw, _washer, _air]);
        // 실제 자리 확인을 마친 가전(평가 10차 10/18부터 자리 확인을 모르면 띠가 그 말 한 문장이라 '준비됐어요' 시험은 근거를 준다).
        if (path.endsWith('/verify-pass')) return json({'state': 'done', 'execution_mode': 'real'});
        if (path == '/routines') return json(_routines);
        if (path == '/routines/next') return json(const []);
        if (path == '/thinq/power') {
          return json({
            'execution_mode': 'real',
            'appliances': [
              {'appliance_id': 'air', 'power': 'on', 'age_s': 3},
            ],
          });
        }
        if (path == '/thinq/air') return json({'execution_mode': 'real', 'appliances': const []});
        if (path == '/suggestions') return json(const []);
        return json({'detail': 'not found'}, 404);
      }),
    );

class _SeededCare extends CareEventsNotifier {
  _SeededCare(super.ref, CareEventsState seed) {
    state = seed;
  }

  @override
  Future<void> refresh() async {}
}

Override _care(int unread) => careEventsProvider.overrideWith((ref) => _SeededCare(
    ref,
    CareEventsState(status: CareInboxStatus.ready, events: [
      for (var i = unread; i >= 1; i--)
        RpiCareEvent(id: i, kind: 'execution_failed', message: '실패 $i', occurredAt: DateTime(2026, 10, 18, 8, i)),
    ])));

final _visited = <String>[];

Widget _app(Widget screen, {double scale = 1.0, int unread = 0, bool korean = false}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    GoRoute(path: '/appliance/detail/:id', builder: (_, s) {
      _visited.add('/appliance/detail/${s.pathParameters['id']}');
      return const Scaffold();
    }),
    GoRoute(path: '/care', builder: (_, __) {
      _visited.add('/care');
      return const Scaffold();
    }),
  ]);
  final base = ThemeData.light();
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(_installed),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(_api()),
      _care(unread),
    ],
    child: MaterialApp.router(
      theme: korean ? base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Malgun')) : base,
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget screen,
    {double width = 400, double scale = 1.0, int unread = 0, bool korean = false}) async {
  tester.view.physicalSize = Size(width, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, scale: scale, unread: unread, korean: korean));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 가전 그림 아이콘(사용자 결정 10/19 — 켜짐·꺼짐은 이 아이콘의 색).
ApplianceArtwork _tileIcon(WidgetTester tester, String id) => tester
    .widget<ApplianceArtwork>(find.descendant(of: find.byKey(Key('appliance-icon-$id')), matching: find.byType(ApplianceArtwork)));

final _koreanFont = File('C:/Windows/Fonts/malgun.ttf');
final _noKoreanFont = _koreanFont.existsSync() ? null : '맑은 고딕 글꼴이 없어 줄 검사를 건너뛰어요';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _visited.clear();
  });
  setUpAll(() async {
    if (_noKoreanFont != null) return;
    final bytes = _koreanFont.readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('A. 가전 타일 — 상태 띠', () {
    test('공기청정기는 바람 아이콘(기호 그림이 아니다), 세탁기는 세탁기 아이콘', () {
      expect(ApplianceCategory.parse('air_purifier').icon, Icons.air);
      expect(ApplianceCategory.parse('air_purifier').label, '공기청정기');
      expect(ApplianceCategory.parse('washing_machine').icon, isNot(ApplianceCategory.other.icon));
    });

    // 사용자 결정(10/19): 상태 띠 대신 — 켜짐(읽은 값)만 아이콘 강조색, 설정 남음은 톱니 표시, 준비는 표시 없음.
    // 사용자 결정(10/19, 두 번째): 밝기 = 켜짐·작동 중 — 켜짐·실행 중은 본문 글자색(appInk), 꺼짐·모름·쉬는 중은 appTileDim. 강조색은 쓰지 않는다.
    testWidgets('켜짐(읽은 값)만 아이콘 밝게, 설정 남음은 톱니 표시, 준비는 표시 없음', (tester) async {
      await _pump(tester, const HomeScreen());
      expect(_tileIcon(tester, 'air').color, AppColors.successLight);
      expect(tileMarkText(tester, 'air'), isNull);
      expect(tileMarkIcon(tester, 'washer'), Icons.settings_rounded);
      // 준비 — 표시 없음. 켜짐을 읽을 수 없는 누름 장치 가전이고 실행 중도 아니니 흐리다.
      expect(tileMarkText(tester, 'mw'), isNull);
      expect(_tileIcon(tester, 'mw').color, AppColors.tileDimLight);
      // 타일 아이콘은 가전마다 — 공기청정기는 바람.
      expect(find.descendant(of: find.byKey(const Key('appliance-card-air')), matching: find.byKey(const Key('appliance-artwork-air_purifier'))),
          findsOneWidget);
    });

    testWidgets('설정의 본체 줄은 네트워크 허브 그림이 아니다', (tester) async {
      await _pump(tester, const SettingsScreen());
      expect(find.byIcon(Icons.hub_outlined), findsNothing);
    });
  });

  group('B. 루틴 — 시간축', () {
    testWidgets('정해진 시각 묶음(이른 순) · 필요할 때 묶음', (tester) async {
      await _pump(tester, const RoutinesScreen());
      expect(find.byKey(const Key('routines-group-time')), findsOneWidget);
      expect(find.byKey(const Key('routines-group-manual')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('routines-group-manual')), matching: findPlainText('필요할 때')),
          findsOneWidget);
      final morn = find.byKey(const Key('routine-line-r-morn'));
      final eve = find.byKey(const Key('routine-line-r-eve'));
      // 평가 10차(10/18): 시각은 이름 아래 한 줄 '매일 오전 7:00 · 공기청정기'(구성은 eval10_phone_test가 본다).
      expect(find.descendant(of: morn, matching: findPlainText('매일 오전 7:00', contains: true), matchRoot: true),
          findsOneWidget);
      expect(find.descendant(of: eve, matching: findPlainText('매일 오후 10:00', contains: true), matchRoot: true),
          findsOneWidget);
      expect(tester.getTopLeft(morn).dy, lessThan(tester.getTopLeft(eve).dy), reason: '07:00이 22:00보다 위');
    });

    testWidgets("'누를 버튼 N개'와 결과 말 — '버튼 N번'·'LG 가전 설정'이 없다", (tester) async {
      await _pump(tester, const RoutinesScreen());
      expect(findPlainText('버튼 2번', contains: true), findsNothing);
      expect(findPlainText('LG 가전 설정', contains: true), findsNothing);
      expect(findPlainText('누를 버튼 2개', contains: true), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('routine-row-r-eve')), matching: findPlainText('공기청정기 켜기', contains: true)),
          findsWidgets);
      expect(find.descendant(of: find.byKey(const Key('routine-row-r-morn')), matching: findPlainText('공기청정기 끄기', contains: true)),
          findsWidgets);
    });

    // 평가 11차(10/18): 회색 '설정 필요' 칩 → 같은 꼴의 글자 단추 '설정하기 >'(eval11_phone_test 1).
    testWidgets("행 버튼은 '지금 하기' 하나, 설정이 남았으면 '설정하기'(테두리 버튼 아님)", (tester) async {
      await _pump(tester, const RoutinesScreen());
      expect(find.text('실행'), findsNothing);
      expect(find.descendant(of: find.byKey(const Key('routine-run-r-heat')), matching: findPlainText('지금 하기')),
          findsOneWidget);
      final setup = find.byKey(const Key('routine-setup-r-wash'));
      expect(find.descendant(of: setup, matching: findPlainText('설정 열기')), findsOneWidget);
      expect(find.descendant(of: setup, matching: find.byType(OutlinedButton)), findsNothing);
      await tester.tap(setup);
      await tester.pumpAndSettle();
      expect(_visited, ['/appliance/detail/washer']);
    });

    testWidgets('홈 저장 동작: 첫 동작 카드와 나머지 줄 목록', (tester) async {
      await _pump(tester, const HomeScreen());
      final list = find.byKey(const Key('home-routines'));
      expect(list, findsOneWidget);
      expect(find.descendant(of: list, matching: find.byType(Card)), findsOneWidget);
      expect(find.descendant(of: list, matching: findPlainText('누를 버튼 2개', contains: true)), findsOneWidget);
    });
  });

  group('C. 기록 배지 넷 · 개발자 기록', () {
    RpiHistoryEntry e(Map<String, dynamic> extra) => RpiHistoryEntry.fromJson({
          'job_id': 'j',
          'finished_at': '2026-10-18T10:00:00',
          'status': 'succeeded',
          'retry_count': 0,
          'buttons': const [],
          ...extra,
        });

    test("보고만 받은 것은 '봐 주세요' — '받았어요' 없음", () {
      expect(historyBadgeOf(e({'execution_mode': 'real', 'route': 'physical', 'confirmation': 'mcu_ack'})).label,
          '봐 주세요');
      expect(historyBadgeOf(e({'execution_mode': 'real', 'route': 'thinq', 'confirmation': 'sent'})).label, '봐 주세요');
    });

    test('배지는 됐어요·봐 주세요·못 했어요·연습 넷만', () {
      final labels = <String>{};
      for (final mode in ['real', 'mock', 'unknown']) {
        for (final route in ['thinq', 'physical']) {
          for (final outcome in ['success', 'failed', 'stopped', 'safety_stop', 'unconfirmed', null]) {
            for (final confirmation in ['state_confirmed', 'press_confirmed', 'already_at_target', 'sent', 'unknown']) {
              labels.add(historyBadgeOf(e({
                'execution_mode': mode,
                'route': route,
                if (outcome != null) 'outcome': outcome,
                'confirmation': confirmation,
              })).label);
            }
          }
        }
      }
      // 평가 7차(10/18): 멈춘 기록은 '봐 주세요'와 글자를 가른다 — 멈췄어요·스스로 멈췄어요.
      expect(labels, {'완료', '봐 주세요', '멈춤', '스스로 멈춤', '실패', '연습'});
    });

    for (final dev in [false, true]) {
      testWidgets("'전기와 소리 기록'은 개발자 모드일 때만 (개발자 모드 $dev)", (tester) async {
        tester.view.physicalSize = const Size(400, 3000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(buildScreen(
          const StatusScreen(),
          overrides: [developerModeProvider.overrideWithValue(dev)],
          executionStatus: const ExecutionStatus(
            phase: ExecutionPhase.running,
            label: '즉석밥 데우기',
            steps: ['BT-08', 'BT-03'],
            completedSteps: 1,
            currentMa: 320,
            soundDb: 42,
          ),
        ));
        await tester.pump();
        expect(findPlainText('전기와 소리 기록'), dev ? findsOneWidget : findsNothing);
      });
    }
  });

  group('D. 보호자 알림을 홈에도', () {
    testWidgets('읽지 않은 알림이 있으면 홈에 한 줄(설정과 같은 수), 누르면 알림함', (tester) async {
      await _pump(tester, const HomeScreen(), unread: 4);
      // 휴리스틱 평가(10/18): 실행 실패는 맨 위 실패 경고, 알림 수는 설정과 같은 전체 수 한 줄.
      final row = find.byKey(const Key('home-unread'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: findPlainText('안 본 알림 4건')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('home-failure')), matching: findPlainText('못 한 일', contains: true)),
          findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(_visited, ['/care']);
    });

    testWidgets('읽지 않은 알림이 없으면 그 줄도 없다', (tester) async {
      await _pump(tester, const HomeScreen());
      expect(find.byKey(const Key('home-unread')), findsNothing);
    });
  });

  group('E. 줄바꿈 — 수동 조작·실행 상태·할까요?', () {
    for (final (width, scale) in [(360.0, 1.0), (390.0, 1.3), (390.0, 2.0)]) {
      testWidgets('수동 조작 ($width, $scale)', (tester) async {
        await _pump(tester, const ManualControlScreen(),
            width: width, scale: scale, korean: true);
        expect(findPlainText(kManualHint), findsOneWidget);
        expect(brokenLines(tester), isEmpty);
      }, skip: _noKoreanFont != null);

      testWidgets('실행 상태 ($width, $scale)', (tester) async {
        tester.view.physicalSize = Size(width, 6000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final base = ThemeData.light();
        await tester.pumpWidget(buildWithProviderState(
          executionStatus: const ExecutionStatus(
            phase: ExecutionPhase.unconfirmed,
            label: '즉석밥 데우기',
            steps: ['BT-08', 'BT-03'],
            completedSteps: 1,
          ),
          child: MaterialApp(
            theme: base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Malgun')),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const StatusScreen(),
          ),
        ));
        await tester.pump();
        expect(brokenLines(tester), isEmpty);
      }, skip: _noKoreanFont != null);

      testWidgets('할까요? ($width, $scale)', (tester) async {
        tester.view.physicalSize = Size(width, 6000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        const s = Suggestion(
          sequenceId: 'eval5-1',
          label: '즉석밥 데우기',
          steps: ['BT-08', 'BT-03', 'BT-05'],
          applianceId: 'microwave',
          source: SuggestionSource.http,
          timeBand: '저녁',
          occurrences: 4,
        );
        final base = ThemeData.light();
        await tester.pumpWidget(buildWithProviderState(
          suggestions: const [s],
          overrides: [...connectedOverrides(), ...installedOverrides([kTestAppliance])],
          child: MaterialApp(
            theme: base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Malgun')),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const SuggestionScreen(sequenceId: 'eval5-1'),
          ),
        ));
        await tester.pump();
        expect(brokenLines(tester), isEmpty);
      }, skip: _noKoreanFont != null);
    }
  });

  group('F. 설정 가전 줄', () {
    // 평가 7차(10/18): 모든 줄이 > 하나, ⋮ 는 가전 상세 화면으로 옮겼다 — 줄 끝 표시가 하나라는 규칙은 그대로.
    // 10/25 사용자: 설정의 가전 목록을 뺐다(홈·가전 탭과 같다) — 설정 가전 줄 시험은 settings_screen_test '설정에는 가전 목록이 없다'로 대신한다.
  });
}
