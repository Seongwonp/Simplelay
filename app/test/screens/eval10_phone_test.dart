// 평가 10차(2026-10-18, 폰 89) + 9차에 남은 폰 감점.
//
// 1. 루틴 목록: 모든 줄이 같은 꼴 — 이름 → 그 아래 한 줄 '언제 · 무슨 가전'('매일 오전 7:00 · 공기청정기',
//    '전자레인지 · 누를 버튼 2개'). 오른쪽 '지금 하기 >'는 모든 줄에서 이름 줄 같은 높이. '다음' 배지는 그 한 줄 끝.
//    홈에서 '자동으로 해요'인 루틴은 목록에도 같은 표시(근거: 본체 /routines/next의 auto).
// 2. 자동으로 하기 탭: 머리 안내는 낱말 단위 줄바꿈('자 / 동' 방지). 사용자가 끈 규칙은 짧은 '꺼 둠' 표시
//    (예전 긴 '자동으로 하기를 꺼 두셨어요' 배지는 두지 않는다).
// 3. 기록: '루틴 · 허락하고 실행' → '루틴 · 물어보고'. '직접' → '사람이 직접'(폰·본체 화면·말을 가를 자료가
//    기록에 없다 — 사람이 시작했다는 것까지만). '봐 주세요' 배지 줄에는 까닭 한 줄(결과 문장 그대로).
// 4. 홈 가전 칸: 자리 확인 보조 줄과 '준비됐어요'가 엇갈리지 않게 — 보조 줄이 있으면 띠가 그 한 문장.
// 5. 설정: 못 읽은 값은 까닭(본체 연결이 끊김처럼 근거가 있을 때만), '새로 보기'는 따로 단추.
// 6. 루틴 편집: 기다리기 단계 '동작이 끝날 때까지 기다리기' → '[전자레인지] 끝나면' 한 줄.
// 7. 큰 글씨 루틴: '다음' 배지가 시각과 이름 사이에 혼자 서지 않는다(이름 아래 한 줄 끝).
// 8. 직접 누르기: 버튼 없는 칸은 옅은 점선 칸(깨진 화면처럼 비어 있지 않게).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/manual_control_screen.dart';
import 'package:simplelay/screens/routine_editor_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

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

Map<String, dynamic> _thinq(String id, String name, String time, String power) => {
      'id': id,
      'name': name,
      'steps': [
        {'kind': 'thinq_command', 'appliance_id': 'air', 'action': 'set_power', 'args': {'power': power}},
      ],
      'trigger': {'kind': 'time', 'days': [0, 1, 2, 3, 4, 5, 6], 'time': time},
      'when': '매일 $time',
      'mode': 'approve',
      'enabled': true,
    };

final _routines = [
  _thinq('r-eve', '저녁 공기청정기 켜기', '22:00', 'POWER_ON'),
  _thinq('r-morn', '아침 공기청정기 끄기', '07:00', 'POWER_OFF'),
  _thinq('r-noon', '점심 공기청정기 켜기', '12:00', 'POWER_ON'),
  {
    'id': 'r-heat',
    'name': '30초 데우기',
    'steps': [
      {'kind': 'press_sequence', 'appliance_id': 'mw', 'buttons': ['시작', '시작']},
    ],
    'trigger': {'kind': 'manual'},
    'when': '직접 실행할 때',
    'mode': 'approve',
    'enabled': true,
  },
];

Map<String, dynamic> _next(String id, String name, String at, {required bool auto}) => {
      'routine_id': id,
      'name': name,
      'at': at,
      'when': '매일',
      'day_label': '오늘',
      'mode': 'approve',
      'mode_label': auto ? '자동 실행' : '승인 후 실행',
      'auto': auto,
    };

final _rules = [
  {
    'id': 'ar-eve',
    'name': '저녁 공기청정기 켜기',
    'condition_text': '매일 밤 10시에',
    'action_text': '공기청정기를 켜요',
    'condition_time': '22:00',
    'enabled': true,
    'fingerprint': 'fp',
  },
  {
    'id': 'ar-heat',
    'name': '데우기가 끝나면 공기청정기 세게',
    'condition_text': '전자레인지가 데우기를 멈추면',
    'action_text': '공기청정기 바람을 세게 해요',
    'enabled': false,
    'disabled_reason': '자동으로 하기를 꺼 두셨어요.',
    'fingerprint': 'fp',
  },
  {
    'id': 'ar-estop',
    'name': '아침 공기청정기 끄기',
    'condition_text': '매일 아침 7시에',
    'action_text': '공기청정기를 꺼요',
    'condition_time': '07:00',
    'enabled': false,
    'disabled_reason': '비상 정지로 꺼졌어요. 다시 허락해 주세요.',
    'fingerprint': 'fp',
  },
];

Map<String, dynamic> _hist(String id, String purpose,
        {String outcome = 'success', String route = 'thinq', String confirmation = 'state_confirmed'}) =>
    {
      'job_id': id,
      'finished_at': '2026-10-18T22:04:00',
      'status': 'succeeded',
      'outcome': outcome,
      'retry_count': 0,
      'buttons': const [],
      'execution_mode': 'real',
      'route': route,
      'confirmation': confirmation,
      'purpose': purpose,
    };

final _history = [
  _hist('j-ask', "'아침 공기청정기 끄기' 루틴"),
  _hist('j-auto', "자동 실행 · '저녁 공기청정기 켜기' 루틴"),
  _hist('j-me', '공기청정기를 꺼요'),
  {
    ..._hist('j-unk', '전자레인지 시작', outcome: 'unconfirmed', route: 'physical', confirmation: 'unknown'),
    'appliance_id': 'mw',
    'buttons': [
      {'button': '시작', 'success': false, 'attempts': 1},
    ],
  },
];

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

RpiApiService _api({bool down = false}) => RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        final path = req.url.path;
        if (path.startsWith('/execute') || path.endsWith('/approve')) {
          fail('실행 경로를 불렀어요: ${req.method} $path');
        }
        if (down) throw http.ClientException('연결 끊김');
        if (path == '/appliances') return _json(_rawAppliances);
        if (path == '/routines') return _json(_routines);
        if (path == '/routines/next') {
          final all = [
            _next('r-noon', '점심 공기청정기 켜기', '2026-10-18T12:00:00+09:00', auto: false),
            _next('r-eve', '저녁 공기청정기 켜기', '2026-10-18T22:00:00+09:00', auto: true),
            _next('r-morn', '아침 공기청정기 끄기', '2026-10-19T07:00:00+09:00', auto: true),
          ];
          final limit = int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 3;
          return _json(all.take(limit).toList());
        }
        if (path == '/routines/auto-rules') return _json(_rules);
        if (path == '/quiet-hours') {
          return _json({'enabled': true, 'start': '22:00', 'end': '07:00', 'active': false});
        }
        if (path == '/history') return _json(_history);
        if (path == '/suggestions') return _json(const []);
        return _json({'detail': 'not found'}, 404);
      }),
    );

Widget _app(Widget screen,
    {double scale = 1.0,
    RpiConnectionState hub = RpiConnectionState.connected,
    bool down = false,
    List<ApplianceMap>? installed}) {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    GoRoute(path: '/routine/edit', builder: (_, __) => const Scaffold(body: Text('편집 화면'))),
  ]);
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides(installed ?? _installed),
      rpiServerOverride(hub),
      rpiApiServiceProvider.overrideWithValue(_api(down: down)),
    ],
    child: MaterialApp.router(
      theme: _noKoreanFont == null
          ? ThemeData.light().copyWith(textTheme: ThemeData.light().textTheme.apply(fontFamily: 'Malgun'))
          : ThemeData.light(),
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget screen,
    {Size size = const Size(390, 3000),
    double scale = 1.0,
    RpiConnectionState hub = RpiConnectionState.connected,
    bool down = false,
    List<ApplianceMap>? installed}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(screen, scale: scale, hub: hub, down: down, installed: installed));
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

int _lines(WidgetTester tester, Finder text) {
  final t = tester.widget<Text>(text);
  final size = (t.style?.fontSize ?? 14) * MediaQuery.textScalerOf(tester.element(text)).scale(1);
  return (tester.getSize(text).height / (size * 1.45)).round();
}

Finder _in(Finder parent, Finder child) => find.descendant(of: parent, matching: child);

final _koreanFont = File('C:/Windows/Fonts/malgun.ttf');
final _noKoreanFont = _koreanFont.existsSync() ? null : '맑은 고딕 글꼴이 없어 줄 수 검사를 건너뛰어요';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    if (_noKoreanFont != null) return;
    final bytes = _koreanFont.readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  group('1. 루틴 목록 한 줄 구성', () {
    testWidgets("이름 아래 한 줄 '언제 · 무슨 가전'", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final cases = {
        'r-morn': ('아침 공기청정기 끄기', '매일 오전 7:00 · 공기청정기'),
        'r-eve': ('저녁 공기청정기 켜기', '매일 오후 10:00 · 공기청정기'),
        'r-heat': ('30초 데우기', '전자레인지 · 누를 버튼 2개'),
      };
      for (final MapEntry(key: id, value: (name, line)) in cases.entries) {
        final row = find.byKey(Key('routine-row-$id'));
        final lineText = find.byKey(Key('routine-line-$id'));
        expect(_in(row, lineText), findsOneWidget, reason: id);
        expect(_in(row, findPlainText(line, contains: true)), findsOneWidget, reason: id);
        final nameText = _in(row, findPlainText(name));
        expect(nameText, findsOneWidget, reason: id);
        // 이름이 먼저, 그 아래 한 줄.
        expect(tester.getTopLeft(lineText).dy, greaterThanOrEqualTo(tester.getBottomLeft(nameText).dy - 0.5),
            reason: id);
      }
    });

    testWidgets("'지금 하기'는 모든 줄에서 이름 줄 같은 높이", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final offsets = <double>[];
      for (final (id, name) in [
        ('r-morn', '아침 공기청정기 끄기'),
        ('r-eve', '저녁 공기청정기 켜기'),
        ('r-heat', '30초 데우기'),
      ]) {
        final row = find.byKey(Key('routine-row-$id'));
        final run = find.byKey(Key('routine-run-$id'));
        final nameText = _in(row, findPlainText(name));
        expect((tester.getCenter(run).dy - tester.getCenter(nameText).dy).abs(), lessThan(2), reason: id);
        offsets.add(tester.getTopLeft(run).dy - tester.getTopLeft(row).dy);
      }
      expect(offsets.every((o) => (o - offsets.first).abs() < 1), isTrue, reason: '$offsets');
    });

    testWidgets("'다음' 배지는 이름 아래 그 한 줄 끝", (tester) async {
      await _pump(tester, const RoutinesScreen());
      final badge = find.byKey(const Key('routine-next-badge-r-noon'));
      final line = find.byKey(const Key('routine-line-r-noon'));
      final name = findPlainText('점심 공기청정기 켜기');
      expect(badge, findsOneWidget);
      expect(tester.getTopLeft(badge).dy, greaterThanOrEqualTo(tester.getBottomLeft(name).dy - 0.5));
      final r = tester.getRect(line);
      final b = tester.getRect(badge);
      expect(b.center.dy, inInclusiveRange(r.top, r.bottom), reason: '$b $r');
      expect(b.left, greaterThan(r.left + 40), reason: '줄 머리가 아니라 글 뒤 $b $r');
    });

    testWidgets("홈에서 '자동으로 해요'인 루틴은 목록에도 '자동으로 해요'", (tester) async {
      await _pump(tester, const RoutinesScreen());
      for (final id in ['r-eve', 'r-morn']) {
        expect(_in(find.byKey(Key('routine-row-$id')), findPlainText('자동으로 해요')), findsOneWidget, reason: id);
      }
      for (final id in ['r-noon', 'r-heat']) {
        expect(_in(find.byKey(Key('routine-row-$id')), findPlainText('자동으로 해요')), findsNothing, reason: id);
      }
    });
  });

  group('2. 자동으로 하기 탭', () {
    testWidgets('머리 안내는 낱말 중간에서 꺾이지 않는다', (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동으로 하기'));
      await tester.pumpAndSettle();
      final intro = tester.widget<Text>(find.byKey(const Key('auto-rules-intro-text')));
      expect(intro.data, contains('자$kWordJoiner동'));
    });

    testWidgets("사용자가 끈 규칙은 짧은 '꺼 둠' — 긴 문장 배지는 없다", (tester) async {
      await _pump(tester, const RoutinesScreen());
      await tester.tap(findPlainText('자동으로 하기'));
      await tester.pumpAndSettle();
      final off = find.byKey(const Key('auto-rule-paused-ar-heat'));
      expect(off, findsOneWidget);
      expect(_in(off, findPlainText('꺼 둠')), findsOneWidget);
      expect(findPlainText('자동으로 하기를 꺼 두셨어요', contains: true), findsNothing);
      // 다른 까닭으로 꺼진 규칙은 그 까닭 배지 그대로.
      expect(findPlainText('비상 정지로 꺼졌어요', contains: true), findsOneWidget);
      expect(find.byKey(const Key('auto-rule-paused-ar-estop')), findsNothing);
      expect(find.byKey(const Key('auto-rule-paused-ar-eve')), findsNothing);
    });
  });

  group('3. 기록', () {
    testWidgets("'루틴 · 물어보고'·'사람이 직접', '봐 주세요'에는 까닭 한 줄", (tester) async {
      await _pump(tester, const HistoryScreen());
      expect(findPlainText('허락하고 실행', contains: true), findsNothing);
      expect(_in(find.byKey(const ValueKey('history-j-ask')), findPlainText('루틴 · 물어보고', contains: true)),
          findsOneWidget);
      expect(_in(find.byKey(const ValueKey('history-j-auto')), findPlainText('루틴 · 자동으로', contains: true)),
          findsOneWidget);
      expect(_in(find.byKey(const ValueKey('history-j-me')), findPlainText('사람이 직접', contains: true)),
          findsOneWidget);
      final unk = find.byKey(const ValueKey('history-j-unk'));
      expect(_in(unk, findPlainText('봐 주세요')), findsOneWidget);
      final reason = find.byKey(const Key('history-reason-j-unk'));
      expect(_in(unk, reason), findsOneWidget);
      expect(find.descendant(of: reason, matching: findPlainText('눌렸는지 몰라요'), matchRoot: true), findsOneWidget);
      // 됐어요 줄에는 까닭 줄이 없다.
      expect(find.byKey(const Key('history-reason-j-me')), findsNothing);
    });
  });

  group('4. 홈 전자레인지 칸', () {
    testWidgets("자리 확인을 모르면 띠가 그 한 문장 — '준비됐어요'와 엇갈리지 않는다", (tester) async {
      await _pump(tester, const HomeScreen(), installed: const []);
      final card = find.byKey(const Key('appliance-card-mw'));
      expect(card, findsOneWidget);
      final band = find.byKey(const Key('appliance-band-mw'));
      expect(_in(band, findPlainText('자리 확인을 했는지 몰라요')), findsOneWidget);
      expect(_in(card, findPlainText('준비됐어요')), findsNothing);
      expect(_in(card, findPlainText('자리 확인', contains: true)), findsOneWidget);
    });
  });

  group('5. 설정', () {
    testWidgets("본체 연결이 끊겨 못 읽은 값은 까닭과 함께 — '새로 보기'는 따로 단추", (tester) async {
      await _pump(tester, const SettingsScreen(), hub: RpiConnectionState.unreachable, down: true);
      expect(findPlainText('연결됐는지 몰라요'), findsNothing);
      expect(findPlainText('본체와 연결이 끊겨 못 불러왔어요'), findsWidgets);
      final quiet = find.byKey(const Key('settings-row-quiet'));
      expect(_in(quiet, findPlainText('본체와 연결이 끊겨', contains: true)), findsOneWidget);
      expect(_in(quiet, findPlainText('새로 보기', contains: true)), findsNothing);
      final refresh = find.byKey(const Key('settings-quiet-refresh'));
      expect(refresh, findsOneWidget);
      expect(_in(refresh, findPlainText('새로 보기')), findsOneWidget);
    });

    test('조용한 시간 값 — 까닭이 없으면 지어내지 않는다', () {
      expect(quietRowValue(null, hasApi: true), '못 불러왔어요');
      expect(quietRowValue(null, hasApi: true, hub: RpiConnectionState.unreachable), '본체와 연결이 끊겨 못 불러왔어요');
    });
  });

  group('6. 루틴 편집 기다리기 단계', () {
    testWidgets("'[전자레인지] 끝나면' 한 줄", (tester) async {
      await _pump(
        tester,
        const RoutineEditorScreen(
          initial: Routine(
            id: 'rt-1',
            name: '아침 데우기',
            steps: [
              RoutineStep.press('mw', ['시작']),
              RoutineStep.wait('mw'),
            ],
            trigger: RoutineTrigger.manual(),
          ),
        ),
        size: const Size(390, 1400),
      );
      expect(findPlainText('동작이', contains: true), findsNothing);
      final done = findPlainText('끝나면');
      expect(done, findsOneWidget);
      expect(_lines(tester, done), 1);
      // 가전 칩과 같은 줄.
      final chips = findPlainText('전자레인지');
      final chip = chips.evaluate().map((e) => tester.getCenter(find.byWidget(e.widget)).dy).toList();
      final y = tester.getCenter(done).dy;
      expect(chip.any((c) => (c - y).abs() < 8), isTrue, reason: '$chip $y');
    }, skip: _noKoreanFont != null);
  });

  group('7. 큰 글씨 루틴', () {
    testWidgets("200%에서 '다음' 배지는 이름 아래 한 줄 안 — 시각과 이름 사이에 혼자 서지 않는다", (tester) async {
      await _pump(tester, const RoutinesScreen(), scale: 2.0);
      final badge = find.byKey(const Key('routine-next-badge-r-noon'));
      final line = find.byKey(const Key('routine-line-r-noon'));
      final name = findPlainText('점심 공기청정기 켜기');
      expect(tester.getTopLeft(badge).dy, greaterThanOrEqualTo(tester.getBottomLeft(name).dy - 0.5));
      final r = tester.getRect(line);
      final b = tester.getRect(badge);
      expect(b.top, greaterThanOrEqualTo(r.top - 0.5));
      expect(b.bottom, lessThanOrEqualTo(r.bottom + 0.5));
    });
  });

  group('8. 직접 누르기 빈 칸', () {
    testWidgets('버튼 없는 칸은 점선 빈 자리', (tester) async {
      const appliance = ApplianceMap(
        id: 'grid',
        name: '전자레인지',
        category: ApplianceCategory.microwave,
        rows: 2,
        cols: 2,
        isCustom: true,
        buttons: [
          ApplianceButton(id: 'a', label: '10초', x: 0, y: 0),
          ApplianceButton(id: 'b', label: '30초', x: 1, y: 0),
          ApplianceButton(id: 'c', label: '시작', x: 0, y: 1),
        ],
      );
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        await container.read(customAppliancesProvider.notifier).ensureLoaded();
        await container.read(customAppliancesProvider.notifier).add(appliance);
        await container.read(selectedApplianceProvider.notifier).select(appliance);
      });
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ManualControlScreen()),
      ));
      await tester.pump();
      final empty = find.byKey(const Key('manual-empty-cell-1-1'));
      expect(empty, findsOneWidget);
      expect(tester.getSize(empty).height, greaterThan(40));
      expect(find.byKey(const Key('manual-empty-cell-0-0')), findsNothing);
    });
  });
}
