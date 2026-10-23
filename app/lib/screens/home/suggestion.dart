part of '../home_screen.dart';

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    super.key,
    required this.suggestion,
    required this.appliance,
    required this.onRun,
    required this.onLater,
  });

  final Suggestion suggestion;
  final ApplianceMap? appliance;
  final VoidCallback onRun;
  final VoidCallback onLater;

  @override
  Widget build(BuildContext context) {
    final a = appliance;
    final why = suggestion.whyNow;
    return Container(
      key: const Key('home-suggestion'),
      padding: const EdgeInsets.all(AppSpace.xl),
      decoration: BoxDecoration(
        color: context.appPrimary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: context.appPrimary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(a?.icon ?? Icons.lightbulb_outline,
                  size: 20, color: context.appPrimary),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  a == null ? '지금 할 일' : '지금 할 일 · ${a.displayName}',
                  style: context.appCaption,
                ),
              ),
              if (suggestion.isDemo) const DemoBadge(),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            suggestion.title,
            style: const TextStyle(fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700),
          ),
          if (why.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Text(why, style: context.appCaption),
          ],
          const SizedBox(height: AppSpace.lg),
          // 화면 글자는 짧게, 읽는 이름에는 대상을(2026-10-14, 발견 5).
          Semantics(
            label: '${suggestion.title} 지금 하기',
            container: true,
            button: true,
            excludeSemantics: true,
            child: FilledButton(
              onPressed: onRun,
              child: const Text('지금 하기'),
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Center(
            child: Semantics(
              label: '${suggestion.title} 다음에',
              container: true,
              button: true,
              excludeSemantics: true,
              child: TextButton(
                onPressed: onLater,
                child: Text('이번엔 안 할게요', style: TextStyle(color: context.appMuted)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 가전 카드 2열 ─────────────────────────────────────────────────────────
