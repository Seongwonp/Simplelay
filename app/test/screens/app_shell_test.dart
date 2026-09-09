// 하단 탭 shell이 "지금 보이는 탭"을 알리는지 확인한다.
//
// 탭은 StatefulShellBranch라 화면을 떠나도 위젯이 살아 있다. 음성 화면처럼
// 가려지면 마이크를 놓아야 하는 화면은 이 신호에 기대므로, 여기가 끊기면
// "숨겨진 화면이 계속 듣는" 버그가 조용히 되살아난다.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
              GoRoute(path: '/', builder: (_, __) => const Text('home')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/voice', builder: (_, __) => const Text('voice')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(path: '/status', builder: (_, __) => const Text('status')),
            ]),
            StatefulShellBranch(routes: [
              GoRoute(
                  path: '/settings', builder: (_, __) => const Text('settings')),
            ]),
          ],
        ),
      ],
    );

void main() {
  testWidgets('탭을 옮기면 currentTabIndexProvider가 따라간다', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: _shellRouter()),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentTabIndexProvider), 0);

    // 음성은 라벨이 붙은 탭이 아니라 **가운데 떠 있는 주 행동**이다.
    await tester.tap(find.bySemanticsLabel('말로 조작하기'));
    await tester.pumpAndSettle();
    expect(container.read(currentTabIndexProvider), voiceTabIndex);

    // 음성 탭을 떠나는 것까지 확인 — 이 전이가 마이크 정리를 촉발한다.
    await tester.tap(find.text('홈'));
    await tester.pumpAndSettle();
    expect(container.read(currentTabIndexProvider), 0);
  });
}
