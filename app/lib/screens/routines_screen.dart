import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/auto_rule.dart';
import '../models/routine.dart';
import '../providers/appliance_provider.dart';
import '../providers/routine_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/auto_rule_confirm_sheet.dart';
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
          ref.invalidate(autoRulesProvider);
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
            // 자동 실행 허용 규칙(2026-10-13) — 카드에서 허용한 것만 있다. 없으면(옛 서버 포함) 아무것도 안 보인다.
            if (!_templates)
              for (final rule in ref.watch(autoRulesProvider).valueOrNull ?? const <AutoRule>[])
                _AutoRuleRow(rule: rule, onChanged: () => ref.invalidate(autoRulesProvider)),
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
    // 직접 실행 루틴은 '언제'를 적지 않는다 — "직접 실행할 때"는 모든 루틴이 그렇다(2026-10-14 UX).
    // 서버 `when` 문장으로 가른다(목록의 루틴은 trigger 없이 when만 올 수 있다).
    if (when != const RoutineTrigger.manual().describe()) when,
    // 루틴 단계 수(실행 화면의 조작 진행과 다른 축). 숫자와 '단계'가 큰 글씨에서 다른 줄로
    // 떨어지지 않게 단어 결합 문자(U+2060)로 붙인다(외부 평가 2026-10-13 L3).
    if (targets.isNotEmpty) '${targets.join('·')} ${r.steps.length}\u2060단계',
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
      _say(e.message.isNotEmpty ? e.message : '바꾸지 못했어요. 연결을 확인해 주세요.');
    } catch (_) {
      _say('바꾸지 못했어요. 연결을 확인해 주세요.');
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
      _say('대상 가전을 찾지 못해 켤 수 없어요 — 가전 연결을 확인해 주세요');
      return;
    }
    final ok = await showAutoRuleConfirmSheet(
      context,
      conditionText: rule.conditionText,
      actionText: rule.actionText,
      title: '다음부터 자동으로 실행할까요?',
      confirmLabel: '허용',
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
        title: const Text('세기 바꾸기'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('바꾸면 다시 허용해야 자동 실행이 켜져요.',
                style: TextStyle(fontSize: 15, color: dialogContext.appMuted)),
          ),
          for (final (v, label) in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, v),
              child: Text(label, style: const TextStyle(fontSize: 18)),
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
        title: const Text('자동 실행 규칙을 지울까요?'),
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
    return Padding(
      key: Key('auto-rule-${r.id}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.autorenew_rounded, color: r.enabled ? context.appPrimary : context.appMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(r.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 36, top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 규칙을 한 문장으로(2026-10-14 UX) — "조건:/동작:" 표 대신.
                Text('${r.conditionText} → ${r.actionText}',
                    style: const TextStyle(fontSize: 15)),
                const SizedBox(height: 4),
                Text(
                  r.statusLabel,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: r.enabled ? context.appPrimary : context.appMuted,
                  ),
                ),
                if (!r.enabled && reason != null && reason.isNotEmpty)
                  Text(reason, style: TextStyle(fontSize: 14, color: context.appMuted)),
                // 마지막 자동 실행의 장치별 결과 — 서버 문장 그대로(확인된 것만 '바꿨어요').
                for (final n in r.lastRunNotices)
                  Text(n, style: TextStyle(fontSize: 14, color: context.appMuted)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (r.enabled)
                      OutlinedButton(
                        key: Key('auto-rule-off-${r.id}'),
                        onPressed: _busy
                            ? null
                            : () => _run((api) => api.setAutoRuleEnabled(r.id, false)),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48)),
                        child: const Text('자동 실행 끄기'),
                      )
                    else
                      FilledButton(
                        key: Key('auto-rule-on-${r.id}'),
                        onPressed: _busy ? null : () => _run((api) => _reallow(api, r)),
                        style: FilledButton.styleFrom(minimumSize: const Size(88, 48)),
                        child: const Text('다시 허용'),
                      ),
                    if (r.allowedValues.length > 1)
                      OutlinedButton(
                        key: Key('auto-rule-edit-${r.id}'),
                        onPressed: _busy ? null : () => _run(_changeValue),
                        style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48)),
                        child: const Text('세기 바꾸기'),
                      ),
                    TextButton(
                      key: Key('auto-rule-delete-${r.id}'),
                      onPressed: _busy ? null : () => _run(_delete),
                      style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
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
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text, style: TextStyle(fontSize: 15, color: context.appMuted)),
      );
}
