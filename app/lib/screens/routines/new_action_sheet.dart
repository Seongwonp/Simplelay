part of '../routines_screen.dart';

class _NewChoice {
  const _NewChoice(this.template);
  final Routine? template;
}

/// [+ 새 루틴] 시트 — 빈 루틴으로 시작하기, 또는 예시 루틴(미리 만든 틀)을 골라 고쳐 쓰기.
class _NewRoutineSheet extends ConsumerWidget {
  const _NewRoutineSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(routineTemplatesProvider);
    final installed = ref.watch(installedAppliancesProvider);
    final names = {for (final a in installed) a.id: a.name};
    final icons = {for (final a in installed) a.id: a.category};
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xxl),
        children: [
          Text('새 루틴', style: AppText.title),
          const SizedBox(height: AppSpace.md),
          OutlinedButton.icon(
            key: const Key('routine-new-blank'),
            onPressed: () => Navigator.pop(context, const _NewChoice(null)),
            icon: const Icon(Icons.add),
            label: const Text('빈 루틴으로 시작하기'),
          ),
          const SizedBox(height: AppSpace.xxl),
          Text('예시 루틴', style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
          Text('골라서 내 가전에 맞게 고치면 내 루틴이 돼요.', style: context.appCaption),
          const SizedBox(height: AppSpace.sm),
          ...templates.when(
            loading: () => const [
              Padding(
                padding: EdgeInsets.all(AppSpace.lg),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
            error: (_, __) => const [_Note('예시 루틴을 불러오지 못했어요.')],
            data: (list) => list.isEmpty
                ? const [_Note('지금 보여 드릴 예시 루틴이 없어요.')]
                : [
                    for (final t in list)
                      _RoutineRow(
                        routine: t,
                        applianceNames: names,
                        applianceIcons: icons,
                        onEdit: () => Navigator.pop(context, _NewChoice(t)),
                        onRun: null,
                        running: false,
                        busy: false,
                        error: null,
                      ),
                  ],
          ),
        ],
      ),
    );
  }
}

/// 위 탭 글 — 한 줄로, 칸보다 길면 그만큼만 줄인다(평가 8차 10/18: 200%에서 '자동으로 / 하기'가 잘렸다).
/// 고른 탭은 색 말고도 굵은 글자 + 밑줄(접근성 감사 10/18 — 색만으로는 어느 탭인지 갈리지 않았다).
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel(this.text, {this.selected = false});
  final String text;
  final bool selected;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(text,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
              decoration: selected ? TextDecoration.underline : TextDecoration.none,
              decorationThickness: 2,
            )),
      );
}
