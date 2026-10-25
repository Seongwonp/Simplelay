// 2026-10-26 '왜 지금' 신호 칩과 '이미 했어요' — 본체가 준 신호만 보이고, 습관 카드에만 '이미 했어요'를 두며
// 누르면 reason=already_done으로 거절한다('이번엔 안 할게요'는 이유 없이 그대로).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/signal_chips.dart';

import '../helpers/test_helpers.dart';

const _signals = [
  SuggestionSignal(label: '집에 계심'),
  SuggestionSignal(label: '평소 오후 10시쯤'),
  SuggestionSignal(label: '최근 7일 중 5일'),
  SuggestionSignal(label: '평일'),
  SuggestionSignal(label: '다섯째 신호'),
];

const _habit = Suggestion(
  sequenceId: 'h1',
  label: '즉석밥 데우기',
  steps: ['BT-08', 'BT-05'],
  applianceId: 'microwave',
  source: SuggestionSource.http,
  timeBand: '저녁',
  occurrences: 5,
  reason: '최근 7일 중 5일, 오후 10시쯤 하셨어요',
  signals: _signals,
  canMarkDone: true,
);

const _plain = Suggestion(
  sequenceId: 'p1',
  label: '즉석밥 데우기',
  steps: ['BT-08', 'BT-05'],
  applianceId: 'microwave',
  source: SuggestionSource.http,
  timeBand: '저녁',
  occurrences: 5,
);

final _chips = find.byWidgetPredicate(
    (w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('suggestion-signal-chip-'));

Widget _build(Suggestion s, {RpiApiService? api}) => buildWithProviderState(
      suggestions: [s],
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([kTestAppliance, kTestAircon]),
        if (api != null) rpiApiServiceProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(
        theme: ThemeData.dark(),
        routerConfig: GoRouter(initialLocation: '/s', routes: [
          GoRoute(path: '/', builder: (_, __) => const Text('home'), routes: [
            GoRoute(path: 's', builder: (_, __) => SuggestionScreen(sequenceId: s.sequenceId)),
          ]),
        ]),
      ),
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  test('본체 JSON의 signals·can_mark_done을 읽는다(없으면 빈 목록·거짓)', () {
    final r = RpiSuggestion.fromJson({
      'id': 'x',
      'purpose': 'p',
      'time_band': '저녁',
      'occurrences': 1,
      'signals': [
        {'label': '집에 계심', 'ok': true},
        {'label': '', 'ok': true},
        {'label': '불을 끄심', 'ok': false},
      ],
      'can_mark_done': true,
    });
    expect(r.signals.map((s) => s.label), ['집에 계심', '불을 끄심']);
    expect(r.signals.last.ok, isFalse);
    expect(r.canMarkDone, isTrue);
    final old = RpiSuggestion.fromJson({'id': 'y', 'purpose': 'p', 'time_band': '저녁', 'occurrences': 1});
    expect(old.signals, isEmpty);
    expect(old.canMarkDone, isFalse);
  });

  test("rejectSuggestion은 reason이 있을 때만 본문에 싣는다", () async {
    final bodies = <Object?>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
      bodies.add(jsonDecode(req.body));
      return http.Response('{"ok":true}', 200);
    }));
    await api.rejectSuggestion('s1');
    await api.rejectSuggestion('s1', reason: 'already_done');
    expect(bodies, [
      {'mute': false},
      {'mute': false, 'reason': 'already_done'},
    ]);
  });

  testWidgets('신호를 칩으로 4개까지만 보인다', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_habit));
    await tester.pumpAndSettle();
    expect(find.byType(SuggestionSignalChips), findsOneWidget);
    expect(_chips, findsNWidgets(4));
    expect(find.text('집에 계심'), findsOneWidget);
    expect(find.text('다섯째 신호'), findsNothing);
  });

  testWidgets("신호가 없으면 칩이 없고 '이미 했어요'도 없다", (tester) async {
    _tall(tester);
    await tester.pumpWidget(_build(_plain));
    await tester.pumpAndSettle();
    expect(_chips, findsNothing);
    expect(find.byKey(const Key('suggestion-already-done')), findsNothing);
  });

  testWidgets("'이미 했어요'는 already_done 이유로 거절한다", (tester) async {
    _tall(tester);
    final calls = <Map<String, dynamic>>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
      if (req.url.path.endsWith('/reject')) calls.add(jsonDecode(req.body) as Map<String, dynamic>);
      return http.Response('{"ok":true}', 200);
    }));
    await tester.pumpWidget(_build(_habit, api: api));
    await tester.pumpAndSettle();
    final done = find.byKey(const Key('suggestion-already-done'));
    expect(done, findsOneWidget);
    expect(tester.getSize(done).height, greaterThanOrEqualTo(48));
    await tester.runAsync(() async {
      await tester.tap(done);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(calls, [
      {'mute': false, 'reason': 'already_done'},
    ]);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget); // '아니요'와 같이 화면을 닫는다
  });
}
