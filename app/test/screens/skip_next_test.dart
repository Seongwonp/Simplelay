// 다음 루틴 '오늘은 건너뛰기'(사용자 결정 2026-10-18) — 홈 '지금 우리 집'의 다음 예정 줄과 루틴 탭의 '다음' 줄.
//
// - 본체 `/routines/next` 항목의 `skip_action_label`(단추 말)·`skip_label`(건너뛴 뒤 표시 말)을 그대로 쓴다 —
//   폰이 날짜 말을 만들지 않는다.
// - 누르면 `POST /routines/next/skip`(본문은 next 항목의 routine_id·at 그대로), 되돌리기는 `/unskip`.
//   확인 창은 없다(되돌리기가 있다). 응답을 기다리는 동안 두 번째 탭은 버린다.
// - 실패면 서버 detail을 스낵바로. 409면 다음 예정을 다시 받는다.
// - 조용한 시간이라 건너뛰는 회차(`quiet_skip`)·옛 본체(단추 말 없음)에는 단추가 없다.
// - 건너뛰기는 실행 경로를 부르지 않는다(아래 서버는 /execute·approve가 불리면 실패).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/line_break.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/routines_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/theme/app_tokens.dart';

import '../helpers/test_helpers.dart';

const _at = '2026-10-18T22:00:00+09:00';

Map<String, dynamic> _routine() => {
      'schema_version': 1,
      'id': 'rt-1',
      'name': '저녁 공기청정기 켜기',
      'steps': [
        {'kind': 'press_sequence', 'appliance_id': 'test-microwave', 'buttons': ['시작']},
      ],
      'trigger': {
        'kind': 'time',
        'days': [0, 1, 2, 3, 4, 5, 6],
        'time': '22:00',
      },
      'when': '매일 22:00',
      'mode': 'approve',
      'enabled': true,
    };

class _Hub {
  bool skipped = false;

  /// 이 값이 있으면 skip·unskip이 이 상태와 detail로 거절한다.
  (int, String)? reject;

  /// 있으면 skip·unskip 응답을 이것이 끝날 때까지 붙든다(중복 탭 시험).
  Future<void>? gate;

  /// 다음 항목에 덧붙일 값(조용한 시간·옛 본체 흉내).
  Map<String, dynamic> nextExtra = const {};
  bool oldServer = false;

  /// `/routines/auto-rules` 응답(루틴 줄의 '자동'·'자동 꺼짐' 표지).
  List<Map<String, dynamic>> rules = const [];

  final requests = <String>[];
  final bodies = <Map<String, dynamic>>[];

  int count(String request) => requests.where((r) => r == request).length;

  Map<String, dynamic> _next() => {
        'routine_id': 'rt-1',
        'name': '저녁 공기청정기 켜기',
        'at': _at,
        'when': '매일 22:00',
        'mode': 'approve',
        'mode_label': '승인 후 실행',
        'auto': true,
        'day_label': '오늘',
        if (!oldServer) ...{
          'skipped': skipped,
          'skip_label': skipped ? '오늘은 건너뛰어요' : null,
          'skip_action_label': '오늘은 건너뛰기',
        },
        ...nextExtra,
      };

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          requests.add('${req.method} $path');
          if (path.startsWith('/execute') || path.endsWith('/approve') || path == '/stop') {
            fail('건너뛰기가 실행·정지 경로를 불렀어요: ${req.method} $path');
          }
          if (req.method == 'GET' && path == '/routines/next') return _json([_next()]);
          if (req.method == 'POST' && (path == '/routines/next/skip' || path == '/routines/next/unskip')) {
            bodies.add(jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, dynamic>);
            final g = gate;
            if (g != null) await g;
            final r = reject;
            if (r != null) return _json({'detail': r.$2}, r.$1);
            skipped = path.endsWith('/skip');
            return _json(_next());
          }
          if (req.method == 'GET' && path == '/routines') return _json([_routine()]);
          if (req.method == 'GET' && path == '/routines/templates') return _json(const []);
          if (req.method == 'GET' && path == '/routines/auto-rules') return _json(rules);
          if (path == '/suggestions') return _json(const []);
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

Widget _app(_Hub hub, String initial) {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
      GoRoute(path: '/routines', builder: (_, __) => const RoutinesScreen()),
      GoRoute(path: '/routine/edit', builder: (_, __) => const Scaffold(body: Text('루틴 편집기'))),
      GoRoute(
        path: '/suggestion/:id',
        builder: (_, state) => Scaffold(body: Text('승인 화면 ${state.pathParameters['id']}')),
      ),
    ],
  );
  return buildWithProviderState(
    overrides: [
      ...connectedOverrides(),
      ...installedOverrides([kTestAppliance]),
      rpiServerOverride(RpiConnectionState.connected),
      rpiApiServiceProvider.overrideWithValue(hub.api()),
    ],
    child: MaterialApp.router(
        theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
        routerConfig: router),
  );
}

void _size(WidgetTester tester, {double width = 400}) {
  tester.view.physicalSize = Size(width, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder _skipButton() => find.byKey(const Key('skip-next-rt-1'));
Finder _undoButton() => find.byKey(const Key('unskip-next-rt-1'));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('다음 예정 항목은 건너뛰기 값을 읽고, 옛 본체면 단추를 두지 않는다', () {
    final run = RoutineNextRun.fromJson({
      'routine_id': 'rt-1',
      'name': '저녁',
      'at': _at,
      'when': '매일 22:00',
      'mode_label': '승인 후 실행',
      'skipped': true,
      'skip_label': '내일은 건너뛰어요',
      'skip_action_label': '내일은 건너뛰기',
    });
    expect(run.skipped, isTrue);
    expect(run.skipLabel, '내일은 건너뛰어요');
    expect(run.skipActionLabel, '내일은 건너뛰기');
    expect(run.canSkip, isTrue);

    final old = RoutineNextRun.fromJson(
        {'routine_id': 'rt-1', 'name': '저녁', 'at': _at, 'when': '매일 22:00', 'mode_label': '승인 후 실행'});
    expect(old.skipped, isFalse);
    expect(old.canSkip, isFalse);

    final quiet = RoutineNextRun.fromJson({
      'routine_id': 'rt-1',
      'name': '저녁',
      'at': _at,
      'when': '매일 22:00',
      'mode_label': '조용한 시간이라 건너뛰었어요',
      'quiet_skip': true,
      'skipped': false,
      'skip_action_label': '오늘은 건너뛰기',
    });
    expect(quiet.canSkip, isFalse);
  });

  testWidgets('홈: 오늘은 건너뛰기 → 본체가 준 말로 "오늘은 건너뛰어요"와 되돌리기, 되돌리면 원래대로', (tester) async {
    _size(tester);
    final hub = _Hub();
    await tester.pumpWidget(_app(hub, '/'));
    await _settle(tester);

    expect(_skipButton(), findsOneWidget);
    expect(find.text(keepWordsTogether('오늘은 건너뛰기')), findsOneWidget);
    expect(_undoButton(), findsNothing);

    await tester.tap(_skipButton());
    await _settle(tester);
    expect(hub.count('POST /routines/next/skip'), 1);
    expect(hub.bodies.single, {'routine_id': 'rt-1', 'at': _at}); // next 항목 값 그대로
    expect(find.text('오늘은 건너뛰어요'), findsOneWidget);
    expect(_undoButton(), findsOneWidget);
    expect(_skipButton(), findsNothing);
    // 건너뛰는 회차에 '자동으로 해요'를 함께 말하지 않는다.
    expect(find.text('자동으로 해요'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing); // 확인 창 없이

    await tester.tap(_undoButton());
    await _settle(tester);
    expect(hub.count('POST /routines/next/unskip'), 1);
    expect(_skipButton(), findsOneWidget);
    expect(find.text('오늘은 건너뛰어요'), findsNothing);
  });

  // 10/19: 건너뛴 상태는 표시 하나('오늘은 건너뛰어요')가 말하고, 그 아래는 작은 회색 굵은 '되돌리기'만(아이콘 없이) —
  // 검은 글자·되돌림 아이콘의 '되돌리기'가 표시와 같은 무게로 한 번 더 말하는 것처럼 보였다. '오늘은 건너뛰기' 모양은 그대로.
  testWidgets('홈: 건너뛰면 표시는 한 번, 되돌리기는 작은 회색 굵은 글자만', (tester) async {
    _size(tester);
    final hub = _Hub();
    await tester.pumpWidget(_app(hub, '/'));
    await _settle(tester);
    final skipText = tester.widget<Text>(
        find.descendant(of: _skipButton(), matching: find.text(keepWordsTogether('오늘은 건너뛰기'))));
    final skipColor = skipText.style?.color;
    expect(find.descendant(of: _skipButton(), matching: find.byType(Icon)), findsOneWidget, reason: '건너뛰기 모양 그대로');

    await tester.tap(_skipButton());
    await _settle(tester);
    expect(find.text('오늘은 건너뛰어요'), findsOneWidget);
    expect(find.descendant(of: _undoButton(), matching: find.byType(Icon)), findsNothing);
    final undoText = tester.widget<Text>(find.descendant(of: _undoButton(), matching: find.byType(Text)));
    expect(undoText.style?.fontWeight, FontWeight.w700);
    expect(undoText.style?.fontSize, AppFont.caption);
    expect(undoText.style?.color, isNot(skipColor), reason: '회색');
    expect(tester.getRect(_undoButton()).height, greaterThanOrEqualTo(48));
  });

  testWidgets('응답을 기다리는 동안 두 번 눌러도 요청은 한 번', (tester) async {
    _size(tester);
    final gate = Completer<void>();
    final hub = _Hub()..gate = gate.future;
    await tester.pumpWidget(_app(hub, '/'));
    await _settle(tester);

    await tester.tap(_skipButton());
    await tester.pump();
    await tester.tap(_skipButton(), warnIfMissed: false);
    await tester.pump();
    gate.complete();
    await _settle(tester);
    expect(hub.count('POST /routines/next/skip'), 1);
    expect(_undoButton(), findsOneWidget);
  });

  testWidgets('409면 본체 문장을 스낵바로 보이고 다음 예정을 다시 받는다', (tester) async {
    _size(tester);
    final hub = _Hub()..reject = (409, '이미 지난 회차라 건너뛸 수 없어요');
    await tester.pumpWidget(_app(hub, '/'));
    await _settle(tester);
    final before = hub.count('GET /routines/next');

    await tester.tap(_skipButton());
    await _settle(tester);
    expect(find.text('이미 지난 회차라 건너뛸 수 없어요'), findsOneWidget);
    expect(hub.count('GET /routines/next'), greaterThan(before));
    expect(_skipButton(), findsOneWidget); // 바뀌지 않았다
  });

  testWidgets('연결 실패 같은 다른 오류도 스낵바(화면은 그대로)', (tester) async {
    _size(tester);
    final hub = _Hub()..reject = (500, '');
    await tester.pumpWidget(_app(hub, '/'));
    await _settle(tester);

    await tester.tap(_skipButton());
    await _settle(tester);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(_skipButton(), findsOneWidget);
  });

  testWidgets('조용한 시간이라 건너뛰는 회차·옛 본체에는 건너뛰기 단추가 없다', (tester) async {
    _size(tester);
    final quiet = _Hub()
      ..nextExtra = {'quiet_skip': true, 'mode_label': '조용한 시간이라 건너뛰었어요'};
    await tester.pumpWidget(_app(quiet, '/'));
    await _settle(tester);
    expect(find.text('조용한 시간이라 안 해요'), findsOneWidget);
    expect(_skipButton(), findsNothing);

    final old = _Hub()..oldServer = true;
    await tester.pumpWidget(_app(old, '/'));
    await _settle(tester);
    expect(find.byKey(const Key('home-now')), findsOneWidget);
    expect(_skipButton(), findsNothing);
  });

  testWidgets('루틴 탭: "다음" 줄에서 건너뛰기 → 줄 표시가 "오늘은 건너뛰어요", 되돌리기', (tester) async {
    _size(tester, width: 500);
    final hub = _Hub();
    await tester.pumpWidget(_app(hub, '/routines'));
    await _settle(tester);

    expect(_skipButton(), findsOneWidget);
    await tester.tap(_skipButton());
    await _settle(tester);
    expect(hub.count('POST /routines/next/skip'), 1);
    expect(find.byKey(const Key('routine-next-badge-rt-1')), findsOneWidget);
    final mark = tester.widget<Text>(find.descendant(
        of: find.byKey(const Key('routine-next-badge-rt-1')), matching: find.byType(Text)));
    expect(mark.semanticsLabel, '오늘은 건너뛰어요');
    expect(find.byKey(const Key('routine-auto-badge-rt-1')), findsNothing);
    expect(_undoButton(), findsOneWidget);
    // 줄을 누르면 편집으로 가는데, 단추는 제 몫만 한다(편집으로 가지 않았다).
    expect(find.text('루틴 편집기'), findsNothing);

    await tester.tap(_undoButton());
    await _settle(tester);
    expect(hub.count('POST /routines/next/unskip'), 1);
    expect(_skipButton(), findsOneWidget);
  });

  // 평가 10/19(폰 루틴 탭): 건너뛴 줄이 이름 옆 '오늘은 건너뛰어요'·'자동 꺼짐' 두 줄 표지 + 스위치 + '지금 하기' +
  // 그 아래 혼자 떨어진 '되돌리기'였다. 이름 옆 표지는 한 줄, '되돌리기'는 건너뛴 표지 바로 옆.
  testWidgets("루틴 탭: 건너뛴 줄은 이름 옆 표지 한 줄, '되돌리기'는 건너뛴 표지 옆", (tester) async {
    _size(tester, width: 390);
    final hub = _Hub()
      ..skipped = true
      ..rules = [
        {
          'id': 'ar-1',
          'name': '저녁 공기청정기 켜기',
          'condition_text': '매일 밤 10시에',
          'action_text': '켜요',
          'condition_time': '22:00',
          'enabled': false,
          'fingerprint': 'fp',
        },
      ];
    await tester.pumpWidget(_app(hub, '/routines'));
    await _settle(tester);

    final marks = find.byKey(const Key('routine-marks-rt-1'));
    final auto = find.byKey(const Key('routine-auto-badge-rt-1'));
    final skipMark = find.byKey(const Key('routine-next-badge-rt-1'));
    expect(auto, findsOneWidget);
    expect(skipMark, findsOneWidget);
    expect(_undoButton(), findsOneWidget);
    // 이름 옆에는 '자동 꺼짐' 하나 — 건너뛴 표지는 그 묶음에 없다(두 줄로 쌓이지 않는다).
    expect(find.descendant(of: marks, matching: auto), findsOneWidget);
    expect(find.descendant(of: marks, matching: skipMark), findsNothing);
    // '되돌리기'는 건너뛴 표지와 같은 줄(가운데 높이가 같다), 그 오른쪽.
    expect((tester.getCenter(_undoButton()).dy - tester.getCenter(skipMark).dy).abs(), lessThan(4));
    expect(tester.getTopLeft(_undoButton()).dx, greaterThan(tester.getTopRight(skipMark).dx - 1));
    // 설명 줄 아래, '지금 하기'보다 위(상태 → 행동).
    expect(tester.getTopLeft(skipMark).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byKey(const Key('routine-line-rt-1'))).dy));
    final run = find.byKey(const Key('routine-run-rt-1'));
    if (run.evaluate().isNotEmpty) {
      expect(tester.getTopLeft(run).dy, greaterThanOrEqualTo(tester.getBottomLeft(_undoButton()).dy - 1));
    }
    // 낭독은 그대로 다 남는다.
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('오늘은 건너뛰어요')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('자동 꺼짐')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('건너뛰기 되돌리기')), findsOneWidget);
    semantics.dispose();
  });

  for (final initial in ['/', '/routines']) {
    testWidgets('큰 글씨(200%)에서도 넘치지 않는다 — $initial', (tester) async {
      _size(tester, width: 360);
      final hub = _Hub();
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(_app(hub, initial));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(_skipButton(), findsOneWidget);
      await tester.tap(_skipButton());
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(_undoButton(), findsOneWidget);
    });
  }
}
