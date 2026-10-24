part of '../home_screen.dart';

/// 첫 저장 동작 카드 아래 정지 위치 한 줄(첫 사용 평가 4차 10/24).
const kHomeStopHint = '실행 중에는 화면 아래에 정지가 나와요';

/// 첫 저장 동작을 강조하되 사용 빈도나 추천 근거를 만들어내지 않는다.
///
/// 본체가 대상 가전을 지금은 실행할 수 없다고 하면(홈 타일 '!'·'지금 하기' 확인 시트와 같은 판정 [routineRunPlan]) 제목 아래
/// '지금은 쓸 수 없어요'를 적고 '실행하기'를 채운 주 버튼이 아닌 흐린 테두리로 그린다(첫 사용 평가 2차 10/24, 키오스크 카드와
/// 같게). 눌러도 바로 하지 않는다 — 확인 시트가 막힌 이유를 말하고 카드를 만들지 않는다.
class _FeaturedAction extends ConsumerWidget {
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
  final Map<String, ApplianceCategory> iconOf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = routineRunPlan(routine, ref.watch(installedAppliancesProvider),
                readinessOf: ref.watch(serverApplianceCatalogProvider).readinessFor)
            .blocked !=
        null;
    final label = running
        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : Text('실행하기',
            semanticsLabel: blocked ? '${routine.name} 실행하기, 지금은 쓸 수 없어요' : '${routine.name} 실행하기');
    return Card(
      key: const Key('home-routine-hero'),
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _FeaturedActionIdentity(routine: routine, subtitle: subtitle, iconOf: iconOf, blocked: blocked),
          const SizedBox(height: AppSpace.lg),
          if (blocked)
            OutlinedButton(
              key: Key('home-routine-tile-${routine.id}'),
              onPressed: busy ? null : onTap,
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: context.appMuted,
                  side: BorderSide(color: context.appBorderFaint)),
              child: label,
            )
          else
            FilledButton(
              key: Key('home-routine-tile-${routine.id}'),
              onPressed: busy ? null : onTap,
              child: label,
            ),
          // 정지가 어디 나오는지 실행 전에 한 줄(첫 사용 평가 4차 10/24). 홈 맨 위에 따로 두지 않고 시작하는 자리에만,
          // 쓸 수 있고 아무것도 돌지 않을 때만 — 실행 중에는 정지 줄이 직접 보인다.
          if (!blocked && !running && !busy)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Text(keepWordsTogether(kHomeStopHint),
                  key: const Key('home-stop-hint'),
                  semanticsLabel: kHomeStopHint,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
            ),
        ]),
      ),
    );
  }
}

class _FeaturedActionIdentity extends ConsumerWidget {
  const _FeaturedActionIdentity(
      {required this.routine, required this.subtitle, required this.iconOf, this.blocked = false});
  final Routine routine;
  final String subtitle;
  final Map<String, ApplianceCategory> iconOf;
  final bool blocked;
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
      if (blocked)
        Text('지금은 쓸 수 없어요',
            style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appWarning)),
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
