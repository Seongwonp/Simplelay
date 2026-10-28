import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/execution_status.dart';
import '../providers/estop_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/voice_stop_provider.dart' show voiceStopNotice, voiceStopNoticeProvider;
import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../widgets/estop_banner.dart';
import '../widgets/voice_stop_indicator.dart';
import 'history_screen.dart' show historyProvider;
import '../theme/app_tokens.dart';

/// 홈·가전·자동 실행·기록 탭을 제공하는 앱 셸.
///
/// 개발자 도구는 `/status.developer_mode`가 참일 때만 설정에 표시한다.
/// 실행 중에는 모든 탭에서 정지 줄을 유지한다. 비상정지는 별도 배너로 표시하며,
/// 해제에는 사용자 확인이 필요하다.
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
              // 지금 탭을 다시 누르면 그 탭의 첫 화면으로(10/26 실기기: '말로 하기'는 홈 탭 위에 얹혀 있어 홈을 눌러도
              // 그대로 머물렀다). 화면을 떠나면 음성 화면이 듣기·생각 중 요청을 스스로 정리한다.
              navigationShell.goBranch(i,
                  initialLocation: i == navigationShell.currentIndex);
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
    // 폰이 시작하지 않은 실행(키오스크·자동 실행·루틴) — 본체 /status가 실행 중이라 하면 같은 정지 줄을 띄운다(첫 사용
    // 평가 10/24: 폰은 자기가 시작한 실행에만 정지 줄을 띄워, 다른 곳에서 시작한 실행을 멈출 길이 보이지 않았다).
    // 방금 끝난 폰의 실행을 지난 조회가 아직 실행 중이라 하는 것은 거른다(HTTP 실행은 sequenceId가 job_id와 같다).
    final hub = ref.watch(estopProvider.select((s) => (running: s.hubRunning, jobId: s.hubJobId)));
    final external = !active && !unknown && hub.running && (hub.jobId == null || hub.jobId != status.sequenceId);
    if (!active && !unknown && !external) return const SizedBox.shrink();

    final label = status.label;
    final line = unknown
        ? '지금 상태를 확인하지 못했어요'
        : external
            ? '다른 곳에서 시작한 동작 진행 중'
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
                  // 폰이 추적하지 않는 실행은 상태 화면이 그 실행을 모른다 — 줄만 보이고 정지만 둔다.
                  button: !external,
                  label: external ? null : '실행 상태 보기',
                  child: InkWell(
                    onTap: external ? null : () => context.push('/status'),
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
                onPressed: () => external
                    ? stopUntrackedRun(ref)
                    : ref.read(executionStatusProvider.notifier).emergencyStop(),
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

/// 폰이 추적하지 않는 실행을 멈춘다 — 음성 '멈춰'의 같은 경로(POST /stop, 대기면 본체가 정지 버튼 누름으로 넘긴다).
/// 결과 한 줄은 서버가 알린 정지 단계까지만([voiceStopNotice]) 정지 줄 위 알림 자리([voiceStopNoticeProvider])에 둔다.
/// 보내지 못했거나 답이 없으면 그렇게 말하고, 정지는 다시 눌러도 안전하다.
Future<void> stopUntrackedRun(WidgetRef ref) async {
  final api = ref.read(rpiApiServiceProvider);
  final notice = ref.read(voiceStopNoticeProvider.notifier);
  if (api == null) {
    notice.state = '멈추라고 보내지 못했어요. 본체 연결을 보고 정지를 다시 눌러 주세요.';
    return;
  }
  try {
    final outcome = await api.stop();
    notice.state = voiceStopNotice(outcome);
  } on TimeoutException {
    notice.state = '멈추라고 보냈는데 답이 없어요. 멈추지 않으면 정지를 다시 눌러 주세요.';
  } catch (_) {
    notice.state = '멈추라고 보내지 못했어요. 정지를 다시 눌러 주세요.';
  }
  // 본체 상태를 다시 읽어 정지 줄을 거둘지 정한다(주기 조회를 기다리지 않는다).
  unawaited(ref.read(estopProvider.notifier).refresh());
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
