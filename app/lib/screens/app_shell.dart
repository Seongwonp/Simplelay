import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/execution_status.dart';
import '../providers/execution_status_provider.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../widgets/estop_banner.dart';
import '../widgets/voice_stop_indicator.dart';
import 'history_screen.dart' show historyProvider;
import '../theme/app_tokens.dart';

/// 과업 탭 shell — **홈 · 가전 · 자동 실행 · 기록**(10/23 승인안).
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
        ? '지금 상태를 확인하지 못했어요'
        : (label == null || label.isEmpty ? '하고 있어요' : '$label 하고 있어요');
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

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onTab});
  final int index;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: SafeArea(top: false, child: Row(
      key: const Key('task-navigation'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, label, icon) in const [
          (homeTabIndex, '홈', Icons.home_outlined),
          (appliancesTabIndex, '가전', Icons.devices_outlined),
          (automationTabIndex, '자동 실행', Icons.bolt_outlined),
          (historyTabIndex, '기록', Icons.history),
        ])
          Expanded(child: Semantics(
            button: true, selected: index == i, label: label, excludeSemantics: true,
            child: InkWell(onTap: () => onTab(i), child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.md, horizontal: AppSpace.xs),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, color: index == i ? context.appPrimary : context.appMuted),
                const SizedBox(height: AppSpace.xs),
                Text(label, textAlign: TextAlign.center, style: TextStyle(
                  fontSize: AppFont.caption, height: 1.2,
                  fontWeight: index == i ? FontWeight.w700 : FontWeight.w500,
                  color: index == i ? context.appPrimary : context.appMuted,
                )),
              ]),
            )),
          )),
      ],
    )),
  );
}
