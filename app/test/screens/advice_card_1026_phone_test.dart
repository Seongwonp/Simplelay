// 2026-10-26 조언 카드 — 가전을 움직이지 않는 말 한마디. '알겠어요'(reason=acknowledged)·'괜찮아요'(이유 없음)만 있고
// '지금 하기'·승인은 없다.
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

import '../helpers/test_helpers.dart';

const _advice = Suggestion(
  sequenceId: 'a1',
  label: '창문을 열어 환기해 보세요',
  steps: [],
  source: SuggestionSource.http,
  timeBand: '조언',
  reason: '실내 습도가 74%로 꽤 습해요. 바깥은 18도로 선선하니 잠깐 창문을 열어 환기해 보시는 건 어떨까요?',
  signals: [SuggestionSignal(label: '집에 계심')],
  kind: 'advice',
);

Widget _build(Suggestion s, RpiApiService api) => buildWithProviderState(
      suggestions: [s],
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([kTestAppliance]),
        rpiApiServiceProvider.overrideWithValue(api),
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

void main() {
  test("본체 JSON의 kind를 읽는다(없으면 'action')", () {
    final r = RpiSuggestion.fromJson(
        {'id': 'x', 'purpose': 'p', 'time_band': '조언', 'occurrences': 0, 'kind': 'advice'});
    expect(r.kind, 'advice');
    expect(RpiSuggestion.fromJson({'id': 'y', 'purpose': 'p', 'time_band': '저녁', 'occurrences': 1}).kind, 'action');
    expect(_advice.isAdvice, isTrue);
  });

  for (final (key, body) in [
    ('advice-acknowledge', {'mute': false, 'reason': 'acknowledged'}),
    ('advice-dismiss', {'mute': false}),
  ]) {
    testWidgets("조언 화면: '$key'는 실행 없이 닫는다", (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final calls = <String>[];
      final bodies = <Object?>[];
      final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
        calls.add(req.url.path);
        if (req.url.path.endsWith('/reject')) bodies.add(jsonDecode(req.body));
        return http.Response('{"ok":true}', 200);
      }));
      await tester.pumpWidget(_build(_advice, api));
      await tester.pumpAndSettle();
      expect(find.text('창문을 열어 환기해 보세요'), findsOneWidget);
      expect(find.text('알겠어요'), findsOneWidget);
      expect(find.text('괜찮아요'), findsOneWidget);
      expect(find.text('지금 하기'), findsNothing);
      expect(find.text('집에 계심'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key(key)));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(calls.where((p) => p.endsWith('/approve')), isEmpty);
      expect(bodies, [body]);
      expect(find.text('home'), findsOneWidget);
    });
  }
}
