import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/care_events_provider.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_colors.dart';

/// 탭 인덱스 — 라우터 브랜치 순서와 같다.
const int _homeTab = 0;
const int _voiceTab = voiceTabIndex; // 1
const int _statusTab = 2;
const int _settingsTab = 3;

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
      bottomNavigationBar: _BottomBar(
        index: index,
        onTab: navigationShell.goBranch,
      ),
    );
  }
}

/// 하단 탭바 — 가운데에 **주 행동**을 띄운다.
///
/// 예전에는 "말로 조작하기"가 탭바 위에 따로 떠 있고 탭바에도 '음성' 탭이
/// 있었다. 같은 일을 하는 것이 화면에 두 번 나오면서, 정작 어느 쪽을 눌러야
/// 하는지가 흐려졌다. 하나로 합쳐 가운데에 크게 둔다 -- 이 앱에서 가장 하고
/// 싶은 일이 가장 크게 보여야 한다.
class _BottomBar extends ConsumerWidget {
  const _BottomBar({required this.index, required this.onTab});

  final int index;
  final void Function(int) onTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(careEventsProvider).unreadCount;
    // 글씨를 키우면 라벨이 커진다. 바 높이를 같이 늘려 잘리지 않게 한다 --
    // 200%에서 라벨이 잘리면 아이콘만 남아 무슨 탭인지 알 수 없다.
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
                selected: index == _homeTab,
                onTap: () => onTab(_homeTab),
              ),
              _Tab(
                icon: Icons.monitor_heart_outlined,
                selectedIcon: Icons.monitor_heart,
                label: '상태',
                selected: index == _statusTab,
                onTap: () => onTab(_statusTab),
              ),
              _VoiceAction(
                selected: index == _voiceTab,
                onTap: () => onTab(_voiceTab),
              ),
              _Tab(
                icon: Icons.notifications_none,
                selectedIcon: Icons.notifications,
                label: '알림',
                selected: false,
                badge: unread,
                // 알림함은 탭이 아니라 위에 얹는 화면이다 -- 돌아오면 원래
                // 보던 탭 그대로다.
                onTap: () => context.push('/care-events'),
              ),
              _Tab(
                icon: Icons.settings_outlined,
                selectedIcon: Icons.settings,
                label: '설정',
                selected: index == _settingsTab,
                onTap: () => onTab(_settingsTab),
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
        label: label,
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
                          style: TextStyle(
                            // 채도 있는 면 위 글자는 반대색으로 -- 흰 글자는
                            // 이 빨강 위에서 3:1로 무너진다.
                            color: AppColors.onAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              // 라벨이 길어져도 줄이지 않고 줄여 맞춘다 -- 잘라내면 어떤
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

/// 가운데 주 행동 — 말로 조작하기.
class _VoiceAction extends StatelessWidget {
  const _VoiceAction({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
        child: Center(
          child: Semantics(
            button: true,
            selected: selected,
            label: '말로 조작하기',
            child: Material(
              color: context.appPrimary,
              shape: const CircleBorder(),
              elevation: 4,
              shadowColor: context.appPrimary.withValues(alpha: 0.45),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTap,
                child: SizedBox(
                  width: 58,
                  height: 58,
                  child: Icon(
                    Icons.mic_rounded,
                    size: 28,
                    // 강조색을 면으로 쓸 때의 반대색. 다크는 검정, 라이트는
                    // 흰색이다 -- 한쪽으로 고정하면 반대 모드에서 무너진다.
                    color: context.appOnAccent,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}
