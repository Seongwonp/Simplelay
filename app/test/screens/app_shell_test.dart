// 하단 탭 shell — 홈 · 루틴 · 기록 · 설정, 개발자 모드일 때만 다섯 번째 '개발자'
// (UI 확정 §2, 2026-09-30).
//
// 이 shell은 두 가지를 더 책임진다.
// 1. "지금 보이는 탭"을 알린다 -- 음성 화면처럼 가려지면 마이크를 놓아야 하는
//    화면은 이 신호에 기댄다.
// 2. '상태' 탭이 없어졌으므로, **실행 중에는 어느 탭에서든 정지 줄이 뜬다.**

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/demo_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
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
                  path: '/routines',
                  builder: (_, __) => const Text('routines-body')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/history',
                  builder: (_, __) => const Text('history-body')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/settings',
                  builder: (_, __) => const Text('settings-body')),
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

    for (final label in ['홈', '루틴', '기록', '설정']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('개발자'), findsNothing);
    // 예전 탭(상태·말로 조작·알림)은 없다.
    expect(find.text('상태'), findsNothing);
    expect(find.bySemanticsLabel('말로 하기'), findsNothing);
  });

  testWidgets('서버 개발자 모드면 설정 옆에 다섯 번째 탭 "개발자"가 생긴다',
      (tester) async {
    final container = await _pump(tester, developerMode: true);

    expect(find.text('개발자'), findsOneWidget);
    // 설정 오른쪽에 있다.
    expect(tester.getCenter(find.text('개발자')).dx,
        greaterThan(tester.getCenter(find.text('설정')).dx));

    await tester.tap(find.text('개발자'));
    await tester.pumpAndSettle();
    expect(find.text('dev-body'), findsOneWidget);
    expect(container.read(currentTabIndexProvider), developerTabIndex);
  });

  testWidgets('탭을 옮기면 currentTabIndexProvider가 따라간다', (tester) async {
    final container = await _pump(tester);
    expect(container.read(currentTabIndexProvider), homeTabIndex);

    await tester.tap(find.text('루틴'));
    await tester.pumpAndSettle();
    expect(find.text('routines-body'), findsOneWidget);
    expect(container.read(currentTabIndexProvider), routinesTabIndex);

    await tester.tap(find.text('기록'));
    await tester.pumpAndSettle();
    expect(container.read(currentTabIndexProvider), historyTabIndex);

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();
    expect(container.read(currentTabIndexProvider), settingsTabIndex);

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
    expect(find.text('아침 데우기 하는 중'), findsOneWidget);
    expect(find.byKey(const Key('shell-stop')), findsOneWidget);

    await tester.tap(find.text('루틴'));
    await tester.pump();
    expect(find.byKey(const Key('shell-stop')), findsOneWidget);
  });

  testWidgets('동작을 확인할 수 없는 상태에서도 정지 수단을 남긴다', (tester) async {
    await _pump(
      tester,
      status: const ExecutionStatus(phase: ExecutionPhase.unknown),
    );
    expect(find.text('지금 상태를 몰라요'), findsOneWidget);
    expect(find.byKey(const Key('shell-stop')), findsOneWidget);
  });
}
