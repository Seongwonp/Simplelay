// 2026-10-13 에뮬레이터: 실행이 끝난 뒤 기록 탭으로 가면 "아직 실행 기록이
// 없어요"였고, 당겨서 새로 고침해야 기록이 보였다(서버 /history에는 이미 있음).
// 기록 탭은 IndexedStack에 남아 있어 처음 받은 목록을 계속 쓴다.
// 실행이 끝나거나 기록 탭에 들어가면 다시 받아야 한다. 조회할 수 없을 때는
// '기록 없음'으로 말하지 않는다.
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
import 'package:simplelay/screens/app_shell.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import '../helpers/test_helpers.dart' show findPlainText;

class _Hub {
  final entries = <Map<String, dynamic>>[];
  int historyCalls = 0;

  late final api =
      RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
    if (req.url.path == '/history') {
      historyCalls++;
      return http.Response.bytes(
        utf8.encode(jsonEncode(entries)),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response('{"detail":"not found"}', 404);
  }));

  void addRun() => entries.insert(0, {
        'job_id': 'job-1',
        'finished_at': DateTime.now().toIso8601String(),
        'purpose': '아침 데우기',
        'status': 'succeeded',
        'retry_count': 0,
        'buttons': [
          {'button': '시작', 'success': true, 'attempts': 1},
        ],
      });
}

GoRouter _router(String initial) => GoRouter(
      initialLocation: initial,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, __, shell) => AppShell(navigationShell: shell),
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(path: '/', builder: (_, __) => const Text('home-body')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/appliances',
                  builder: (_, __) => const Text('routines-body')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/automation', builder: (_, __) => const Text('automation-body')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/history',
                  builder: (_, __) => const HistoryScreen()),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/dev', builder: (_, __) => const Text('dev-body')),
            ]),
          ],
        ),
      ],
    );

Future<ProviderContainer> _pump(
    WidgetTester tester, RpiApiService? api, String initial) async {
  final container = ProviderContainer(overrides: [
    rpiApiServiceProvider.overrideWithValue(api),
  ]);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: ThemeData.dark().copyWith(splashFactory: InkRipple.splashFactory),
      routerConfig: _router(initial),
    ),
  ));
  await _settle(tester);
  return container;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 걸림 조회 등 주기 타이머를 정리한다(위젯을 내리고 컨테이너를 닫는다).
Future<void> _end(WidgetTester tester, ProviderContainer c) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
  await tester.pump(const Duration(seconds: 6));
}

void _seed(ProviderContainer c, ExecutionPhase phase) {
  // Test-only seed of the real notifier.
  // ignore: invalid_use_of_protected_member
  c.read(executionStatusProvider.notifier).state =
      ExecutionStatus(phase: phase, label: '아침 데우기');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('실행이 끝나면 기록을 다시 받는다(당겨서 새로 고침 없이)', (tester) async {
    final hub = _Hub();
    final c = await _pump(tester, hub.api, '/history');
    expect(find.textContaining('아직 기록이 없어요'), findsOneWidget);

    _seed(c, ExecutionPhase.running);
    await _settle(tester);
    hub.addRun(); // 서버는 실행을 마치며 기록을 남긴다.
    _seed(c, ExecutionPhase.completed);
    await _settle(tester);

    expect(findPlainText('아침 데우기'), findsOneWidget);
    expect(find.textContaining('아직 기록이 없어요'), findsNothing);
    await _end(tester, c);
  });

  testWidgets('기록 탭에 다시 들어가면 기록을 다시 받는다', (tester) async {
    final hub = _Hub();
    final c = await _pump(tester, hub.api, '/history');
    expect(find.textContaining('아직 기록이 없어요'), findsOneWidget);

    await tester.tap(find.text('홈'));
    await _settle(tester);
    hub.addRun(); // 다른 기기(키오스크 등)에서 실행이 끝났다.
    await tester.tap(find.text('기록'));
    await _settle(tester);

    expect(findPlainText('아침 데우기'), findsOneWidget);
    await _end(tester, c);
  });

  testWidgets('허브 연결이 없어 조회하지 못하면 "기록 없음"으로 말하지 않는다', (tester) async {
    final c = await _pump(tester, null, '/history');
    expect(find.textContaining('아직 기록이 없어요'), findsNothing);
    expect(find.textContaining('기록을 불러오지 못했어요'), findsOneWidget);
    await _end(tester, c);
  });
}
