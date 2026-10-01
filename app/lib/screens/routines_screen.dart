import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/routine.dart';
import '../providers/appliance_provider.dart';
import '../providers/routine_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// 루틴 탭 — 위에 "다음 실행", 아래에 "내 루틴 / 추천"(UI 확정 §2).
///
/// 추천은 **템플릿**이다. 사용자 데이터가 아니고 실행되지도 않는다 -- 눌러서
/// 자기 가전·버튼으로 고친 뒤 저장해야 루틴이 된다.
class RoutinesScreen extends ConsumerStatefulWidget {
  const RoutinesScreen({super.key});

  @override
  ConsumerState<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends ConsumerState<RoutinesScreen> {
  bool _templates = false;

  @override
  Widget build(BuildContext context) {
    final next = ref.watch(nextRoutineProvider).valueOrNull;
    final list = _templates
        ? ref.watch(routineTemplatesProvider)
        : ref.watch(routinesProvider);
    final names = {
      for (final a in ref.watch(installedAppliancesProvider)) a.id: a.name,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('루틴'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              // 앱바 안에서는 테마의 '폭 채우기'를 끈다.
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _open(context, null),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('새 루틴'),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(routinesProvider);
          ref.invalidate(routineTemplatesProvider);
          ref.invalidate(nextRoutineProvider);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
          children: [
            _NextRunCard(next: next),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('내 루틴')),
                ButtonSegment(value: true, label: Text('추천')),
              ],
              selected: {_templates},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _templates = v.first),
            ),
            const SizedBox(height: 12),
            ...list.when(
              loading: () => const [
                Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
              error: (e, _) => [
                _Note(
                  e is RoutinesUnavailable
                      ? '허브 주소를 정하면 루틴을 볼 수 있어요.'
                      : '루틴을 불러오지 못했어요. 연결을 확인하고 아래로 당겨 새로고침해 주세요.',
                ),
              ],
              data: (routines) => routines.isEmpty
                  ? [
                      _Note(_templates
                          ? '지금 보여 드릴 추천이 없어요.'
                          : '아직 만든 루틴이 없어요. 가전 상세에서 "루틴 녹화"로 만들거나 추천에서 골라 보세요.'),
                    ]
                  : [
                      for (final r in routines)
                        _RoutineRow(
                          routine: r,
                          applianceNames: names,
                          onTap: () => _open(context, r),
                        ),
                    ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, Routine? routine) async {
    // 템플릿은 새 루틴 초안으로 연다 -- 템플릿 자체를 고치는 것이 아니다.
    final initial = routine == null
        ? null
        : routine.isTemplate
            ? routine.asNewDraft()
            : routine;
    await context.push('/routine/edit', extra: initial);
    if (!mounted) return;
    ref.invalidate(routinesProvider);
    ref.invalidate(nextRoutineProvider);
  }
}

class _NextRunCard extends StatelessWidget {
  const _NextRunCard({required this.next});
  final RoutineNextRun? next;

  @override
  Widget build(BuildContext context) {
    final n = next;
    final at = n?.at;
    final hm = at == null
        ? '--:--'
        : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.appSurfaceLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appBorderSubtle),
      ),
      child: Row(
        children: [
          Text(
            hm,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: n == null ? context.appMuted : context.appPrimary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: n == null
                ? Text('예약된 루틴이 없어요',
                    style: TextStyle(fontSize: 15, color: context.appMuted))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('다음 실행 · ${n.name}',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      Text('${n.when} · ${n.modeLabel}',
                          style:
                              TextStyle(fontSize: 14, color: context.appMuted)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _RoutineRow extends StatelessWidget {
  const _RoutineRow({
    required this.routine,
    required this.applianceNames,
    required this.onTap,
  });

  final Routine routine;
  final Map<String, String> applianceNames;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final r = routine;
    final when = r.when ?? r.trigger.describe(applianceNames: applianceNames);
    final targets = r.applianceIds
        .map((id) => applianceNames[id] ?? id)
        .toList();
    final subtitle = [
      when,
      if (targets.isNotEmpty) '${targets.join('·')} ${r.steps.length}단계',
      r.mode.label,
      if (!r.enabled) '꺼짐',
    ].join(' · ');
    return InkWell(
      key: Key('routine-${r.id ?? r.templateId ?? r.name}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(
              r.isTemplate ? Icons.auto_awesome_outlined : Icons.repeat,
              color: r.enabled ? context.appPrimary : context.appMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  Text(
                    r.isTemplate && (r.description ?? '').isNotEmpty
                        ? r.description!
                        : subtitle,
                    style: TextStyle(fontSize: 14, color: context.appMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: context.appMuted),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text, style: TextStyle(fontSize: 15, color: context.appMuted)),
      );
}
