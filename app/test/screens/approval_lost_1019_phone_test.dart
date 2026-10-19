// 검토 10/19(3): 승인 응답(job_id)을 잃으면 '보내지 못했어요'라고 하고 실행을 놓쳐, 본체가 이미 시작한 실행을 멈출 길이
// 없었다. 이제 '시작됐는지 몰라요'로 정지를 남기고, 같은 승인을 다시 물어(본체가 같은 실행 번호를 준다) 그 실행을 이어서 본다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/suggestion_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

Map<String, dynamic> _card() => {
      'id': 'sug-1',
      'purpose': '공기청정기 강풍으로 바꿀까요?',
      'time_band': '시나리오',
      'occurrences': 0,
      'steps': <String>[],
      'reason': '공기가 나빠요',
      'appliance_id': 'air_purifier',
      'is_demo': true,
      'scenario_id': 'cook_done_air',
      'commands': [
        {
          'target_id': 'air_purifier',
          'route': 'thinq',
          'action': 'set_wind_strength',
          'args': {'wind_strength': 'HIGH'},
          'buttons': <String>[],
          'summary': '거실 공기청정기 풍량 강',
        },
      ],
    };

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status,
    headers: {'content-type': 'application/json'});

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('승인 응답을 잃으면 시작됐을 수 있다고 하고 정지를 남기며, 다시 물어 받은 실행을 이어서 본다', (tester) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    var approves = 0;
    var stops = 0;
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
      final path = req.url.path;
      if (path == '/suggestions') return _json([_card()]);
      if (path == '/scenarios') return _json(<dynamic>[]);
      if (path == '/readiness/air_purifier') {
        return _json({
          'appliance_id': 'air_purifier',
          'route': 'thinq',
          'state': 'operable',
          'can_execute': true,
          'reasons': <String>[],
        });
      }
      if (path == '/suggestions/sug-1/approve') {
        approves++;
        if (approves == 1) throw http.ClientException('응답 유실');
        return _json({'job_id': 'job-1'}); // 이미 승인된 카드 — 본체가 같은 실행 번호를 준다
      }
      if (path == '/stop') {
        stops++;
        return _json({'ok': true});
      }
      if (path == '/status') return _json({'running': true, 'job_id': 'job-1'});
      return _json({'detail': 'not found'}, 404);
    }));
    late ProviderContainer container;
    final router = GoRouter(
      initialLocation: '/suggestion/sug-1',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('홈'))),
        GoRoute(
          path: '/suggestion/:id',
          builder: (_, state) => SuggestionScreen(sequenceId: state.pathParameters['id']!),
        ),
        GoRoute(path: '/status', builder: (_, __) => const Scaffold(body: Text('상태 화면'))),
      ],
    );
    await tester.pumpWidget(buildWithProviderState(
      overrides: [...connectedOverrides(), rpiApiServiceProvider.overrideWithValue(api)],
      onContainerReady: (c) => container = c,
      child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
    ));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.text('지금 하기'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(approves, 1);
    expect(find.textContaining('본체에 보내지 못했어요'), findsNothing, reason: '보냈는지 모르는 것을 못 보냈다고 하지 않는다');
    expect(find.text('상태 화면'), findsOneWidget);
    var status = container.read(executionStatusProvider);
    expect(status.phase, ExecutionPhase.unknown);
    expect(status.message, ExecutionStatusNotifier.submissionUnknownNotice);

    await container.read(executionStatusProvider.notifier).emergencyStop();
    expect(stops, 1, reason: '실행 번호를 몰라도 정지는 그 본체로 간다');

    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump(const Duration(milliseconds: 50));
    expect(approves, 2);
    status = container.read(executionStatusProvider);
    expect(status.sequenceId, 'job-1');
    expect(status.phase, ExecutionPhase.running);
    await tester.pumpWidget(const SizedBox());
  });
}
