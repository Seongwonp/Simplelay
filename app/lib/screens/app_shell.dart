import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/execution_status.dart';
import '../providers/care_events_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/hub_provider.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_colors.dart';

/// 하단 탭 shell — **홈 · 루틴 · 기록 · 설정**(UI 확정 §2).
///
/// 서버 `/status.developer_mode`가 참일 때만 다섯 번째 탭 '개발자'가 설정
/// 옆에 생긴다. 꺼져 있으면 탭 자체가 없다 -- 시연 날 제품 화면에 데모
/// 흔적이 남지 않게 한다.
///
/// 예전 탭바 가운데의 '말로 조작하기'와 '상태' 탭은 없앴다. 대신
/// **실행 중에는 어느 탭에서든 탭바 바로 위에 정지 줄이 뜬다** -- 상태
/// 탭이 사라져도 멈출 수단이 한 번의 터치 안에 있어야 한다.
class AppShell extends ConsumerWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = navigationShell.currentIndex;
    final showDev = ref.watch(showDeveloperTabProvider);

    // 지금 보이는 탭을 알린다 — 브랜치는 화면을 떠나도 살아 있어서, 마이크처럼
    // 가려지면 멈춰야 하는 자원을 쥔 화면이 스스로 정리할 수 있어야 한다.
    // build 중에는 provider를 바꿀 수 없으므로 프레임 뒤로 미룬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ref.context.mounted) return;
      if (ref.read(currentTabIndexProvider) != index) {
        ref.read(currentTabIndexProvider.notifier).state = index;
      }
      // 개발자 탭에 있는데 개발자 모드가 꺼지면 홈으로 돌린다. 탭은
      // 사라졌는데 화면만 남아 있으면 돌아갈 길이 없다.
      if (index == developerTabIndex && !showDev) {
        navigationShell.goBranch(homeTabIndex);
      }
    });

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const RunningStopStrip(),
          _BottomBar(
            index: index,
            showDeveloper: showDev,
            onTab: navigationShell.goBranch,
          ),
        ],
      ),
    );
  }
}

/// 실행 중일 때 탭바 위에 붙는 한 줄 — 무엇이 도는지와 **정지**.
///
/// 정지는 실행 상태 화면의 긴급 정지와 같은 경로(`emergencyStop`)다.
/// 확인할 수 없는 상태(unknown)에서도 남긴다: 통신이 끊긴 것이지 가전이
/// 멈춘 게 아니다.
class RunningStopStrip extends ConsumerWidget {
  const RunningStopStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(executionStatusProvider);
    final active = status.phase == ExecutionPhase.running ||
        status.phase == ExecutionPhase.retrying ||
        status.phase == ExecutionPhase.waiting;
    final unknown = status.phase == ExecutionPhase.unknown;
    if (!active && !unknown) return const SizedBox.shrink();

    final label = status.label;
    final line = unknown
        ? '동작을 확인할 수 없어요'
        : (label == null || label.isEmpty ? '실행 중이에요' : '$label 실행 중');
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: '실행 상태 보기',
                  child: InkWell(
                    onTap: () => context.push('/status'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          Icon(
                            unknown ? Icons.help_outline : Icons.autorenew,
                            size: 20,
                            color: unknown ? context.appWarning : context.appPrimary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              line,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('shell-stop'),
                onPressed: () =>
                    ref.read(executionStatusProvider.notifier).emergencyStop(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.stop,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(88, 48),
                ),
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
                label: const Text('정지'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends ConsumerWidget {
  const _BottomBar({
    required this.index,
    required this.showDeveloper,
    required this.onTab,
  });

  final int index;
  final bool showDeveloper;
  final void Function(int) onTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 보호자 알림함은 설정 안으로 옮겼다. 읽지 않은 알림 수는 설정 탭에
    // 배지로 남긴다 -- 실패·긴급 정지 알림이 눈에 띄지 않으면 안 된다.
    final unread = ref.watch(careEventsProvider).unreadCount;
    // 글씨를 키우면 라벨이 커진다. 바 높이를 같이 늘려 잘리지 않게 한다.
    final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    final barHeight = 62.0 + (scale - 1) * 26;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: context.appBorderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: barHeight,
          child: Row(
            children: [
              _Tab(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home,
                label: '홈',
                selected: index == homeTabIndex,
                onTap: () => onTab(homeTabIndex),
              ),
              _Tab(
                icon: Icons.auto_awesome_motion_outlined,
                selectedIcon: Icons.auto_awesome_motion,
                label: '루틴',
                selected: index == routinesTabIndex,
                onTap: () => onTab(routinesTabIndex),
              ),
              _Tab(
                icon: Icons.history,
                selectedIcon: Icons.history,
                label: '기록',
                selected: index == historyTabIndex,
                onTap: () => onTab(historyTabIndex),
              ),
              _Tab(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
                label: '설정',
                selected: index == settingsTabIndex,
                badge: unread,
                onTap: () => onTab(settingsTabIndex),
              ),
              if (showDeveloper)
                _Tab(
                  icon: Icons.build_outlined,
                  selectedIcon: Icons.build,
                  label: '개발자',
                  selected: index == developerTabIndex,
                  onTap: () => onTab(developerTabIndex),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.appPrimary : context.appMuted;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: badge > 0 ? '$label, 읽지 않은 알림 $badge건' : label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(selected ? selectedIcon : icon, size: 25, color: color),
                  if (badge > 0)
                    Positioned(
                      right: -8,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.danger,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: const TextStyle(
                            // 채도 있는 면 위 글자는 반대색으로 -- 흰 글자는
                            // 이 빨강 위에서 3:1로 무너진다.
                            color: AppColors.onAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              // 라벨이 길어져도 자르지 않고 줄여 맞춘다 -- 잘라내면 어떤
              // 탭인지 알 수 없게 된다.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
