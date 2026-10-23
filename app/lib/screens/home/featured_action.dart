part of '../home_screen.dart';

/// 첫 저장 동작을 강조하되 사용 빈도나 추천 근거를 만들어내지 않는다.
class _FeaturedAction extends StatelessWidget {
  const _FeaturedAction({required this.routine, required this.subtitle,
    required this.running, required this.busy, required this.onTap, required this.iconOf});
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        RoutineIcon(routine: routine, iconOf: iconOf, color: context.appPrimary),
        const SizedBox(height: AppSpace.md),
        Text(keepWordsTogether(routine.name), style: AppText.heading),
        const SizedBox(height: AppSpace.sm),
        Text(keepPhrasesTogether(subtitle), style: context.appCaption),
        const SizedBox(height: AppSpace.xl),
        FilledButton.icon(
          key: Key('home-routine-tile-${routine.id}'),
          onPressed: busy ? null : onTap,
          icon: running ? const SizedBox(width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow),
          label: Text('실행하기', semanticsLabel: '${routine.name} 실행하기'),
        ),
      ]),
    ),
  );
}
