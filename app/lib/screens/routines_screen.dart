import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/auto_rule.dart';
import '../models/clock_text.dart';
import '../models/execution_status.dart';
import '../models/routine.dart';
import '../models/routine_candidate.dart';
import '../providers/appliance_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/routine_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/server_appliance_provider.dart';
import '../services/rpi_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../models/display_status.dart';
import '../models/line_break.dart';
import '../models/quiet_hours.dart';
import '../theme/app_text.dart';
import '../widgets/auto_rule_confirm_sheet.dart';
import '../widgets/routine_candidate_sheet.dart';
import '../widgets/routine_confirm_sheet.dart' show routineRunPlan;
import '../widgets/routine_icon.dart';
import '../widgets/routine_run.dart';
import '../widgets/row_menu.dart';
import '../widgets/skip_next_control.dart';
import '../widgets/status_badge.dart';
import '../widgets/settings_action.dart';
import '../widgets/notification_action.dart';
import '../theme/app_tokens.dart';

// 오전/오후 시각 꼴은 clock_text 한 곳(평가 8차 10/18) — 홈·시험이 이 파일에서 가져가던 이름을 그대로 내보낸다.
export '../models/clock_text.dart' show ampmClock, withAmPm;

part 'routines/automatic_actions.dart';
part 'routines/candidate_card.dart';
part 'routines/routine_labels.dart';
part 'routines/touch_controls.dart';
part 'routines/status_mark.dart';
part 'routines/routine_row.dart';
part 'routines/auto_rule_row.dart';
part 'routines/rule_labels.dart';
part 'routines/new_action_sheet.dart';

/// 루틴 탭 — 세그먼트 [내 루틴 | 자동 규칙](UI 개편안 §4, 2026-10-18).
///
/// 내 루틴: 표지 뜻 한 줄 · 사용 기록으로 만든 초안 · 루틴 줄(가전 아이콘 · 이름 · 오른쪽 스위치(정해진 시각)와 >, 이름 아래
/// '지금 하기'(먼저 묻는다) 작은 단추, 줄을 누르면 고치기·지우기 — '고치기' 단추는 없다, 결선 모의 평가 10/18). 다음에 할 줄에는 '다음' 배지.
/// 시각 루틴에 붙은 자동 규칙은 그 루틴 줄의 '자동'(꺼져 있으면 '자동 꺼짐')을 누르면 스위치가 나온다.
/// 자동 규칙: 루틴이 아닌 규칙 카드(가전 알림으로 하는 일 — 예: 전자레인지가 멈추면 공기청정기 세게), 스위치·최근 결과.
///
/// 평가 14차(10/18): 같은 시각 루틴이 두 탭에 다른 조작으로 따로 나왔다 → 한 곳(루틴 줄)에서. 루틴에 닿지 않는 시각
/// 규칙(루틴을 지웠거나 이름이 바뀐 것)은 탭에 그대로 둔다 — 자동 실행을 끄는 길은 늘 한 군데 이상 있다.
///
/// 예시 루틴은 미리 만든 **템플릿**이다(개인 습관 추천이 아니다) — [+ 새 루틴] 안의 선택지로 둔다.
/// 눌러서 자기 가전·버튼으로 고친 뒤 저장해야 루틴이 된다.
///
/// 줄의 '실행'은 편집기의 '지금 실행'과 같은 경로로 **승인 카드만 만든다** — 가전은 승인 화면에서
/// 최종 허락해야 움직인다.
class RoutinesScreen extends ConsumerStatefulWidget {
  const RoutinesScreen({super.key, this.automatic = false});
  final bool automatic;

  @override
  ConsumerState<RoutinesScreen> createState() => _RoutinesScreenState();
}

class _RoutinesScreenState extends ConsumerState<RoutinesScreen> {
  /// 0 = 내 루틴, 1 = 자동 규칙.
  int _segment = 0;

  /// 카드 요청 중인 루틴(한 번에 하나). 중복 탭·다른 행 동시 실행을 막는다.
  String? _runningId;

  /// 행별 실행 실패 문장.
  final Map<String, String> _errors = {};

  @override
  Widget build(BuildContext context) {
    if (widget.automatic) return _automaticActions(context);
    final next = ref.watch(nextRoutineProvider).valueOrNull;
    final autoIds = ref.watch(autoRoutineIdsProvider).valueOrNull ?? const <String>{};
    final rules = ref.watch(autoRulesProvider).valueOrNull ?? const <AutoRule>[];
    final needsSetup = {
      for (final a in ref.watch(installedAppliancesProvider))
        if (needsPanelMapping(a)) a.id,
    };
    final list = ref.watch(routinesProvider);
    // 루틴에 닿는 시각 규칙은 그 루틴 줄에서 — 탭에는 나머지만(평가 14차 10/18).
    final standalone = standaloneAutoRules(rules, list.valueOrNull ?? const <Routine>[]);
    final installed = ref.watch(installedAppliancesProvider);
    final names = {for (final a in installed) a.id: a.name};
    final icons = {for (final a in installed) a.id: a.category};
    // 대상 가전을 지금은 쓸 수 없는 루틴 — 홈 카드·확인 시트와 같은 판정([routineRunPlan]).
    final readinessOf = ref.watch(serverApplianceCatalogProvider).readinessFor;
    bool blockedNow(Routine r) => routineRunPlan(r, installed, readinessOf: readinessOf).blocked != null;
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
            // 화면 좌우 여백 토큰(본문 [AppSpace.xl])과 같게(출시 검토 10/18 — 화면 끝에 붙어 보였다).
            padding: const EdgeInsets.only(right: AppSpace.xl),
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
          ref.invalidate(autoRoutineIdsProvider);
          ref.invalidate(autoRulesProvider);
          ref.invalidate(routineCandidatesProvider);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.xs, AppSpace.xl, AppSpace.xxxl),
          children: [
            SegmentedButton<int>(
              segments: [
                // 큰 글씨에서도 한 줄 — 두 줄로 꺾이면 탭 위아래가 잘렸다(평가 8차 10/18). 칸보다 길 때만 그만큼 줄인다.
                ButtonSegment(value: 0, label: _SegmentLabel('내 루틴', selected: _segment == 0)),
                // 평가 14차(10/18): 폰 '자동으로 해요'·'자동'·'자동으로 하기'가 섞였다 — 표시는 '자동', 이 탭은 루틴이 아닌
                // 규칙만 둔다. 이름은 '자동으로 하기'(문구 기준 R9 10/19 — '자동 규칙'·'자동 루틴'을 하나로).
                ButtonSegment(value: 1, label: _SegmentLabel('자동으로 하기', selected: _segment == 1)),
              ],
              selected: {_segment},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _segment = v.first),
            ),
            const SizedBox(height: AppSpace.lg),
            if (_segment == 1)
              ...(standalone.isEmpty
                  ? [
                      _Note(rules.isEmpty
                          // 언제 묻는지와 무엇만 되는지를 함께(첫 사용자 검토 10/19 — '할까요? 카드'로는 길을 찾지 못했다).
                          // 버튼 누르기는 본체가 자동 규칙으로 받지 않는다.
                          ? '아직 "자동으로 하기"가 없어요. "할까요?" 하고 물어볼 때 "다음부터도 자동으로"를 고르면 생겨요. '
                              'LG 가전 일만 이렇게 할 수 있어요.'
                          // 시각 루틴 규칙만 있으면 어디서 끄는지 말한다(끄는 길을 잃지 않게).
                          : "정해진 시각 루틴은 '내 루틴'에서 '자동'을 눌러 켜고 꺼요."),
                    ]
                  : [
                      // 낱말 중간에서 꺾이지 않게(평가 10차 10/18). 평가 14차(10/18): '~이에요. ~않아요.'가 잇달아 단조로웠다 →
                      // 짧은 명사구 + 한 문장.
                      // 평가 15차(10/18): '묻지 않고 하도록 허락한 일.'은 번역투 명사문이었다 → 쉬운 말 한 문장 + 짧은 안내.
                      // 평가 17차(10/18): '~해요. ~꺼요' 토막 두 마디 → 자연스러운 한 문장(끄는 방법이 문장 안에).
                      const _Note("허용한 조건에 맞으면 묻지 않고 실행해요. 정해진 시각의 루틴은 '내 루틴'에서 바꿔요.",
                          key: Key('auto-rules-intro'), textKey: Key('auto-rules-intro-text')),
                      // 평가 15차(10/18): 그림자 진 흰 카드 한 장이 '내 루틴'의 면 없는 목록과 문법이 달랐다 → 같은 면 없는 줄,
                      // 줄 사이는 옅은 구분선.
                      for (final (i, rule) in standalone.indexed) ...[
                        if (i > 0) Divider(height: 1, color: context.appBorderFaint),
                        _AutoRuleRow(rule: rule, onChanged: _ruleChanged),
                      ],
                    ])
            else ...[
              // 위 '다음: …' 한 줄은 두지 않는다 — 다음에 할 루틴 줄에 '다음' 배지(평가 6차 10/18: 같은 말이 위아래 두 번).
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
                        // 표지 뜻 한 줄(결선 모의 평가 10/18 — '다음'·'자동' 표지가 무슨 뜻인지 몰랐다).
                        // 줄의 표지와 같은 모양으로 보여 주고 그 옆에 뜻(위 '다음: …' 루틴 이름 줄과 헷갈리지 않게, 평가 6차 10/18).
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpace.sm),
                          child: Semantics(
                            key: const Key('routines-mark-legend'),
                            container: true,
                            label: kRoutineMarkLegend,
                            excludeSemantics: true,
                            child: Wrap(
                              spacing: AppSpace.md,
                              runSpacing: AppSpace.xs,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (final (mark, meaning, accent) in kRoutineMarkMeanings)
                                  Row(mainAxisSize: MainAxisSize.min, children: [
                                    // 줄의 표지와 같은 모양 — 자동은 면 + 번개.
                                    _LineMark(
                                        label: mark, accent: accent, filled: accent, icon: accent ? Icons.bolt : null),
                                    const SizedBox(width: AppSpace.xs),
                                    // 큰 글씨(200%)에서는 뜻이 줄을 바꾼다(넘치지 않게).
                                    Flexible(
                                      child: Text(keepWordsTogether(meaning),
                                          style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                                    ),
                                  ]),
                              ],
                            ),
                          ),
                        ),
                        // 시간축 목록(평가 5차 10/18) — 정해진 시각(이른 순, 줄 왼쪽 큰 시각) · 필요할 때 · 이럴 때(가전 알림 등).
                        // 묶음 안에서는 설정이 필요한 가전의 루틴을 아래로 — 홈과 같은 순서(UI 평가 10/17).
                        for (final (groupKey, groupLabel, group) in _routineGroups(
                          [
                            ...routines.where((r) => !r.applianceIds.any(needsSetup.contains)),
                            ...routines.where((r) => r.applianceIds.any(needsSetup.contains)),
                          ],
                        )) ...[
                          _GroupHead(key: Key('routines-group-$groupKey'), label: groupLabel),
                          for (final r in group)
                          _RoutineRow(
                            routine: r,
                            applianceNames: names,
                            applianceIcons: icons,
                            // 편집·지우기는 줄을 눌러 들어가는 편집 화면 안(지우기 확인 대화 그대로) — 줄 끝 ⋮는 두지 않는다
                            // (평가 8차 10/18: ⋮ 자리만큼 이름이 좁아져 '아침 공기청정기 / 끄기'로 꺾였다).
                            onEdit: () => _open(context, r),
                            // 버튼 자리를 맞추지 않은 가전의 루틴은 실행 대신 이유(외부 평가 10/16 3차).
                            onRun: r.isRunCandidate && !r.applianceIds.any(needsSetup.contains)
                                ? () => _run(context, r)
                                : null,
                            // 정해진 시각 루틴은 줄에서 바로 끄고 켠다(보호자 과업 평가 10/18) — 자동 규칙이 붙었으면 그
                            // 규칙(켤 때는 확인 시트), 아니면 루틴 자체(서버 /routines/{id}/enable).
                            onToggle: routineClock(r) == null || r.id == null
                                ? null
                                : switch (routineAutoRule(r, rules)) {
                                    final rule? => (on) => _toggleRule(context, r, rule, on),
                                    null => (on) => _toggleRoutine(context, r, on),
                                  },
                            switchOn: routineAutoRule(r, rules)?.enabled ?? r.enabled,
                            switchLabel: routineAutoRule(r, rules) != null
                                ? '${r.name} 자동 실행 허용'
                                : '${r.name} 루틴 켜기',
                            toggling: r.id != null && _togglingId == r.id,
                            running: r.id != null && _runningId == r.id,
                            blocked: blockedNow(r),
                            next: next != null && r.id != null && next.routineId == r.id ? next : null,
                            auto: r.id != null && autoIds.contains(r.id),
                            autoRule: routineAutoRule(r, rules),
                            onAuto: switch (routineAutoRule(r, rules)) {
                              final rule? => () => _openAutoRule(context, rule.id),
                              null => null,
                            },
                            busy: _runningId != null,
                            error: r.id == null ? null : _errors[r.id],
                            onSetup: r.applianceIds.any(needsSetup.contains)
                                ? () => context.push('/appliance/detail/'
                                    '${r.applianceIds.firstWhere(needsSetup.contains)}')
                                : null,
                            // 이유 문장은 두지 않는다 — '설정하기 >' 단추가 말하고, 무엇이 남았는지는 홈의
                            // '확인이 필요해요' 한 곳에서 말한다(평가 3차 10/18: 행마다 두 줄 경고).
                          ),
                        ],
                      ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 자동 규칙을 바꾼 뒤 — 규칙 목록과, 루틴 줄·홈의 '자동' 표시 근거(/routines/next)를 다시 받는다.
  void _ruleChanged() {
    ref.invalidate(automationRulesProvider);
    ref.invalidate(autoRulesProvider);
    ref.invalidate(autoRoutineIdsProvider);
    ref.invalidate(nextRoutineProvider);
  }

  /// 루틴 줄 '자동'을 누르면 — 그 루틴에 붙은 규칙의 스위치·지우기(평가 14차 10/18). 끌 때는 바로, 켤 때는 확인 시트.
  Future<void> _openAutoRule(BuildContext context, String ruleId) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => Consumer(
        builder: (context, ref, _) {
          final rule = (ref.watch(autoRulesProvider).valueOrNull ?? const <AutoRule>[])
              .where((r) => r.id == ruleId)
              .firstOrNull;
          return Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.xl, 0, AppSpace.xl, AppSpace.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('자동으로 하기', style: AppText.title),
                const SizedBox(height: AppSpace.xs),
                Text(keepWordsTogether('켜 두면 정해진 시각에 묻지 않고 해요.'),
                    style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
                const SizedBox(height: AppSpace.md),
                if (rule == null)
                  const _Note('이 규칙을 찾지 못했어요. 아래로 당겨 새로 봐 주세요.')
                else
                  _AutoRuleRow(rule: rule, onChanged: _ruleChanged),
              ],
            ),
          );
        },
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

  Future<void> _run(BuildContext context, Routine r) async {
    final id = r.id;
    if (id == null || _runningId != null) return; // 누르는 중 — 두 번째 탭은 버린다
    try {
      // 먼저 무엇을 하는지 묻는다(휴리스틱 평가 10/18) — 고르면 예전과 같은 승인 카드 경로.
      final error = await confirmAndRunRoutine(context, ref, r, onConfirmed: () {
        if (!mounted) return;
        setState(() {
          _runningId = id;
          _errors.remove(id);
        });
      });
      if (mounted && error != null) setState(() => _errors[id] = error);
    } finally {
      if (mounted) setState(() => _runningId = null);
    }
  }

  /// 스위치를 바꾸는 중인 루틴(한 번에 하나).
  String? _togglingId;

  void _say(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// 규칙이 붙은 시각 루틴의 스위치 — 끄면 바로, 켜면 확인 시트([setAutoRuleSwitch]). 끈 뒤에는 때가 되면 물어본다
  /// (자동 실행을 못 하면 본체는 카드로 묻는다 — 루틴 엔진 `_auto_time`).
  Future<void> _toggleRule(BuildContext context, Routine r, AutoRule rule, bool on) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null || _togglingId != null) return;
    setState(() => _togglingId = r.id);
    try {
      final done = await setAutoRuleSwitch(context, api, rule, on);
      if (done && context.mounted) {
        _say(context, on ? "'${r.name}' 자동 실행을 허용했어요" : "'${r.name}' 자동 실행 허용을 껐어요. 때가 되면 물어볼게요");
      }
    } on RpiApiException catch (e) {
      if (context.mounted) _say(context, e.message.isNotEmpty ? e.message : '바꾸지 못했어요. 연결을 봐 주세요.');
    } catch (_) {
      if (context.mounted) _say(context, '바꾸지 못했어요. 연결을 봐 주세요.');
    } finally {
      if (mounted) setState(() => _togglingId = null);
      _ruleChanged();
    }
  }

  /// 규칙이 없는 시각 루틴의 스위치 — 루틴 자체를 끄고 켠다(편집기 '루틴 켜기'와 같은 값, 서버 /routines/{id}/enable).
  Future<void> _toggleRoutine(BuildContext context, Routine r, bool on) async {
    final api = ref.read(rpiApiServiceProvider);
    final id = r.id;
    if (api == null || id == null || _togglingId != null) return;
    setState(() => _togglingId = id);
    try {
      await api.setRoutineEnabled(id, on);
      if (context.mounted) {
        _say(context, on ? "'${r.name}' 루틴을 켰어요" : "'${r.name}' 루틴을 껐어요. 때가 되어도 하지 않아요");
      }
    } on RpiApiException catch (e) {
      if (context.mounted) _say(context, e.message.isNotEmpty ? e.message : '바꾸지 못했어요. 연결을 봐 주세요.');
    } catch (_) {
      if (context.mounted) _say(context, '바꾸지 못했어요. 연결을 봐 주세요.');
    } finally {
      if (mounted) setState(() => _togglingId = null);
      ref.invalidate(routinesProvider);
      ref.invalidate(nextRoutineProvider);
      ref.invalidate(autoRoutineIdsProvider);
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
    ref.invalidate(autoRoutineIdsProvider);
  }
}

/// 사용 기록으로 만든 루틴 초안 한 장 — 가전·버튼 순서와 근거(가전 사용 기록 문장), [루틴으로 저장] [괜찮아요].
///
/// 개인 습관으로 단정하지 않는다(누가 썼는지 모른다). '추천'이라 부르지 않는다(예시 루틴과 구분).
