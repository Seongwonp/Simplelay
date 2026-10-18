import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/execution_status.dart';
import '../providers/care_events_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../widgets/estop_banner.dart';
import '../widgets/voice_stop_indicator.dart';
import 'history_screen.dart' show historyProvider;
import 'home_screen.dart' show careNeedsLook;
import '../theme/app_tokens.dart';

/// 하단 탭 shell — **홈 · 루틴 · 기록 · 설정**(UI 확정 §2).
///
/// 탭은 늘 네 개다(UI 개편안 §4, 2026-10-18). 개발자 도구는 탭이 아니라 설정
/// 맨 아래 항목이고, 서버 `/status.developer_mode`가 참일 때만 보인다 -- 시연 날
/// 제품 화면에 데모 흔적이 남지 않게 한다.
///
/// 예전 탭바 가운데의 '말로 조작하기'와 '상태' 탭은 없앴다. 대신
/// **실행 중에는 어느 탭에서든 탭바 바로 위에 정지 줄이 뜬다** -- 상태
/// 탭이 사라져도 멈출 수단이 한 번의 터치 안에 있어야 한다.
///
/// 콘센트 모듈 비상정지가 걸려 있으면(2026-10-05) 정지 줄 위에 걸림 배너가
/// 함께 뜬다 — 해제는 사람이 확인 대화를 거쳐서만 한다.
class AppShell extends ConsumerWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = navigationShell.currentIndex;

    // 지금 보이는 탭을 알린다 — 브랜치는 화면을 떠나도 살아 있어서, 마이크처럼
    // 가려지면 멈춰야 하는 자원을 쥔 화면이 스스로 정리할 수 있어야 한다.
    // build 중에는 provider를 바꿀 수 없으므로 프레임 뒤로 미룬다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!ref.context.mounted) return;
      if (ref.read(currentTabIndexProvider) != index) {
        ref.read(currentTabIndexProvider.notifier).state = index;
      }
    });

    // 기록 탭은 IndexedStack에 남아 처음 받은 목록을 계속 쓴다(2026-10-13
    // 에뮬레이터: 실행이 끝났는데 "아직 실행 기록이 없어요"). 실행이 끝나면
    // 다시 받는다. 다시 받는 동안은 이전 목록이 그대로 보인다.
    ref.listen<ExecutionPhase>(
      executionStatusProvider.select((s) => s.phase),
      (prev, next) {
        if (prev != next && _runEnded(next)) ref.invalidate(historyProvider);
      },
    );

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 비상정지 걸림은 정지 줄 **위**에 — 걸린 채로도 정지 줄은 그대로 닿는다.
          const EstopBanner(),
          // 실행 중 음성 '멈춰'를 듣는 동안만 보인다(2026-10-07).
          const VoiceStopIndicator(),
          const RunningStopStrip(),
          _BottomBar(
            index: index,
            onTab: (i) {
              // 다른 기기(키오스크 등)의 실행도 보이게, 기록 탭에 들어갈 때마다 다시 받는다.
              if (i == historyTabIndex) ref.invalidate(historyProvider);
              navigationShell.goBranch(i);
            },
          ),
        ],
      ),
    );
  }
}

bool _runEnded(ExecutionPhase p) =>
    p == ExecutionPhase.completed ||
    p == ExecutionPhase.failed ||
    p == ExecutionPhase.unconfirmed;

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
        ? '지금 상태를 몰라요'
        : (label == null || label.isEmpty ? '하는 중이에요' : '$label 하는 중');
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.md, AppSpace.sm),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  button: true,
                  label: '실행 상태 보기',
                  child: InkWell(
                    onTap: () => context.push('/status'),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
                      child: Row(
                        children: [
                          Icon(
                            unknown ? Icons.help_outline : AppIcons.running,
                            size: 20,
                            color: unknown ? context.appWarning : context.appPrimary,
                          ),
                          const SizedBox(width: AppSpace.sm),
                          Expanded(
                            child: Text(
                              line,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: AppFont.caption, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
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
    required this.onTab,
  });

  final int index;
  final void Function(int) onTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 보호자 알림함은 설정 안으로 옮겼다. 읽지 않은 알림 수는 설정 탭에
    // 배지로 남긴다 -- 실패·긴급 정지 알림이 눈에 띄지 않으면 안 된다.
    // 2026-10-13: 숫자 대신 점 하나였다("13"은 무엇이 13개인지 말하지 않는다). 접근성 감사(10/18): 점은 색으로만 말해
    // 무엇이 있는지·얼마나 있는지 몰랐다 — 안 본 알림 수를 숫자 배지로(99건 넘으면 99+). 무엇의 수인지는 접근성 이름이 말한다.
    // 조회 실패는 0건과 다르게 읽힌다.
    final care = ref.watch(careEventsProvider);
    final unread = care.unreadCount;
    final settingsLabel = unread > 0
        ? '설정, 안 본 알림 $unread건'
        : care.status == CareInboxStatus.failed
            ? '설정, 알림을 불러오지 못했어요'
            : '설정';
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
                icon: AppIcons.routine,
                selectedIcon: AppIcons.routineSelected,
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
                badgeCount: unread,
                // 볼 것(실패·정지 등)이 섞였을 때만 빨간 배지, 자동으로 한 일·루틴 안내뿐이면 중립 배지(평가 13차 10/18).
                dotAlert: careNeedsLook(care.unreadEvents),
                semanticsLabel: settingsLabel,
                onTap: () => onTab(settingsTabIndex),
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
    this.badgeCount = 0,
    this.dotAlert = true,
    this.semanticsLabel,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 안 본 알림 수 — 0이면 배지가 없다. 무엇의 수인지는 [semanticsLabel]이 말한다.
  final int badgeCount;

  /// 배지를 경고(빨강)로 칠하는가.
  final bool dotAlert;

  /// 읽을 이름. 없으면 [label].
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.appPrimary : context.appMuted;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: semanticsLabel ?? label,
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
                  if (badgeCount > 0)
                    Positioned(
                      right: -12,
                      top: -8,
                      child: Container(
                        key: const Key('settings-unread-badge'),
                        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: dotAlert ? AppColors.danger : context.appPrimary,
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Text(badgeCount > 99 ? '99+' : '$badgeCount',
                            textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
                            style: const TextStyle(
                                fontSize: AppFont.caption, height: 1.2, fontWeight: FontWeight.w800, color: Colors.white)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              // 라벨이 길어져도 자르지 않고 줄여 맞춘다 -- 잘라내면 어떤
              // 탭인지 알 수 없게 된다.
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: AppFont.caption,
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
