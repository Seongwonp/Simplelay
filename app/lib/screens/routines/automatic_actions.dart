part of '../routines_screen.dart';

/// 시간 루틴과 사건 규칙의 저장 모델을 합치지 않고 같은 과업 화면에 표시한다.
extension _AutomaticActions on _RoutinesScreenState {
  Widget _automaticActions(BuildContext context) {
    final list = ref.watch(routinesProvider);
    final rules = ref.watch(automationRulesProvider);
    final next = ref.watch(nextRoutineProvider).valueOrNull;
    final installed = ref.watch(installedAppliancesProvider);
    final names = {for (final a in installed) a.id: a.name};
    final icons = {for (final a in installed) a.id: a.icon};
    final allRules = rules.valueOrNull ?? const <AutoRule>[];
    return Scaffold(
      appBar: AppBar(title: Text('자동 실행', style: AppText.heading),
        actions: const [NotificationAction(), SettingsAction()]),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(routinesProvider);
          _ruleChanged();
          await ref.read(routinesProvider.future).catchError((_) => <Routine>[]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpace.xl),
          children: [
            const _Note('시간이나 조건에 맞춰 할 일을 관리해요. 스위치는 가전 전원이 아니라 실행 허용이에요.'),
            Text('정해진 시간', style: AppText.title),
            ...list.when(
              loading: () => const [Center(child: CircularProgressIndicator())],
              error: (_, __) => const [_Note('예약을 불러오지 못했어요. 본체 연결을 확인해 주세요.')],
              data: (items) {
                final scheduled = items.where((r) => !r.isTemplate && routineClock(r) != null).toList();
                return [
                  if (scheduled.isEmpty) const _Note('정해진 시간에 할 일이 없어요.'),
                  for (final r in scheduled)
                    _RoutineRow(
                      routine: r, applianceNames: names, applianceIcons: icons,
                      onEdit: () => _open(context, r),
                      onRun: null,
                      running: false, busy: false, error: null,
                      onToggle: switch (routineAutoRule(r, allRules)) {
                        final rule? => (on) => _toggleRule(context, r, rule, on),
                        null => (on) => _toggleRoutine(context, r, on),
                      },
                      switchOn: routineAutoRule(r, allRules)?.enabled ?? r.enabled,
                      switchLabel: routineAutoRule(r, allRules) != null
                          ? '${r.name} 자동 실행 허용' : '${r.name} 예약 켜기',
                      toggling: _togglingId == r.id,
                      next: next?.routineId == r.id ? next : null,
                      autoRule: routineAutoRule(r, allRules),
                      auto: routineAutoRule(r, allRules)?.enabled ?? false,
                      onAuto: switch (routineAutoRule(r, allRules)) {
                        final rule? => () => _openAutoRule(context, rule.id),
                        null => null,
                      },
                    ),
                ];
              },
            ),
            const SizedBox(height: AppSpace.xl),
            Text('상황에 따라', style: AppText.title),
            ...rules.when(
              loading: () => const [Center(child: CircularProgressIndicator())],
              error: (_, __) => const [_Note('조건을 불러오지 못했어요. 아래로 당겨 다시 확인해 주세요.')],
              data: (items) {
                // 이름·시각이 맞지 않는 시각 규칙도 남겨 끄는 길을 잃지 않는다.
                final standalone = standaloneAutoRules(items, list.valueOrNull ?? const []);
                return [
                  if (standalone.isEmpty) const _Note('허용한 조건이 없어요. 제안에서 “다음부터도 자동으로”를 고르면 여기에 보여요.'),
                  for (final rule in standalone) _AutoRuleRow(rule: rule, onChanged: _ruleChanged),
                ];
              },
            ),
            const SizedBox(height: AppSpace.xl),
            OutlinedButton.icon(onPressed: () => context.push('/routines'),
              icon: const Icon(Icons.bookmark_outline), label: const Text('저장한 동작 전체')),
          ],
        ),
      ),
    );
  }
}
