// 하단 탭 shell — 홈 · 루틴 · 기록 · 설정 네 개(UI 개편안 §4, 2026-10-18).
// 개발자 도구는 탭이 아니라 설정 맨 아래 항목(개발 모드일 때만)이다.
//
// 이 shell은 두 가지를 더 책임진다.
// 1. "지금 보이는 탭"을 알린다 -- 음성 화면처럼 가려지면 마이크를 놓아야 하는
//    화면은 이 신호에 기댄다.
// 2. '상태' 탭이 없어졌으므로, **실행 중에는 어느 탭에서든 정지 줄이 뜬다.**

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/demo_provider.dart';
import 'package:simplelay/providers/estop_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/providers/hub_provider.dart';
import 'package:simplelay/providers/navigation_provider.dart';
import 'package:simplelay/screens/app_shell.dart';

/// main.dart와 같은 브랜치 구성. 화면은 스텁으로 둔다(여기 관심사는 shell).
GoRouter _shellRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, __, shell) => AppShell(navigationShell: shell),
          branches: [
            StatefulShellBranch(routes: [
              GoRoute(
                path: '/',
                builder: (_, __) => const Text('home-body'),
                routes: [
                  GoRoute(
                      path: 'status',
                      builder: (_, __) => const Text('status-body')),
                ],
              ),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/appliances',
                  builder: (_, __) => const Text('appliances-body')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/automation',
                  builder: (_, __) => const Text('automation-body')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/history',
                  builder: (_, __) => const Text('history-body')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/dev', builder: (_, __) => const Text('dev-body')),
            ]),
          ],
        ),
      ],
    );

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool developerMode = false,
  ExecutionStatus? status,
}) async {
  final container = ProviderContainer(overrides: [
    developerModeProvider.overrideWithValue(developerMode),
  ]);
  addTearDown(container.dispose);
  if (status != null) {
    // Test-only seed of the real notifier.
    // ignore: invalid_use_of_protected_member
    container.read(executionStatusProvider.notifier).state = status;
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: _shellRouter()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('모의 사용만으로 개발자 탭을 열지 않아요', (tester) async {
    final container = await _pump(tester);
    // set()은 기기 저장소를 기다려 가짜 시계 위에서 멈춘다 — 상태만 직접 켠다.
    // Test-only seed of the real notifier.
    // ignore: invalid_use_of_protected_member
    container.read(demoModeProvider.notifier).state = true;
    await tester.pumpAndSettle();
    expect(container.read(demoModeProvider), isTrue);
    expect(find.text('개발자'), findsNothing);
  });

  testWidgets('탭은 홈·루틴·기록·설정 네 개이고 개발자 탭은 숨는다', (tester) async {
    await _pump(tester);

    for (final label in ['홈', '가전', '자동 실행', '기록']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('개발자'), findsNothing);
    // 예전 탭(상태·말로 조작·알림)은 없다.
    expect(find.text('상태'), findsNothing);
    expect(find.bySemanticsLabel('말로 하기'), findsNothing);
  });

  testWidgets('서버 개발자 모드여도 탭은 네 개 — 개발자는 설정 안 맨 아래 항목', (tester) async {
    await _pump(tester, developerMode: true);

    for (final label in ['홈', '가전', '자동 실행', '기록']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('개발자'), findsNothing);
  });

  testWidgets('탭을 옮기면 currentTabIndexProvider가 따라간다', (tester) async {
    final container = await _pump(tester);
    expect(container.read(currentTabIndexProvider), homeTabIndex);

    await tester.tap(find.text('가전'));
    await tester.pumpAndSettle();
    expect(find.text('appliances-body'), findsOneWidget);
    expect(container.read(currentTabIndexProvider), appliancesTabIndex);

    await tester.tap(find.text('기록'));
    await tester.pumpAndSettle();
    expect(container.read(currentTabIndexProvider), historyTabIndex);

    await tester.tap(find.text('자동 실행'));
    await tester.pumpAndSettle();
    expect(container.read(currentTabIndexProvider), automationTabIndex);

    // 홈으로 돌아오는 전이 -- 음성 화면(홈 위)의 마이크 정리가 여기에 걸린다.
    await tester.tap(find.text('홈'));
    await tester.pumpAndSettle();
    expect(container.read(currentTabIndexProvider), homeTabIndex);
  });

  testWidgets('실행 중이면 어느 탭에서든 정지 줄이 뜨고, 없으면 없다', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('shell-stop')), findsNothing);
  });

  testWidgets('실행 중 정지 줄은 탭을 옮겨도 남는다', (tester) async {
    await _pump(
      tester,
      status: const ExecutionStatus(
        phase: ExecutionPhase.running,
        label: '아침 데우기',
      ),
    );
    expect(find.text('아침 데우기 하고 있어요'), findsOneWidget);
    expect(find.byKey(const Key('shell-stop')), findsOneWidget);

    await tester.tap(find.text('가전'));
    await tester.pump();
    expect(find.byKey(const Key('shell-stop')), findsOneWidget);
  });

  // 첫 사용 평가(10/24): 키오스크·자동 실행이 시작한 실행은 폰이 추적하지 않아 정지 줄이 뜨지 않았다 — 본체 상태
  // (`/status.running`)가 실행 중이면 폰이 시작하지 않은 실행에도 정지 줄을 띄우고, 같은 POST /stop을 보낸다.
  testWidgets('폰이 시작하지 않은 실행도 본체가 실행 중이라 하면 정지 줄이 뜨고 정지를 보낸다', (tester) async {
    final stops = <String>[];
    final api = RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((req) async {
        if (req.method == 'POST' && req.url.path == '/stop') {
          stops.add(req.url.path);
          return http.Response(
              jsonEncode({'stop_level': 'sent', 'stop_job_id': 'kiosk-1', 'was_running': true}), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('{}', 404);
      }),
    );
    final container = ProviderContainer(overrides: [
      developerModeProvider.overrideWithValue(false),
      rpiApiServiceProvider.overrideWithValue(api),
      estopProvider.overrideWith((ref) {
        final n = EstopNotifier(null);
        // Test-only seed: 본체 /status가 키오스크가 시작한 실행을 알린 상태.
        // ignore: invalid_use_of_protected_member
        n.state = const EstopState(hubRunning: true, hubJobId: 'kiosk-1');
        return n;
      }),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: _shellRouter()),
    ));
    await tester.pump();
    expect(container.read(executionStatusProvider).phase, ExecutionPhase.idle, reason: '폰이 시작한 실행이 아니다');
    expect(find.byKey(const Key('shell-stop')), findsOneWidget);
    // 용어 통일(2026-10-25, 사용자 승인): "다른 곳에서 시작한 동작 진행 중 · [정지]".
    expect(find.text('다른 곳에서 시작한 동작 진행 중'), findsOneWidget);
    await tester.tap(find.byKey(const Key('shell-stop')));
    await tester.pump();
    await tester.pump();
    expect(stops, ['/stop']);
  });

  testWidgets('동작을 확인할 수 없는 상태에서도 정지 수단을 남긴다', (tester) async {
    await _pump(
      tester,
      status: const ExecutionStatus(phase: ExecutionPhase.unknown),
    );
    expect(find.text('지금 상태를 확인하지 못했어요'), findsOneWidget);
    expect(find.byKey(const Key('shell-stop')), findsOneWidget);
  });
}
