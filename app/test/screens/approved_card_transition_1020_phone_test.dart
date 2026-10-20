// 실물 폰 10/20: 승인 화면 '지금 하기' 뒤 실행 상태 화면으로 넘어가는 사이(약 0.5초) 옛 화면이
// "이 물음을 찾을 수 없어요. 홈으로 돌아가 주세요."를 잠깐 보였다 — 방금 승인한 카드가 목록에서 빠져서다.
// 이 화면이 방금 승인해서 사라진 카드면 찾을 수 없다고 말하지 않는다(전환 동안 매 프레임 확인).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

const _notFound = '이 물음을 찾을 수 없어요. 홈으로 돌아가 주세요.';

const _airCard = {
  'id': 'sug-air',
  'purpose': '공기청정기를 켤까요?',
  'time_band': '환경',
  'occurrences': 0,
  'steps': <String>[],
  'reason': '공기청정기 센서: 초미세먼지 42 · 나쁨',
  'appliance_id': 'air_purifier',
  'scenario_id': 'air_quality_power_on',
  'is_demo': false,
  'commands': [
    {
      'target_id': 'air_purifier',
      'route': 'thinq',
      'action': 'set_power',
      'args': {'power': 'POWER_ON'},
      'buttons': <String>[],
      'summary': '공기청정기 전원 켜기',
    },
  ],
};

class _Hub {
  bool approved = false;

  http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
        utf8.encode(jsonEncode(body)),
        status,
        headers: {'content-type': 'application/json'},
      );

  RpiApiService api() => RpiApiService(
        'http://rpi5.local:8000',
        client: MockClient((req) async {
          final path = req.url.path;
          // 승인되면 서버는 카드를 내린다.
          if (path == '/suggestions') return _json(approved ? [] : [_airCard]);
          if (path == '/suggestions/sug-air/approve') {
            approved = true;
            return _json({'job_id': 'job-1'});
          }
          if (path == '/status') {
            return _json({'running': true, 'job_id': 'job-1', 'last_job_id': null});
          }
          if (path == '/readiness/air_purifier') {
            return _json({
              'appliance_id': 'air_purifier',
              'route': 'thinq',
              'state': 'operable',
              'can_execute': true,
              'reasons': <String>[],
            });
          }
          return _json({'detail': 'not found'}, 404);
        }),
      );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('지금 하기 → 상태 화면으로 넘어가는 동안 찾을 수 없다는 말이 한 프레임도 보이지 않는다', (tester) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hub = _Hub();
    final router = GoRouter(
      initialLocation: '/suggestion/sug-air',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, __) => Scaffold(
            body: TextButton(
              onPressed: () => context.push('/suggestion/sug-air'),
              child: const Text('열기'),
            ),
          ),
        ),
        GoRoute(
          path: '/suggestion/:id',
          builder: (_, state) => SuggestionScreen(sequenceId: state.pathParameters['id']!),
        ),
        GoRoute(path: '/status', builder: (_, __) => const Scaffold(body: Text('상태 화면'))),
      ],
    );
    await tester.pumpWidget(buildWithProviderState(
      overrides: [
        ...connectedOverrides(),
        rpiApiServiceProvider.overrideWithValue(hub.api()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    // 첫 폴링이 카드를 받을 때까지(그 전 첫 프레임의 '찾을 수 없어요'는 이 시험의 대상이 아니다).
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('지금 하기'), findsOneWidget, reason: '승인 화면이 열린다');

    await tester.tap(find.text('지금 하기'));
    // 전환이 끝날 때까지 매 프레임 — 옛 화면이 '찾을 수 없어요'를 보이면 안 된다.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text(_notFound), findsNothing, reason: '프레임 $i: 방금 승인한 카드는 찾을 수 없는 카드가 아니다');
    }
    expect(hub.approved, isTrue);
    expect(find.text('상태 화면'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
