import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/auto_rule.dart';
import '../models/execution_status.dart';
import '../models/routine.dart';
import '../models/routine_candidate.dart';
import '../providers/appliance_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/routine_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../models/display_status.dart';
import '../models/line_break.dart';
import '../models/quiet_hours.dart';
import '../theme/app_text.dart';
import '../widgets/auto_rule_confirm_sheet.dart';
import '../widgets/routine_candidate_sheet.dart';
import '../widgets/routine_icon.dart';
import '../widgets/routine_run.dart';
import '../widgets/row_menu.dart';
import '../widgets/status_badge.dart';
import '../theme/app_tokens.dart';

/// 루틴 탭 — 세그먼트 [내 루틴 | 자동으로 하기](UI 개편안 §4, 2026-10-18).
///
/// 내 루틴: 다음 실행(예약이 있을 때만) · 사용 기록으로 만든 초안 · 루틴 줄(실행 하나 + ⋮).
/// 자동으로 하기: 허락한 규칙 카드(언제·무엇을 한 문장, 상태 배지, 최근 결과, 스위치).
///
/// 예시 루틴은 미리 만든 **템플릿**이다(개인 습관 추천이 아니다) — [+ 새 루틴] 안의 선택지로 둔다.
/// 눌러서 자기 가전·버튼으로 고친 뒤 저장해야 루틴이 된다.
///
/// 줄의 '실행'은 편집기의 '지금 실행'과 같은 경로로 **승인 카드만 만든다** — 가전은 승인 화면에서
/// 최종 허락해야 움직인다.
class RoutinesScreen extends ConsumerStatefulWidget {
  const RoutinesScreen({super.key});

  @override
  ConsumerState<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends ConsumerState<RoutinesScreen> {
  /// 0 = 내 루틴, 1 = 자동으로 하기.
  int _segment = 0;

  /// 카드 요청 중인 루틴(한 번에 하나). 중복 탭·다른 행 동시 실행을 막는다.
  String? _runningId;

  /// 행별 실행 실패 문장.
  final Map<String, String> _errors = {};

  @override
  Widget build(BuildContext context) {
    final next = ref.watch(nextRoutineProvider).valueOrNull;
    final rules = ref.watch(autoRulesProvider).valueOrNull ?? const <AutoRule>[];
    final needsSetup = {
      for (final a in ref.watch(installedAppliancesProvider))
        if (needsPanelMapping(a)) a.id,
    };
    final list = ref.watch(routinesProvider);
    final installed = ref.watch(installedAppliancesProvider);
    final names = {for (final a in installed) a.id: a.name};
    final icons = {for (final a in installed) a.id: a.icon};
    final executing = switch (ref.watch(executionStatusProvider).phase) {
      ExecutionPhase.waiting || ExecutionPhase.running || ExecutionPhase.retrying => true,
      _ => false,
    };

    return Scaffold(
      appBar: AppBar(
        // 탭 제목은 홈('우리 집')과 같은 굵은 큰 제목(UI 평가 10/17).
        title: Text('루틴', style: AppText.heading),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.md),
            child: FilledButton.icon(
              key: const Key('routine-new'),
              // 앱바 안에서는 테마의 '폭 채우기'를 끈다.
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => _newRoutine(context),
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
          ref.invalidate(autoRulesProvider);
          ref.invalidate(routineCandidatesProvider);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xs, AppSpace.xl, AppSpace.xxxl),
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('내 루틴')),
                ButtonSegment(value: 1, label: Text('자동으로 하기')),
              ],
              selected: {_segment},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _segment = v.first),
            ),
            const SizedBox(height: AppSpace.lg),
            if (_segment == 1)
              ...(rules.isEmpty
                  ? [
                      const _Note('아직 자동으로 하는 일이 없어요. 할까요? 카드에서 "다음부터도 자동으로"를 고르면 여기에 생겨요.'),
                    ]
                  : [
                      for (final rule in rules)
                        _AutoRuleRow(rule: rule, onChanged: () => ref.invalidate(autoRulesProvider)),
                    ])
            else ...[
              // 예약이 있을 때만. nextRoutineProvider는 조회 실패도 null로 돌리므로
              // null을 '예약 없음'으로 단정하지 않는다.
              if (next != null) ...[
                _NextRunCard(next: next),
                const SizedBox(height: AppSpace.lg),
              ],
              // 사용 기록으로 만든 루틴 초안(2026-10-14) — 조용히: 이 쪽에만, 실행 중에는 감춘다(작업 도중 끼어들지 않는다).
              if (!executing)
                for (final c in ref.watch(routineCandidatesProvider).valueOrNull ?? const <RoutineCandidate>[])
                  _CandidateCard(
                    candidate: c,
                    onSave: () => _saveCandidate(context, c),
                    onDecline: () => _declineCandidate(c),
                  ),
              ...list.when(
                loading: () => const [
                  Padding(
                    padding: EdgeInsets.all(AppSpace.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
                error: (e, _) => [
                  _Note(
                    e is RoutinesUnavailable
                        ? '본체와 연결하면 루틴을 볼 수 있어요.'
                        : '루틴을 불러오지 못했어요. 연결을 보고 아래로 당겨 새로 봐 주세요.',
                  ),
                ],
                data: (routines) => routines.isEmpty
                    ? [
                        const _Note('아직 만든 루틴이 없어요. 가전 화면의 "누르는 순서 저장"이나 [+ 새 루틴]의 예시 루틴으로 만들어 보세요.'),
                      ]
                    : [
                        // 설정이 필요한 가전의 루틴은 아래로 — 홈과 같은 순서(UI 평가 10/17).
                        for (final r in [
                          ...routines.where((r) => !r.applianceIds.any(needsSetup.contains)),
                          ...routines.where((r) => r.applianceIds.any(needsSetup.contains)),
                        ])
                          _RoutineRow(
                            routine: r,
                            applianceNames: names,
                            applianceIcons: icons,
                            onEdit: () => _open(context, r),
                            onDelete: r.isTemplate || r.id == null ? null : () => _delete(context, r),
                            // 버튼 자리를 맞추지 않은 가전의 루틴은 실행 대신 이유(외부 평가 10/16 3차).
                            onRun: r.isRunCandidate && !r.applianceIds.any(needsSetup.contains)
                                ? () => _run(context, r.id!)
                                : null,
                            running: r.id != null && _runningId == r.id,
                            busy: _runningId != null,
                            error: r.id == null ? null : _errors[r.id],
                            onSetup: r.applianceIds.any(needsSetup.contains)
                                ? () => context.push('/appliance/detail/'
                                    '${r.applianceIds.firstWhere(needsSetup.contains)}')
                                : null,
                            // 이유 문장은 두지 않는다 — '설정하기' 단추가 말하고, 무엇이 남았는지는 홈의
                            // '확인이 필요해요' 한 곳에서 말한다(평가 3차 10/18: 행마다 두 줄 경고).
                          ),
                      ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// [+ 새 루틴] — 빈 루틴, 또는 예시 루틴을 골라 고쳐 쓰기(2026-10-18: 예시는 세그먼트가 아니라 여기).
  Future<void> _newRoutine(BuildContext context) async {
    final picked = await showModalBottomSheet<_NewChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => const _NewRoutineSheet(),
    );
    if (picked == null || !context.mounted) return;
    await _open(context, picked.template);
  }

  /// ⋮ 메뉴 '지우기' — 확인을 한 번 더 받고 지운다(편집기의 지우기와 같은 서버 경로).
  Future<void> _delete(BuildContext context, Routine r) async {
    final api = ref.read(rpiApiServiceProvider);
    final id = r.id;
    if (api == null || id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirmDelete(context,
        title: '이 루틴을 지울까요?', body: '지우면 떠 있던 카드도 내려가요.');
    if (!ok || !mounted) return;
    try {
      await api.deleteRoutine(id);
    } on RpiApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(e.message.isNotEmpty ? e.message : '지우지 못했어요. 연결을 봐 주세요.')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('지우지 못했어요. 연결을 봐 주세요.')));
    }
    if (!mounted) return;
    ref.invalidate(routinesProvider);
    ref.invalidate(nextRoutineProvider);
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

  /// 초안 저장 — 확인 시트에서 이름과 '직접 실행할 때만 / 정해진 때 물어보기'만 고른다. 저장만 한다.
  Future<void> _saveCandidate(BuildContext context, RoutineCandidate c) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final saved = await showRoutineCandidateSheet(context, candidate: c, api: api);
    if (!mounted) return;
    ref.invalidate(routineCandidatesProvider);
    if (saved == null) return;
    ref.invalidate(routinesProvider);
    ref.invalidate(nextRoutineProvider);
    messenger.showSnackBar(SnackBar(
      content: Text("'${saved.name}' 루틴을 저장했어요. 아직 하지는 않았어요."),
    ));
  }

  Future<void> _declineCandidate(RoutineCandidate c) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null) return;
    try {
      await api.declineRoutineCandidate(c.key);
    } catch (_) {
      // 실패해도 목록을 다시 받는다 — 남아 있으면 그대로 보인다.
    }
    if (mounted) ref.invalidate(routineCandidatesProvider);
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

/// 사용 기록으로 만든 루틴 초안 한 장 — 가전·버튼 순서와 근거(가전 사용 기록 문장), [루틴으로 저장] [괜찮아요].
///
/// 개인 습관으로 단정하지 않는다(누가 썼는지 모른다). '추천'이라 부르지 않는다(예시 루틴과 구분).
class _CandidateCard extends StatelessWidget {
  const _CandidateCard({required this.candidate, required this.onSave, required this.onDecline});

  final RoutineCandidate candidate;
  final VoidCallback onSave;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final c = candidate;
    return Container(
      key: Key('candidate-${c.key}'),
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: context.appSurfaceLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.appBorderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('사용 기록으로 만든 루틴 초안',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          const SizedBox(height: AppSpace.xs),
          Text('${c.applianceName}: ${c.sequenceText}',
              style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
          Text(c.evidence, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              FilledButton(
                key: Key('candidate-save-${c.key}'),
                onPressed: onSave,
                style: FilledButton.styleFrom(minimumSize: const Size(112, 48)),
                child: const Text('루틴으로 저장'),
              ),
              TextButton(
                key: Key('candidate-decline-${c.key}'),
                onPressed: onDecline,
                style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
                child: const Text('괜찮아요'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 다음 실행 — 작은 한 줄(평가 3차 10/18). 큰 시각은 홈 '지금 우리 집'에만 둔다 — 두 탭에 같은 크기로 겹쳐 있었다.
class _NextRunCard extends StatelessWidget {
  const _NextRunCard({required this.next});
  final RoutineNextRun next;

  @override
  Widget build(BuildContext context) {
    final n = next;
    // 본체 벽시계 그대로 — 폰 시간대로 바꾸면 '매일 07:00' 옆에 22:00이 나왔다(2차 평가 10/18).
    // 오늘·내일과 시각이 먼저, 실행 방식은 끝(외부 평가 10/16 p02).
    final line = [
      '다음: ${n.name}',
      if (n.dayLabel.isNotEmpty) n.dayLabel,
      if (n.when.isNotEmpty) n.when else n.clock,
      n.modeLabel,
    ].join(' · ');
    return Row(
      key: const Key('routines-next'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.xs),
          child: Icon(AppIcons.schedule, size: 20, color: context.appMuted),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(keepWordsTogether(line),
              semanticsLabel: line,
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
        ),
      ],
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
    // 직접 실행 루틴은 '언제'를 적지 않는다 — "직접 실행할 때"는 모든 루틴이 그렇다(2026-10-14 UX).
    // 서버 `when` 문장으로 가른다(목록의 루틴은 trigger 없이 when만 올 수 있다).
    if (when != const RoutineTrigger.manual().describe()) when,
    // 대상 가전과 크기 — 키오스크와 같은 단위 '버튼 N번'(작은 팔이 누르는 수)·'LG 가전 설정 N번'
    // (평가 3차 10/18: '할 일 1개'는 무엇을 몇 번 하는지 말하지 않았다).
    if (targets.isNotEmpty) targets.join(', '),
    ...routineSizeParts(r),
    if (r.mode == RoutineMode.notify) r.mode.label,
    if (!r.enabled) '꺼짐',
  ].join(' · ');
}

/// 루틴 크기 — '버튼 N번'(누를 버튼 합) · 'LG 가전 설정 N번'(LG 가전 설정 단계 수). 키오스크 루틴 카드와 같은 말.
List<String> routineSizeParts(Routine r) {
  var presses = 0;
  var settings = 0;
  for (final s in r.steps) {
    if (s.kind == RoutineStepKind.pressSequence) presses += s.buttons.length;
    if (s.kind == RoutineStepKind.thinqCommand) settings += 1;
  }
  return [
    // 숫자와 '번'이 다른 줄로 떨어지지 않게 단어 결합 문자(U+2060)로 붙인다(외부 평가 2026-10-13 L3).
    if (presses > 0) '버튼 $presses\u2060번',
    if (settings > 0) 'LG 가전 설정 $settings\u2060번',
  ];
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
    this.applianceIcons = const {},
    this.onDelete,
    this.onSetup,
  });

  /// 가전 id → 아이콘. 줄 아이콘을 대상 가전 아이콘으로(평가 3차 10/18).
  final Map<String, IconData> applianceIcons;

  /// 설정이 필요한 가전의 상세로 — 있으면 '실행' 대신 '설정하기' 단추(홈과 같다).
  final VoidCallback? onSetup;

  final Routine routine;
  final Map<String, String> applianceNames;

  /// 행 전체 탭 = 편집(상세). ⋮ 메뉴의 '편집'도 같다.
  final VoidCallback onEdit;

  /// ⋮ 메뉴의 '지우기'(확인은 부르는 쪽이 받는다). null이면 메뉴에 두지 않는다.
  final VoidCallback? onDelete;

  /// null이면 실행 단추를 두지 않는다(알림만·꺼짐·템플릿·가전 조작 없음).
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
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(r.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
        Text(
          r.isTemplate && (r.description ?? '').isNotEmpty
              ? r.description!
              : routineSubtitle(r, applianceNames),
          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
        ),
      ],
    );
    final icon = RoutineIcon(
        routine: r,
        iconOf: applianceIcons,
        color: r.enabled ? context.appPrimary : context.appMuted);

    // 예시 루틴은 낭독에서도 예시라고 말하고, 누르면 무엇이 되는지 말한다(2026-10-14 UI 정리).
    if (r.isTemplate) {
      final about = (r.description ?? '').isNotEmpty ? '${r.description}. ' : '';
      return Semantics(
        label: '예시 루틴 ${r.name}. $about고쳐서 저장하면 내 루틴이 돼요',
        button: true,
        container: true,
        excludeSemantics: true,
        onTap: onEdit,
        child: InkWell(
          key: Key('routine-$key'),
          onTap: onEdit,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              child: Row(children: [
                icon,
                const SizedBox(width: AppSpace.md),
                Expanded(child: text),
                Icon(Icons.chevron_right, color: context.appMuted),
              ]),
            ),
          ),
        ),
      );
    }

    // 행의 단추는 하나 — 실행, 아니면 설정하기. 편집·지우기는 ⋮ 안(2026-10-18 버튼 위계).
    final run = onRun;
    final setup = onSetup;
    final Widget? action = setup != null
        ? Semantics(
            label: '${r.name} 가전 설정하기',
            container: true,
            button: true,
            excludeSemantics: true,
            child: OutlinedButton(
              key: Key('routine-setup-$key'),
              onPressed: setup,
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(88, 48), foregroundColor: context.appWarning),
              child: const Text('설정하기'),
            ),
          )
        : run != null
            ? Semantics(
                label: '${r.name} 실행하기',
                container: true,
                button: true,
                enabled: !busy,
                excludeSemantics: true,
                // 테두리 버튼 — 줄마다 채운 버튼이면 주 행동이 너무 많아 위계가 흐려진다.
                child: OutlinedButton(
                  key: Key('routine-run-$key'),
                  onPressed: busy ? null : run,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(72, 48)),
                  child: running
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('실행'),
                ),
              )
            : null;
    final menu = RowMenu(
      menuKey: Key('routine-menu-$key'),
      semanticLabel: '${r.name} 더 보기',
      items: [
        RowMenuItem(
          key: Key('routine-edit-$key'),
          label: '편집',
          icon: Icons.edit_outlined,
          onSelected: onEdit,
        ),
        if (onDelete case final del?)
          RowMenuItem(
            key: Key('routine-delete-$key'),
            label: '지우기',
            icon: Icons.delete_outline,
            danger: true,
            onSelected: del,
          ),
      ],
    );
    // 큰 글씨에서는 단추를 이름 아래로 내린다 — 한 줄에 두면 이름이 한 글자씩 꺾인다.
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final head = Row(
      children: [
        icon,
        const SizedBox(width: AppSpace.md),
        Expanded(child: Semantics(container: true, child: text)),
        if (!big && action != null) ...[const SizedBox(width: AppSpace.sm), action],
        menu,
      ],
    );
    const indent = AppSpace.xxxl + AppSpace.xs;
    return Padding(
      key: Key('routine-row-$key'),
      padding: const EdgeInsets.only(bottom: AppSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            // 행 전체를 누르면 편집(상세). 실행 단추·⋮는 제 몫을 먼저 받는다.
            key: Key('routine-$key'),
            borderRadius: BorderRadius.circular(12),
            onTap: onEdit,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                child: head,
              ),
            ),
          ),
          if (big && action != null)
            Padding(
              padding: const EdgeInsets.only(left: indent, bottom: AppSpace.xs),
              child: action,
            ),
          if (error case final message?)
            Padding(
              padding: const EdgeInsets.only(left: indent, bottom: AppSpace.xs),
              // 어절 단위로 줄을 바꾼다('자리/를' 방지, UI 평가 10/17).
              child: Text(keepWordsTogether(message),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
            ),
        ],
      ),
    );
  }
}

/// 자동 실행 허용 규칙 한 줄 — '자동 실행 켜짐/꺼짐', 끄기·다시 허용·설정값 바꾸기·삭제.
///
/// 켜는 일(다시 허용)은 늘 확인 시트를 거친다 — 서버가 준 조건·동작을 보여 주고 그 지문으로만 켠다.
/// 설정값을 바꾸면 서버가 자동 실행을 끄므로, 바꾼 내용으로 다시 허용할지 이어서 묻는다.
class _AutoRuleRow extends ConsumerStatefulWidget {
  const _AutoRuleRow({required this.rule, required this.onChanged});

  final AutoRule rule;
  final VoidCallback onChanged;

  @override
  ConsumerState<_AutoRuleRow> createState() => _AutoRuleRowState();
}

class _AutoRuleRowState extends ConsumerState<_AutoRuleRow> {
  bool _busy = false;

  Future<void> _run(Future<void> Function(RpiApiService api) action) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action(api);
    } on RpiApiException catch (e) {
      _say(e.message.isNotEmpty ? e.message : '바꾸지 못했어요. 연결을 봐 주세요.');
    } catch (_) {
      _say('바꾸지 못했어요. 연결을 봐 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onChanged();
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _reallow(RpiApiService api, AutoRule rule) async {
    final fp = rule.fingerprint;
    if (fp == null) {
      _say('어느 가전인지 몰라서 켤 수 없어요. 가전 연결을 봐 주세요');
      return;
    }
    final ok = await showAutoRuleConfirmSheet(
      context,
      conditionText: rule.conditionText,
      actionText: rule.actionText,
      caveat: rule.caveat,
      title: '다음부터 자동으로 할까요?',
      confirmLabel: '허락',
    );
    if (!ok) return;
    await api.setAutoRuleEnabled(rule.id, true, fingerprint: fp);
  }

  Future<void> _changeValue(RpiApiService api) async {
    final rule = widget.rule;
    final choices = rule.allowedValues.where((v) => v.$1 != rule.value).toList();
    if (choices.isEmpty) return;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(autoRuleValueLabel(rule)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.xxl, 0, AppSpace.xxl, AppSpace.sm),
            child: Text('바꾸면 다시 허락해야 자동으로 해요.',
                style: TextStyle(fontSize: AppFont.caption, color: dialogContext.appMuted)),
          ),
          for (final (v, label) in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, v),
              child: Text(label, style: const TextStyle(fontSize: AppFont.body)),
            ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    final changed = await api.updateAutoRuleValue(rule.id, value);
    if (!mounted) return;
    await _reallow(api, changed);
  }

  Future<void> _delete(RpiApiService api) async {
    final ok = await confirmDelete(context,
        title: '이 자동으로 하기를 지울까요?',
        body: '${widget.rule.conditionText} → ${widget.rule.actionText}');
    if (ok) await api.deleteAutoRule(widget.rule.id);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rule;
    final reason = r.disabledReason;
    final quietNote = quietRuleNote(ref.watch(quietHoursProvider).valueOrNull, r);
    // 상태는 서버 문장(status_label)이 아니라 enabled 값으로(2차 평가 10/18).
    final badge = r.enabled
        ? const StatusBadge(icon: AppIcons.auto, label: '자동으로 해요', tone: BadgeTone.accent)
        : const StatusBadge(icon: Icons.pause_circle_outline, label: '지금은 안 해요');
    return Padding(
      key: Key('auto-rule-${r.id}'),
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Card(
        semanticContainer: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.xs, AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(AppIcons.auto, color: r.enabled ? context.appPrimary : context.appMuted),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Text(keepWordsTogether(r.name),
                        semanticsLabel: r.name,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  // 켜기/끄기 — 켤 때는 늘 확인 시트(서버가 준 조건·동작과 지문으로만 켠다), 끌 때는 바로.
                  Semantics(
                    label: '${r.name} 자동으로 하기',
                    toggled: r.enabled,
                    excludeSemantics: true,
                    child: SizedBox(
                      height: 48,
                      child: Switch(
                        key: Key('auto-rule-switch-${r.id}'),
                        value: r.enabled,
                        onChanged: _busy
                            ? null
                            : (on) => on
                                ? _run((api) => _reallow(api, r))
                                : _run((api) => api.setAutoRuleEnabled(r.id, false)),
                      ),
                    ),
                  ),
                  // 값 바꾸기·지우기는 ⋮ 안(2026-10-18 버튼 위계).
                  RowMenu(
                    menuKey: Key('auto-rule-menu-${r.id}'),
                    semanticLabel: '${r.name} 더 보기',
                    items: [
                      if (r.allowedValues.length > 1)
                        RowMenuItem(
                          key: Key('auto-rule-edit-${r.id}'),
                          label: autoRuleValueLabel(r),
                          icon: Icons.tune,
                          enabled: !_busy,
                          onSelected: () => _run(_changeValue),
                        ),
                      RowMenuItem(
                        key: Key('auto-rule-delete-${r.id}'),
                        label: '지우기',
                        icon: Icons.delete_outline,
                        danger: true,
                        enabled: !_busy,
                        onSelected: () => _run(_delete),
                      ),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: AppSpace.xxxl + AppSpace.xs, right: AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 언제·무엇을 한 문장(2차 평가 10/18) — 화살표·'조건:/동작:' 표를 쓰지 않는다.
                    // 낱말 중간에서 꺾이지 않게('전/원' 방지).
                    Text(keepWordsTogether(autoRuleSentence(r)),
                        semanticsLabel: autoRuleSentence(r),
                        style: const TextStyle(fontSize: AppFont.body)),
                    const SizedBox(height: AppSpace.sm),
                    badge,
                    if (!r.enabled && reason != null && reason.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(reason, style: context.appCaption),
                    ],
                    // 조용한 시간과 겹치면 여기서도 말한다 — 켜져 있으면 앰버(실제로 건너뜀), 꺼져 있으면 회색(UI 평가 7차 10/17).
                    if (quietNote != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(keepWordsTogether(quietNote),
                          semanticsLabel: quietNote,
                          style: TextStyle(
                              fontSize: AppFont.caption,
                              fontWeight: FontWeight.w600,
                              color: ref.watch(quietHoursProvider).valueOrNull?.enabled == true
                                  ? context.appWarning
                                  : context.appMuted)),
                    ],
                    // 마지막 자동 실행의 장치별 결과 — 서버 문장 그대로(확인된 것만 '바꿨어요').
                    if (r.lastRunNotices.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.sm),
                      Text('최근 결과', style: context.appCaption.copyWith(fontWeight: FontWeight.w600)),
                      for (final n in r.lastRunNotices) Text(n, style: context.appCaption),
                    ],
                  ],
                ),
              ),
            ],
          ),
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
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: Text(text, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
      );
}

/// 규칙 값 바꾸기 단추 이름 — 무엇의 값인지 말한다(UI 평가 3차 10/17: '세기'는 무엇의 세기인지 몰랐다).
///
/// 서버(bcc4cdb)가 규칙 문장에서 '풍량'을 뺐다 — 문장이 아니라 동작 이름으로 가른다(옛 서버는 문장으로).
String autoRuleValueLabel(AutoRule rule) =>
    rule.action == 'set_wind_strength' ||
            (rule.action == null && rule.actionText.contains('풍량'))
        ? '바람 세기 바꾸기'
        : '설정 바꾸기';

/// 규칙 한 문장 — 언제 + 무엇을(화살표 없이). 서버 문장이 '…면'·'…해요'로 이어 읽히게 만든다(2차 평가 10/18).
String autoRuleSentence(AutoRule rule) =>
    [rule.conditionText.trim(), rule.actionText.trim()].where((t) => t.isNotEmpty).join(' ');

/// [+ 새 루틴]에서 고른 것 — 빈 루틴이면 [template]이 null.
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
    final icons = {for (final a in installed) a.id: a.icon};
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
