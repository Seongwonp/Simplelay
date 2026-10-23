part of '../home_screen.dart';

/// 첫 저장 동작을 강조하되 사용 빈도나 추천 근거를 만들어내지 않는다.
class _FeaturedAction extends StatelessWidget {
  const _FeaturedAction(
      {required this.routine,
      required this.subtitle,
      required this.running,
      required this.busy,
      required this.onTap,
      required this.iconOf});
  final Routine routine;
  final String subtitle;
  final bool running;
  final bool busy;
  final VoidCallback onTap;
  final Map<String, IconData> iconOf;

  @override
  Widget build(BuildContext context) => Card(
        key: const Key('home-routine-hero'),
        margin: const EdgeInsets.only(bottom: AppSpace.md),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _FeaturedActionIdentity(
                routine: routine, subtitle: subtitle, iconOf: iconOf),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              key: Key('home-routine-tile-${routine.id}'),
              onPressed: busy ? null : onTap,
              child: running
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text('실행하기', semanticsLabel: '${routine.name} 실행하기'),
            ),
          ]),
        ),
      );
}

class _FeaturedActionIdentity extends ConsumerWidget {
  const _FeaturedActionIdentity(
      {required this.routine, required this.subtitle, required this.iconOf});
  final Routine routine;
  final String subtitle;
  final Map<String, IconData> iconOf;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appliances = ref.watch(installedAppliancesProvider);
    final targets = [
      for (final a in appliances)
        if (routine.applianceIds.contains(a.id)) a
    ];
    final picture = Container(
      padding: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
          color: context.appOverlayFaint,
          borderRadius: BorderRadius.circular(16)),
      child: targets.length == 1 && routine.mode != RoutineMode.notify
          ? ApplianceArtwork(category: targets.single.category, size: 56)
          : RoutineIcon(
              routine: routine,
              iconOf: iconOf,
              color: context.appInk,
              size: 48),
    );
    final text =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(keepWordsTogether(routine.name), style: AppText.heading),
      const SizedBox(height: AppSpace.xs),
      Text(
          keepPhrasesTogether(subtitle,
              wholeParts: MediaQuery.textScalerOf(context).scale(1) <= 1.3),
          style: context.appCaption),
    ]);
    if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [picture, const SizedBox(height: AppSpace.md), text]);
    }
    return Row(children: [
      picture,
      const SizedBox(width: AppSpace.md),
      Expanded(child: text)
    ]);
  }
}
