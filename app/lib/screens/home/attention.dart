part of '../home_screen.dart';

class _FailureAlert extends ConsumerWidget {
  const _FailureAlert({required this.execution});

  final ExecutionStatus execution;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCare = ref.watch(careEventsProvider.select((s) => s.unreadEvents));
    final look = careAttentionLines(unreadCare).look;
    final failed = look != null && careLookIsFailure(unreadCare);
    final (String text, Color color, IconData icon, String actionLabel, VoidCallback onAction)? alert =
        switch (execution.phase) {
      ExecutionPhase.failed => ('지난 일을 못 했어요', context.appDanger, Icons.cancel_outlined, '결과 보기',
          () => context.push('/status')),
      ExecutionPhase.unconfirmed => ('지난 일이 됐는지 확인하지 못했어요', context.appWarning, Icons.help_outline, '결과 보기',
          () => context.push('/status')),
      _ => look == null
          ? null
          : (
              look,
              failed ? context.appDanger : context.appWarning,
              failed ? Icons.cancel_outlined : Icons.error_outline,
              failed ? '기록 보기' : '알림 보기',
              failed
                  ? () {
                      // 못 한 일만 거른 기록으로(보호자 과업 평가 10/18 — 어제 실패를 찾기 쉽게).
                      ref.read(historyFailedOnlyProvider.notifier).state = true;
                      // 보러 간다 = 봤다(사용자 보고 10/19: 기록을 보고 와도 경고가 남았다) — 본체에 적어 이 경고·설정 탭
                      // 배지·키오스크 표시가 함께 사라진다. 이 경고에 보인 못 한 일까지만, 실행은 기록 화면에 보인 것만
                      // (검토 10/19). 새 실패는 다시 뜬다.
                      ref.read(historyAckPendingProvider.notifier).state = true;
                      unawaited(ref.read(careEventsProvider.notifier).markFailuresSeen(unreadCare));
                      context.go('/history');
                    }
                  : () => context.push('/care'),
            ),
    };
    if (alert == null) return const SizedBox.shrink();
    final (text, color, icon, actionLabel, onAction) = alert;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Container(
        key: const Key('home-failure'),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border(left: BorderSide(color: color, width: 4)),
        ),
        padding: const EdgeInsets.only(left: AppSpace.md, right: AppSpace.xs),
        // 한 줄 — 무엇을 못 했는지 + 오른쪽 할 일 단추(첫 화면에 가전 두 줄이 남게, 평가 6차 10/18).
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Icon(icon, size: AppSpace.xl, color: color),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            // '알림 / 4건'처럼 숫자가 앞 낱말과 갈리지 않게. 말줄임 없이.
            child: Text(keepPhrasesTogether(text),
                semanticsLabel: text,
                style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: color)),
          ),
          TextButton(
            key: const Key('home-failure-action'),
            onPressed: onAction,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
              foregroundColor: color,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(keepWordsTogether(actionLabel),
                  semanticsLabel: actionLabel,
                  style: const TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700)),
              const Icon(Icons.chevron_right, size: AppSpace.xl),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 안 본 알림 가운데 가장 무거운 볼 것이 '못 한 일'(실행 실패)인가 — 실패 경고의 색·할 일 단추가 갈린다.

/// '해야 할 일'(설정이 남은 가전)과 안 본 알림 한 줄 — 실패 경고 아래, 가전 위.
///
/// 설정 남음은 사람이 할 일이라 제목 '해야 할 일' 아래 그 가전 카드(둘 이상은 한 줄). 안 본 알림은 **설정과 같은 수 하나**
/// ('안 본 알림 7건' — 위 실패 경고로 보인 것도 센다)를 중립색 한 줄로.
class _TodoAndUnread extends ConsumerWidget {
  const _TodoAndUnread({required this.setupCandidates});

  final List<ApplianceMap> setupCandidates;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = pendingSetupAppliances(ref, setupCandidates);
    final unreadCare = ref.watch(careEventsProvider.select((s) => s.unreadEvents));
    final rest = careAttentionLines(unreadCare).rest;
    if (pending.isEmpty && rest == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: pending.isEmpty ? AppSpace.sm : AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pending.isNotEmpty)
            Container(
              key: const Key('home-todo'),
              // 평가 16차(10/18): 면 없이 왼쪽 굵은 색 선과 글자만(가전 카드와 다른 문법).
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: context.appWarning, width: 4)),
              ),
              padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.sm, AppSpace.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.checklist_rounded,
                        key: const Key('home-attention-icon'), size: AppSpace.xl, color: context.appWarning),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text('해야 할 일',
                            style: TextStyle(
                                fontSize: AppFont.body, fontWeight: FontWeight.w700, color: context.appWarning)),
                      ),
                    ),
                  ]),
                  // 한 대면 그 가전의 설정 카드를 그대로(연습 자리 확인이면 '실제 자리는 확인하지 못했어요'까지), 둘 이상은 한 줄.
                  if (pending.length == 1)
                    ApplianceSetupCard(appliance: pending.single, flat: true)
                  else
                    SetupSummaryRow(appliances: pending),
                ],
              ),
            ),
          if (rest != null)
            Padding(
              padding: EdgeInsets.only(top: pending.isNotEmpty ? AppSpace.sm : 0),
              child: _AttentionRow(
                key: const Key('home-unread'),
                // 알림 줄이라 알림 아이콘, 중립색 — 볼 것은 위 실패 경고가 말한다.
                icon: Icons.notifications_none,
                text: rest,
                color: Theme.of(context).colorScheme.onSurface,
                onTap: () => context.push('/care'),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    super.key,
    required this.icon,
    required this.text,
    required this.color,
    required this.onTap,
  });
  final IconData? icon;
  final String text;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        button: true,
        label: text,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Row(children: [
              // 아이콘이 없는 줄도 글자는 같은 세로줄(아이콘 칸 20 + 사이 8).
              if (icon case final i?) Icon(i, size: 20, color: color) else const SizedBox(width: AppSpace.xl),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                // '알림 / 4건'처럼 숫자가 앞 낱말과 갈리지 않게(평가 13차 10/18).
                child: Text(keepPhrasesTogether(text),
                    style: TextStyle(fontSize: AppFont.caption, color: color)),
              ),
              Icon(Icons.chevron_right, color: context.appMuted),
            ]),
          ),
        ),
      );
}

// 내 루틴 타일

/// 홈의 루틴 자리(2026-10-18) — **직접 실행하는** 적격 루틴을 2열 타일로 넷까지.
///
/// 시각 루틴은 정해진 때 저절로 돌고 '지금 우리 집'의 다음 예정이 이미 말한다 — 타일로 겹치지 않는다.
/// 자동 순위·즐겨찾기가 아니라 서버가 준 목록 순서다('자주'·'추천' 같은 이유를 붙이지 않는다).
/// 타일을 누르면 승인 카드만 만든다(루틴 탭과 같은 경로) — 가전은 승인 화면에서 허락해야 움직인다.
