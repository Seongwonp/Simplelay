// 검토 10/19(core5 1): 실행 요청(승인·말·버튼)의 접수 답을 기다리는 사이에도 본체는 이미 움직이고 있을 수 있다 — 보내기 전에
// '보내는 중'으로 들어가 정지 띠를 남기고, 그사이 누른 정지는 job_id가 오거나 복구가 실행을 찾으면 한 번 더 보낸다.
import 'dart:async';
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
import 'package:simplelay/screens/app_shell.dart' show RunningStopStrip;
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
    headers: {'content-type': 'application/json; charset=utf-8'});

Future<void> _pumps(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('승인', () {
    late Completer<http.Response> approve;
    late int stops;
    late List<String> paths;

    RpiApiService api() => RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
          final path = req.url.path;
          paths.add(path);
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
          if (path == '/suggestions/sug-1/approve') return approve.future;
          if (path == '/stop') {
            stops++;
            return _json({'ok': true, 'was_running': false, 'stop_job_id': null});
          }
          if (path == '/status') return _json({'running': true, 'job_id': 'job-1'});
          return _json({'detail': 'not found'}, 404);
        }));

    Future<ProviderContainer> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      approve = Completer<http.Response>();
      stops = 0;
      paths = [];
      late ProviderContainer container;
      final router = GoRouter(
        initialLocation: '/suggestion/sug-1',
        routes: [
          GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('홈'))),
          GoRoute(
            path: '/suggestion/:id',
            builder: (_, state) => Scaffold(
              body: SuggestionScreen(sequenceId: state.pathParameters['id']!),
              bottomNavigationBar: const RunningStopStrip(),
            ),
          ),
          GoRoute(path: '/status', builder: (_, __) => const Scaffold(body: Text('상태 화면'))),
        ],
      );
      await tester.pumpWidget(buildWithProviderState(
        overrides: [...connectedOverrides(), rpiApiServiceProvider.overrideWithValue(api())],
        onContainerReady: (c) => container = c,
        child: MaterialApp.router(theme: ThemeData.dark(), routerConfig: router),
      ));
      await _pumps(tester, 12);
      return container;
    }

    testWidgets('답을 기다리는 사이에도 정지 띠가 있고, 그사이 누른 정지는 job_id가 오면 한 번 더 보낸다', (tester) async {
      final container = await open(tester);
      await tester.tap(find.text('지금 하기'));
      await _pumps(tester);

      var status = container.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.waiting, reason: '보내기 전에 보내는 중으로 들어간다');
      expect(status.requestId, isNotNull, reason: '보낼 때마다 요청 번호를 짓는다');
      expect(find.byType(RunningStopStrip), findsOneWidget);
      expect(find.byKey(const Key('shell-stop')), findsOneWidget, reason: '답을 기다리는 사이에도 정지가 보인다');

      await tester.tap(find.byKey(const Key('shell-stop')));
      await _pumps(tester);
      expect(stops, 1, reason: '실행 번호를 몰라도 정지는 바로 그 본체로 간다');
      expect(container.read(executionStatusProvider).message,
          ExecutionStatusNotifier.stopWhileSubmittingNotice);

      approve.complete(_json({'job_id': 'job-1'}));
      await _pumps(tester);
      status = container.read(executionStatusProvider);
      expect(status.sequenceId, 'job-1');
      expect(stops, 2, reason: '앞의 정지가 접수보다 먼저 닿았을 수 있어 job_id가 오면 다시 보낸다');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('본체가 거절하면 보내는 중을 거두고 보내기 전으로 돌아간다', (tester) async {
      final container = await open(tester);
      await tester.tap(find.text('지금 하기'));
      await _pumps(tester);
      expect(container.read(executionStatusProvider).phase, ExecutionPhase.waiting);

      approve.complete(_json({'detail': 'busy'}, 409));
      await _pumps(tester);
      expect(container.read(executionStatusProvider).phase, ExecutionPhase.idle);
      expect(stops, 0);
      expect(find.text('다른 일을 하는 중이에요. 끝난 뒤 다시 해 주세요.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('답을 모르게 된 뒤에도 보내는 사이 누른 정지를 기억해 지금 한 번, 실행을 찾으면 또 한 번 보낸다', () async {
    var stops = 0;
    var running = false;
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
      if (req.url.path == '/stop') {
        stops++;
        return _json({'ok': true, 'was_running': false, 'stop_job_id': null});
      }
      return _json(running ? {'running': true, 'job_id': 'job-late'} : {'running': false});
    }));
    final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final n = c.read(executionStatusProvider.notifier);
    final id = n.beginSubmitting(api: api, label: '시작');
    await n.emergencyStop();
    expect(stops, 1);
    n.beginSubmissionUnknown(api: api, label: '시작', requestId: id);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(stops, 2, reason: '앞의 정지 뒤에 접수됐을 수 있다');
    expect(c.read(executionStatusProvider).requestId, id);
    running = true;
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(c.read(executionStatusProvider).sequenceId, 'job-late');
    expect(stops, 3, reason: '복구가 실행을 찾으면 다시 보낸다');
  });
}
