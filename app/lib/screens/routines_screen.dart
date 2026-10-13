import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/routine.dart';
import '../providers/appliance_provider.dart';
import '../providers/routine_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/routine_run.dart';

/// 루틴 탭 — 위에 "다음 실행"(예약이 있을 때만), 아래에 "내 루틴 / 추천"(UI 확정 §2).
///
/// 추천은 **템플릿**이다. 사용자 데이터가 아니고 실행되지도 않는다 -- 눌러서
/// 자기 가전·버튼으로 고친 뒤 저장해야 루틴이 된다.
///
/// 행마다 '편집'과 '실행하기'를 나눈다(2026-10-13). '실행하기'는 편집기의 '지금 실행'과
/// 같은 경로로 **승인 카드만 만든다** — 가전은 승인 화면에서 최종 승인해야 움직인다.
class RoutinesScreen extends ConsumerStatefulWidget {
  const RoutinesScreen({super.key});

  @override
  ConsumerState<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends ConsumerState<RoutinesScreen> {
  bool _templates = false;

  /// 카드 요청 중인 루틴(한 번에 하나). 중복 탭·다른 행 동시 실행을 막는다.
  String? _runningId;

  /// 행별 실행 실패 문장.
  final Map<String, String> _errors = {};

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
            // 예약이 있을 때만. nextRoutineProvider는 조회 실패도 null로 돌리므로
            // null을 '예약 없음'으로 단정하지 않는다.
            if (next != null) ...[
              _NextRunCard(next: next),
              const SizedBox(height: 16),
            ],
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
                          onEdit: () => _open(context, r),
                          onRun: r.isRunCandidate
                              ? () => _run(context, r.id!)
                              : null,
                          running: r.id != null && _runningId == r.id,
                          busy: _runningId != null,
                          error: r.id == null ? null : _errors[r.id],
                        ),
                    ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _run(BuildContext context, String id) async {
    if (_runningId != null) return; // 누르는 중 — 두 번째 탭은 버린다
    setState(() {
      _runningId = id;
      _errors.remove(id);
    });
    try {
      final error = await runRoutineNow(context, ref, id);
      if (mounted && error != null) setState(() => _errors[id] = error);
    } finally {
      if (mounted) setState(() => _runningId = null);
    }
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
  final RoutineNextRun next;

  @override
  Widget build(BuildContext context) {
    final n = next;
    final at = n.at;
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
              color: context.appPrimary,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('다음 실행 · ${n.name}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                Text('${n.when} · ${n.modeLabel}',
                    style: TextStyle(fontSize: 14, color: context.appMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 루틴 한 줄의 부제 — 조건 한 줄(알려진 가전 알림은 사람 말로) · 대상 · 알림만 · 꺼짐.
/// '승인 후 실행'은 줄마다 되풀이하지 않는다(실행하기가 승인 카드로 간다).
String routineSubtitle(Routine r, Map<String, String> applianceNames) {
  final when = (r.trigger.kind == RoutineTriggerKind.event
          ? knownEventLabel(r.trigger.event)
          : null) ??
      r.when ??
      r.trigger.describe(applianceNames: applianceNames);
  final targets =
      r.applianceIds.map((id) => applianceNames[id] ?? id).toList();
  return [
    when,
    if (targets.isNotEmpty) '${targets.join('·')} ${r.steps.length}단계',
    if (r.mode == RoutineMode.notify) r.mode.label,
    if (!r.enabled) '꺼짐',
  ].join(' · ');
}

class _RoutineRow extends StatelessWidget {
  const _RoutineRow({
    required this.routine,
    required this.applianceNames,
    required this.onEdit,
    required this.onRun,
    required this.running,
    required this.busy,
    required this.error,
  });

  final Routine routine;
  final Map<String, String> applianceNames;
  final VoidCallback onEdit;

  /// null이면 실행하기를 두지 않는다(알림만·꺼짐·템플릿·가전 조작 없음).
  final VoidCallback? onRun;

  /// 이 행의 카드 요청 중.
  final bool running;

  /// 어느 행이든 카드 요청 중(다른 행 실행도 잠근다).
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final r = routine;
    final key = r.id ?? r.templateId ?? r.name;
    final info = InkWell(
      // 행(이름·조건)을 누르면 편집 — 종전과 같다. 실행하기는 이 영역 밖이다.
      key: Key('routine-$key'),
      onTap: onEdit,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
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
                    Text(r.name,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    Text(
                      r.isTemplate && (r.description ?? '').isNotEmpty
                          ? r.description!
                          : routineSubtitle(r, applianceNames),
                      style: TextStyle(fontSize: 14, color: context.appMuted),
                    ),
                  ],
                ),
              ),
              if (r.isTemplate) Icon(Icons.chevron_right, color: context.appMuted),
            ],
          ),
        ),
      ),
    );
    if (r.isTemplate) return info;

    final run = onRun;
    // 큰 글씨에서는 Wrap이 버튼을 다음 줄로 내린다 — 겹치거나 줄어들지 않는다.
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Semantics(
          label: '${r.name} 편집',
          container: true,
          button: true,
          excludeSemantics: true,
          child: OutlinedButton(
            key: Key('routine-edit-$key'),
            onPressed: onEdit,
            style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48)),
            child: const Text('편집'),
          ),
        ),
        if (run != null)
          Semantics(
            label: '${r.name} 실행하기',
            container: true,
            button: true,
            enabled: !busy,
            excludeSemantics: true,
            child: FilledButton(
              key: Key('routine-run-$key'),
              onPressed: busy ? null : run,
              style: FilledButton.styleFrom(minimumSize: const Size(112, 48)),
              child: running
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('실행하기'),
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          info,
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: actions,
          ),
          if (error case final message?) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Text(message,
                  style: TextStyle(fontSize: 15, color: context.appDanger)),
            ),
          ],
        ],
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
