import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/voice_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/screens/voice_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import '../helpers/test_helpers.dart';

http.Response jsonResponse(Object body, [int code = 200]) =>
    http.Response(jsonEncode(body), code,
        headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, Object> proposal(String kind) => {
      'understood': true,
      'source': 'llm',
      'label': '시험 동작',
      'question': '시험 동작을 할까요?',
      'action': switch (kind) {
        'thinq' => {
            'kind': kind,
            'appliance_id': 'air',
            'action': 'power',
            'args': {'power': 'ON'}
          },
        'routine' => {
            'kind': kind,
            'routine_id': 'saved',
            'fingerprint': 'a' * 64
          },
        _ => {
            'kind': kind,
            'appliance_id': 'microwave',
            'buttons': ['즉석밥', '시작']
          },
      },
    };

Future<void> mount(
    WidgetTester tester, Future<http.Response> Function(http.Request) handler,
    {bool custom = false}) async {
  SharedPreferences.setMockInitialValues({});
  final api = RpiApiService('http://hub',
      apiKey: 'test-key', client: MockClient(handler));
  final container = ProviderContainer(overrides: [
    ...installedOverrides([
      custom
          ? ApplianceMap.fromJson(
              {...kTestAppliance.toJson(), 'is_custom': true})
          : kTestAppliance
    ]),
    rpiApiServiceProvider.overrideWithValue(api),
  ]);
  addTearDown(container.dispose);
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const VoiceScreen()),
    GoRoute(
        path: '/status',
        builder: (_, __) => const Scaffold(body: Text('tracked-job'))),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
      container: container, child: MaterialApp.router(routerConfig: router)));
  container.read(voiceTextProvider.notifier).state = '공기가 텁텁하네';
  await tester.pump();
  await tester.ensureVisible(find.text('이대로 하기'));
  await tester.tap(find.text('이대로 하기'));
  await tester.pump();
}

void main() {
  testWidgets('등록 가전의 기존 해석기 미설정도 읽기 전용 폴백 후 확인', (tester) async {
    var fallback = 0;
    await mount(tester, (r) async {
      if (r.url.path == '/execute-for-appliance') {
        return jsonResponse({
          'detail':
              'no LLM client configured -- appliance-aware voice commands need one'
        }, 503);
      }
      if (r.url.path == '/intent/understand') {
        fallback++;
        return jsonResponse(proposal('buttons'));
      }
      return jsonResponse({});
    }, custom: true);
    await tester.pumpAndSettle();
    expect(fallback, 1);
    expect(find.text('시험 동작을 할까요?'), findsOneWidget);
    await tester.tap(find.text('아니요'));
    await tester.pumpAndSettle();
  });
  for (final kind in ['buttons', 'thinq', 'routine']) {
    testWidgets('$kind 제안은 네를 누른 뒤에만 기존 경로 실행', (tester) async {
      final writes = <http.Request>[];
      await mount(tester, (r) async {
        if (r.url.path == '/execute') {
          return jsonResponse({'detail': '못 알아들었어요'}, 422);
        }
        if (r.url.path == '/intent/understand') {
          return jsonResponse(proposal(kind));
        }
        if (r.method == 'POST') {
          writes.add(r);
          if (r.url.path.endsWith('/trigger')) {
            return jsonResponse({
              'kind': 'suggestion',
              'suggestion': {'id': 'card'}
            });
          }
          return jsonResponse({'job_id': 'job1'});
        }
        if (r.url.path == '/suggestions') {
          return jsonResponse([
            {
              'id': 'card',
              'purpose': '시험',
              'time_band': '',
              'occurrences': 0,
              'scenario_id': 'routine:saved@${'a' * 12}'
            }
          ]);
        }
        return jsonResponse({'running': false});
      });
      await tester.pumpAndSettle();
      expect(find.text('시험 동작을 할까요?'), findsOneWidget);
      expect(writes, isEmpty);
      await tester.tap(find.text('네'));
      await tester.pumpAndSettle();
      expect(
          writes.first.url.path,
          switch (kind) {
            'thinq' => '/thinq/command',
            'routine' => '/routines/saved/trigger',
            _ => '/execute-buttons',
          });
      expect(find.text('tracked-job'), findsOneWidget);
      expect(writes.last.body, contains('client_request_id'));
      final scope =
          ProviderScope.containerOf(tester.element(find.text('tracked-job')));
      scope.invalidate(executionStatusProvider);
      await tester.pump();
    });
  }
  testWidgets('아니요는 실행하지 않는다', (tester) async {
    var writes = 0;
    await mount(tester, (r) async {
      if (r.url.path == '/execute') return jsonResponse({'detail': '모름'}, 422);
      if (r.url.path == '/intent/understand') {
        return jsonResponse(proposal('buttons'));
      }
      if (r.method == 'POST') writes++;
      return jsonResponse({});
    });
    await tester.pumpAndSettle();
    expect(find.text('시험 동작을 할까요?'), findsOneWidget);
    await tester.tap(find.text('아니요'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('시험 동작을 할까요?'), findsNothing);
  });
  for (final leave in [false, true]) {
    testWidgets('생각 중 ${leave ? '화면 이탈' : '취소'}하면 늦은 응답 무시', (tester) async {
      final reply = Completer<http.Response>();
      var writes = 0;
      await mount(tester, (r) async {
        if (r.url.path == '/execute') {
          return jsonResponse({'detail': '모름'}, 422);
        }
        if (r.url.path == '/intent/understand') return reply.future;
        if (r.method == 'POST') writes++;
        return jsonResponse({});
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('생각하고 있어요…'), findsOneWidget);
      if (leave) {
        await tester.pumpWidget(const MaterialApp(home: Text('다른 화면')));
      } else {
        await tester.tap(find.byKey(const Key('intent-cancel')));
      }
      reply.complete(jsonResponse(proposal('buttons')));
      await tester.pumpAndSettle();
      expect(find.text('시험 동작을 할까요?'), findsNothing);
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    });
  }
  for (final failure in ['off', 'invalid', 'timeout']) {
    testWidgets('$failure면 기존 못 알아들음 안내 유지', (tester) async {
      var fallback = 0;
      await mount(tester, (r) async {
        if (r.url.path == '/execute') {
          return jsonResponse({'detail': '모름'}, 422);
        }
        if (r.url.path == '/intent/understand') {
          fallback++;
          if (failure == 'timeout') throw TimeoutException('test');
          return jsonResponse(failure == 'off'
              ? {'understood': false, 'source': 'off'}
              : proposal('unsafe'));
        }
        return jsonResponse({});
      });
      await tester.pumpAndSettle();
      expect(fallback, 1);
      expect(find.text('무슨 말인지 몰랐어요. 다시 말해 주세요.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }
}
