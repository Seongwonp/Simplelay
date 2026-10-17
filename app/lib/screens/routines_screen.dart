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
import '../widgets/routine_run.dart';
import '../theme/app_tokens.dart';

/// 루틴 탭 — 위에 "다음 실행"(예약이 있을 때만), 아래에 "내 루틴 / 예시 루틴"(UI 확정 §2).
///
/// 예시 루틴은 미리 만든 **템플릿**이다(개인 습관 추천이 아니라 2026-10-14에 "추천"에서 이름을 바꿨다).
/// 사용자 데이터가 아니고 실행되지도 않는다 -- 눌러서
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
    final rules = ref.watch(autoRulesProvider).valueOrNull ?? const <AutoRule>[];
    final needsSetup = {
      for (final a in ref.watch(installedAppliancesProvider))
        if (needsPanelMapping(a)) a.id,
    };
    final list = _templates
        ? ref.watch(routineTemplatesProvider)
        : ref.watch(routinesProvider);
    final names = {
      for (final a in ref.watch(installedAppliancesProvider)) a.id: a.name,
    };
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
          ref.invalidate(autoRulesProvider);
          ref.invalidate(routineCandidatesProvider);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xs, AppSpace.xl, AppSpace.xxxl),
          children: [
            // 예약이 있을 때만. nextRoutineProvider는 조회 실패도 null로 돌리므로
            // null을 '예약 없음'으로 단정하지 않는다.
            if (next != null) ...[
              _NextRunCard(next: next),
              const SizedBox(height: AppSpace.lg),
            ],
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('내 루틴')),
                ButtonSegment(value: true, label: Text('예시 루틴')),
              ],
              selected: {_templates},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _templates = v.first),
            ),
            const SizedBox(height: AppSpace.md),
            // 사용 기록으로 만든 루틴 초안(2026-10-14) — 조용히: 이 탭에만, 실행 중에는 감춘다(작업 도중 끼어들지 않는다).
            if (!_templates && !executing)
              for (final c in ref.watch(routineCandidatesProvider).valueOrNull ?? const <RoutineCandidate>[])
                _CandidateCard(
                  candidate: c,
                  onSave: () => _saveCandidate(context, c),
                  onDecline: () => _declineCandidate(c),
                ),
            // 자동 실행 허용 규칙(2026-10-13) — 카드에서 허용한 것만 있다. 없으면(옛 서버 포함) 아무것도 안 보인다.
            // 규칙이 있으면 머리말로 루틴 목록과 나눈다 — 같은 이름(시각 루틴과 그 규칙)이 두 번 나와 헷갈렸다(외부 평가 10/16 3차).
            if (!_templates && rules.isNotEmpty) ...[
              const _SectionLabel('자동으로 하기'),
              for (final rule in rules)
                _AutoRuleRow(rule: rule, onChanged: () => ref.invalidate(autoRulesProvider)),
              const SizedBox(height: AppSpace.sm),
              const _SectionLabel('내 루틴 목록'),
            ],
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
                      _Note(_templates
                          ? '지금 보여 드릴 예시 루틴이 없어요.'
                          : '아직 만든 루틴이 없어요. 가전 화면의 "누르는 순서 저장"이나 예시 루틴으로 만들어 보세요.'),
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
                          onEdit: () => _open(context, r),
                          // 버튼 자리를 맞추지 않은 가전의 루틴은 실행하기 대신 이유(외부 평가 10/16 3차).
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
                          // 설정 안내는 오류가 아니다 — 앰버(홈과 같은 색, UI 평가 10/17).
                          note: r.applianceIds.any(needsSetup.contains)
                              ? '가전 설정이 필요해요. 홈의 가전을 눌러 버튼 자리를 맞춰 주세요'
                              : null,
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
      padding: const EdgeInsets.all(AppSpace.lg),
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
              fontSize: AppFont.tabTitle,
              fontWeight: FontWeight.w700,
              color: context.appPrimary,
            ),
          ),
          const SizedBox(width: AppSpace.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('다음: ${n.name}',
                    style: const TextStyle(
                        fontSize: AppFont.caption, fontWeight: FontWeight.w700)),
                // 오늘·내일이 먼저, 실행 방식은 끝 — 아래 '자동 실행 켜짐' 줄과 같은 말(외부 평가 10/16 p02).
                Text(
                    [
                      if (n.dayLabel.isNotEmpty) n.dayLabel,
                      if (n.when.isNotEmpty) n.when,
                      n.modeLabel,
                    ].join(' · '),
                    style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
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
    // 직접 실행 루틴은 '언제'를 적지 않는다 — "직접 실행할 때"는 모든 루틴이 그렇다(2026-10-14 UX).
    // 서버 `when` 문장으로 가른다(목록의 루틴은 trigger 없이 when만 올 수 있다).
    if (when != const RoutineTrigger.manual().describe()) when,
    // 루틴 단계 수(실행 화면의 조작 진행과 다른 축). 숫자와 '단계'가 큰 글씨에서 다른 줄로
    // 떨어지지 않게 단어 결합 문자(U+2060)로 붙인다(외부 평가 2026-10-13 L3).
    if (targets.isNotEmpty) '${targets.join(', ')} 할 일 ${r.steps.length}\u2060개',
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
    this.note,
    this.onSetup,
  });

  /// 설정이 필요한 가전의 상세로 — 있으면 '설정하기' 단추(홈과 같다).
  final VoidCallback? onSetup;

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

  /// 오류가 아닌 안내(앰버) — 설정이 필요한 가전 등.
  final String? note;

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
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Row(
            children: [
              Icon(
                AppIcons.routine,
                color: r.enabled ? context.appPrimary : context.appMuted,
              ),
              const SizedBox(width: AppSpace.md),
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
                      style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
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
    // 예시 루틴은 낭독에서도 예시라고 말하고, 누르면 무엇이 되는지 말한다(2026-10-14 UI 정리).
    if (r.isTemplate) {
      final about = (r.description ?? '').isNotEmpty ? '${r.description}. ' : '';
      return Semantics(
        label: '예시 루틴 ${r.name}. $about고쳐서 저장하면 내 루틴이 돼요',
        button: true,
        container: true,
        excludeSemantics: true,
        onTap: onEdit,
        child: info,
      );
    }

    final run = onRun;
    // 큰 글씨에서는 Wrap이 버튼을 다음 줄로 내린다 — 겹치거나 줄어들지 않는다.
    final actions = Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
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
        if (onSetup case final setup?)
          Semantics(
            label: '${r.name} 가전 설정하기',
            container: true,
            button: true,
            excludeSemantics: true,
            child: OutlinedButton(
              key: Key('routine-setup-$key'),
              onPressed: setup,
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(112, 48), foregroundColor: context.appWarning),
              child: const Text('설정하기'),
            ),
          ),
        if (run != null)
          Semantics(
            label: '${r.name} 실행하기',
            container: true,
            button: true,
            enabled: !busy,
            excludeSemantics: true,
            // 홈 목록과 같은 테두리 버튼 — 줄마다 채운 버튼이면 주 행동이 너무 많아 위계가 흐려졌다(UI 평가 3차 10/17).
            child: OutlinedButton(
              key: Key('routine-run-$key'),
              onPressed: busy ? null : run,
              style: OutlinedButton.styleFrom(minimumSize: const Size(112, 48)),
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
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          info,
          Padding(
            padding: const EdgeInsets.only(left: AppSpace.xxxl),
            child: actions,
          ),
          if (note case final message?) ...[
            const SizedBox(height: AppSpace.sm),
            Padding(
              padding: const EdgeInsets.only(left: AppSpace.xxxl),
              child: Text(keepWordsTogether(message),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
            ),
          ],
          if (error case final message?) ...[
            const SizedBox(height: AppSpace.sm),
            Padding(
              padding: const EdgeInsets.only(left: AppSpace.xxxl),
              // 어절 단위로 줄을 바꾼다('자리/를' 방지, UI 평가 10/17).
              child: Text(keepWordsTogether(message),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
            ),
          ],
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('이 자동으로 하기를 지울까요?'),
        content: Text('${widget.rule.conditionText} → ${widget.rule.actionText}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('지우기')),
        ],
      ),
    );
    if (ok == true) await api.deleteAutoRule(widget.rule.id);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rule;
    final reason = r.disabledReason;
    final quietNote = quietRuleNote(ref.watch(quietHoursProvider).valueOrNull, r);
    return Padding(
      key: Key('auto-rule-${r.id}'),
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.auto, color: r.enabled ? context.appPrimary : context.appMuted),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(r.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: AppSpace.xxxl, top: AppSpace.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 규칙을 한 문장으로(2026-10-14 UX) — "조건:/동작:" 표 대신.
                Text('${r.conditionText} → ${r.actionText}',
                    style: const TextStyle(fontSize: AppFont.caption)),
                const SizedBox(height: AppSpace.xs),
                Text(
                  r.statusLabel,
                  style: TextStyle(
                    fontSize: AppFont.caption,
                    fontWeight: FontWeight.w700,
                    color: r.enabled ? context.appPrimary : context.appMuted,
                  ),
                ),
                if (!r.enabled && reason != null && reason.isNotEmpty)
                  Text(reason, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                // 조용한 시간과 겹치면 여기서도 말한다 — 켜져 있으면 앰버(실제로 건너뜀), 꺼져 있으면 회색(UI 평가 7차 10/17).
                if (quietNote != null)
                  Text(keepWordsTogether(quietNote),
                      semanticsLabel: quietNote,
                      style: TextStyle(
                          fontSize: AppFont.caption,
                          fontWeight: FontWeight.w600,
                          color: ref.watch(quietHoursProvider).valueOrNull?.enabled == true
                              ? context.appWarning
                              : context.appMuted)),
                // 마지막 자동 실행의 장치별 결과 — 서버 문장 그대로(확인된 것만 '바꿨어요').
                for (final n in r.lastRunNotices)
                  Text(n, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    if (r.enabled)
                      OutlinedButton(
                        key: Key('auto-rule-off-${r.id}'),
                        onPressed: _busy
                            ? null
                            : () => _run((api) => api.setAutoRuleEnabled(r.id, false)),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48)),
                        child: const Text('자동으로 하지 않기'),
                      )
                    else
                      FilledButton(
                        key: Key('auto-rule-on-${r.id}'),
                        onPressed: _busy ? null : () => _run((api) => _reallow(api, r)),
                        style: FilledButton.styleFrom(minimumSize: const Size(88, 48)),
                        child: const Text('다시 허락'),
                      ),
                    if (r.allowedValues.length > 1)
                      OutlinedButton(
                        key: Key('auto-rule-edit-${r.id}'),
                        onPressed: _busy ? null : () => _run(_changeValue),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48)),
                        child: Text(autoRuleValueLabel(r)),
                      ),
                    // 테두리 있는 버튼 — 글자만 있으면 누를 곳으로 보이지 않는다(외부 평가 10/16 p02).
                    OutlinedButton(
                      key: Key('auto-rule-delete-${r.id}'),
                      onPressed: _busy ? null : () => _run(_delete),
                      style: OutlinedButton.styleFrom(
                          minimumSize: const Size(64, 48),
                          foregroundColor: context.appDanger),
                      child: const Text('지우기'),
                    ),
                  ],
                ),
              ],
            ),
          ),
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
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: Text(text, style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
      );
}

/// 루틴 탭 구획 머리말(2026-10-16).
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.xs),
        child: Semantics(
          header: true,
          child: Text(text, style: AppText.title),
        ),
      );
}

/// 규칙 값 바꾸기 단추 이름 — 무엇의 값인지 말한다(UI 평가 3차 10/17: '세기'는 무엇의 세기인지 몰랐다).
String autoRuleValueLabel(AutoRule rule) =>
    rule.actionText.contains('풍량') ? '바람 세기 바꾸기' : '설정 바꾸기';
