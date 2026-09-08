import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/navigation_provider.dart';

class AppShell extends ConsumerWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = navigationShell.currentIndex;

    // 지금 보이는 탭을 알린다 — 브랜치는 화면을 떠나도 살아 있어서, 마이크처럼
    // 가려지면 멈춰야 하는 자원을 쥔 화면이 스스로 정리할 수 있어야 한다.
    // 탭바 탭 이벤트가 아니라 shell의 현재 인덱스를 보는 이유: context.go로도
    // 탭이 바뀌기 때문(실행 시작 시 상태 탭 이동 등).
    // build 중에는 provider를 바꿀 수 없으므로 프레임 뒤로 미룬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ref.context.mounted) return;
      if (ref.read(currentTabIndexProvider) != index) {
        ref.read(currentTabIndexProvider.notifier).state = index;
      }
    });

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: navigationShell.goBranch,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.mic_none),
            selectedIcon: Icon(Icons.mic),
            label: '음성',
          ),
          NavigationDestination(
            icon: Icon(Icons.monitor_heart_outlined),
            selectedIcon: Icon(Icons.monitor_heart),
            label: '상태',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '설정',
          ),
        ],
      ),
    );
  }
}
