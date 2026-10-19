import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/auto_rule.dart';
import '../models/clock_text.dart';
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
import '../widgets/skip_next_control.dart';
import '../widgets/status_badge.dart';
import '../theme/app_tokens.dart';

// 오전/오후 시각 꼴은 clock_text 한 곳(평가 8차 10/18) — 홈·시험이 이 파일에서 가져가던 이름을 그대로 내보낸다.
export '../models/clock_text.dart' show ampmClock, withAmPm;

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
  const RoutinesScreen({super.key});

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
                      const _Note('스위치가 켜져 있는 동안은 묻지 않고 바로 해요',
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
                                ? '${r.name} 자동으로 하기'
                                : '${r.name} 루틴 켜기',
                            toggling: r.id != null && _togglingId == r.id,
                            running: r.id != null && _runningId == r.id,
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
        _say(context, on ? "'${r.name}' 자동으로 하기를 켰어요" : "'${r.name}' 자동으로 하기를 껐어요. 때가 되면 물어볼게요");
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
          Text('자주 하신 일로 만든 루틴(아직 저장 안 했어요)',
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

/// 루틴 한 줄의 부제 — 조건 한 줄(알려진 가전 알림은 사람 말로) · 무엇을 · 꺼짐.
/// '승인 후 실행'은 줄마다 되풀이하지 않는다(실행하기가 승인 카드로 간다).
///
/// 시각은 오전/오후 꼴('매일 오후 10:00', 평가 7차 10/18). [withClock]이 false면 정해진 시각 루틴의 '언제'를 통째로
/// 뺀다 — 루틴 목록은 이름 위 칩([routineWhenLabel])이 '매일 오전 7:00'을 따로 말한다.
///
/// [skipNamed]가 true면 이름이 이미 말하는 '무엇을' 조각은 뺀다(평가 8차 10/18: '아침 공기청정기 끄기' 아래
/// '공기청정기 끄기'가 같은 말을 되풀이했다). 루틴 목록 줄만 쓴다.
String routineSubtitle(Routine r, Map<String, String> applianceNames,
    {bool withClock = true, bool skipNamed = false}) {
  var when = withAmPm(_routineWhen(r, applianceNames));
  if (!withClock && routineClock(r) != null) when = '';
  String squash(String t) => t.replaceAll(RegExp(r'\s+'), '');
  final name = squash(r.name);
  return [
    // 직접 실행 루틴은 '언제'를 적지 않는다 — "직접 실행할 때"는 모든 루틴이 그렇다(2026-10-14 UX).
    // 서버 `when` 문장으로 가른다(목록의 루틴은 trigger 없이 when만 올 수 있다).
    if (when.isNotEmpty && when != const RoutineTrigger.manual().describe()) when,
    for (final part in routineDoParts(r, applianceNames))
      if (!skipNamed || !name.contains(squash(part))) part,
    // 알림만 루틴은 부제에 '알림만'을 적지 않는다 — 줄 오른쪽 '알려 드려요' 배지와 종 아이콘이 말한다(평가 4차 10/18).
    if (!r.enabled) '꺼짐',
  ].join(' · ');
}

/// 루틴 목록 줄의 이름 아래 한 줄 — '언제 · 무슨 가전'(평가 10차 10/18: 시각 줄은 시각이 이름 위에 있고 가전이
/// 없었고, 필요할 때 줄은 가전·버튼이 아래라 줄 모양이 섞였다).
///
/// - 언제: 정해진 시각이면 '매일 오전 7:00', 가전 알림이면 그 조건, 직접 실행이면 적지 않는다.
/// - 무슨 가전: 누르는 가전과 '누를 버튼 N개', LG 가전은 결과 말('공기청정기 바람 세게') — 이름이 이미 그 결과를
///   말하면(이름 '아침 공기청정기 끄기') 가전 이름만('공기청정기').
/// - 꺼진 루틴은 끝에 '꺼짐'.
String routineListLine(Routine r, Map<String, String> applianceNames) {
  String squash(String t) => t.replaceAll(RegExp(r'\s+'), '');
  final name = squash(r.name);
  final clock = routineClock(r);
  var when = clock != null
      ? (routineWhenLabel(r, applianceNames) ?? '')
      : withAmPm(_routineWhen(r, applianceNames));
  if (when == const RoutineTrigger.manual().describe()) when = '';
  final targets = <String>[];
  var presses = 0;
  final results = <String>[];
  for (final s in r.steps) {
    final target = routineApplianceName(applianceNames, s.applianceId);
    if (s.kind == RoutineStepKind.pressSequence) {
      if (!targets.contains(target)) targets.add(target);
      presses += s.buttons.length;
    }
    if (s.kind == RoutineStepKind.thinqCommand) {
      final phrase = thinqResultPhrase(target, s.action, s.args);
      final shown = name.contains(squash(phrase)) ? target : phrase;
      if (!results.contains(shown) && !targets.contains(shown)) results.add(shown);
    }
  }
  return [
    if (when.isNotEmpty) when,
    if (targets.isNotEmpty) targets.join(', '),
    if (presses > 0) '누를 버튼 $presses개',
    ...results,
    // 꺼 둔 루틴은 이름 옆 '꺼 둠' 표지가 말한다(보호자 과업 평가 10/18) — 설명 줄에 되풀이하지 않는다.
  ].join(' · ');
}

String _routineWhen(Routine r, Map<String, String> applianceNames) =>
    (r.trigger.kind == RoutineTriggerKind.event ? knownEventLabel(r.trigger.event) : null) ??
    r.when ??
    r.trigger.describe(applianceNames: applianceNames);

/// 정해진 시각 루틴의 '언제' 칩 — '매일 오전 7:00'. 시각이 없는 루틴은 null.
String? routineWhenLabel(Routine r, Map<String, String> applianceNames) {
  final clock = routineClock(r);
  if (clock == null) return null;
  final when = _routineWhen(r, applianceNames);
  return withAmPm(when.contains(clock) ? when : clock);
}

/// 루틴이 하는 일 — 누르는 가전과 '누를 버튼 N개', LG 가전은 결과 말('공기청정기 켜기').
///
/// 평가 5차(10/18): '버튼 2번'은 한 버튼을 두 번 누르는 것으로 읽혔고, 'LG 가전 설정 1번'은 무엇이 되는지 말하지 않았다.
List<String> routineDoParts(Routine r, Map<String, String> applianceNames) {
  final pressTargets = <String>[];
  var presses = 0;
  final results = <String>[];
  for (final s in r.steps) {
    final name = routineApplianceName(applianceNames, s.applianceId);
    if (s.kind == RoutineStepKind.pressSequence) {
      if (!pressTargets.contains(name)) pressTargets.add(name);
      presses += s.buttons.length;
    }
    if (s.kind == RoutineStepKind.thinqCommand) {
      results.add(thinqResultPhrase(name, s.action, s.args));
    }
  }
  return [
    if (pressTargets.isNotEmpty) pressTargets.join(', '),
    if (presses > 0) '누를 버튼 $presses개',
    ...results,
  ];
}

/// LG 가전 단계 하나 → 결과 말('공기청정기 켜기'·'공기청정기 바람 세게'). 모르는 동작·값은 지어내지 않고 '바꾸기'.
String thinqResultPhrase(String name, String? action, Map<String, dynamic> args) {
  switch (action) {
    case 'set_power':
      final v = '${args['power'] ?? ''}'.toUpperCase();
      if (v == 'POWER_ON' || v == 'ON') return '$name 켜기';
      if (v == 'POWER_OFF' || v == 'OFF') return '$name 끄기';
      return '$name 전원 바꾸기';
    case 'set_wind_strength':
      final word = switch ('${args['wind_strength'] ?? ''}'.toUpperCase()) {
        'HIGH' => '세게',
        'MID' => '중간으로',
        'LOW' => '약하게',
        'AUTO' => '자동으로',
        _ => null,
      };
      return word == null ? '$name 바람 세기 바꾸기' : '$name 바람 $word';
    case 'set_job_mode':
      return '$name 운전 방식 바꾸기';
  }
  return '$name 설정 바꾸기';
}

/// 루틴 탭 시간축 묶음 — (키, 머리 말, 루틴들). 빈 묶음은 뺀다. 정해진 시각 묶음은 이른 시각부터.
/// 머리에 아이콘을 두지 않는다(평가 14차 10/18: 시계·손·종 장식이 줄 아이콘과 겹쳤다).
List<(String, String, List<Routine>)> _routineGroups(List<Routine> routines) {
  final timed = [for (final r in routines) if (routineClock(r) != null) r];
  // 'H:MM'도 'HH:MM'과 같은 자리로 비교한다.
  String sortKey(Routine r) => routineClock(r)!.padLeft(5, '0');
  final ordered = [...timed]..sort((a, b) => sortKey(a).compareTo(sortKey(b)));
  final manual = [
    for (final r in routines)
      if (routineClock(r) == null && r.trigger.kind == RoutineTriggerKind.manual) r,
  ];
  final other = [
    for (final r in routines)
      if (routineClock(r) == null && r.trigger.kind != RoutineTriggerKind.manual) r,
  ];
  return [
    if (ordered.isNotEmpty) ('time', '정해진 시각', ordered),
    if (manual.isNotEmpty) ('manual', '필요할 때', manual),
    if (other.isNotEmpty) ('event', '이럴 때', other),
  ];
}

/// 정해진 시각 루틴의 'HH:MM'. 시각이 없는 루틴은 null.
String? routineClock(Routine r) {
  if (r.trigger.kind == RoutineTriggerKind.time && (r.trigger.time ?? '').isNotEmpty) {
    return r.trigger.time;
  }
  // 목록의 루틴은 trigger 없이 서버 `when`('매일 22:00')만 올 수 있다.
  if (r.trigger.kind == RoutineTriggerKind.manual) {
    final m = RegExp(r'\b(\d{1,2}:\d{2})\b').firstMatch(r.when ?? '');
    if (m != null) return m.group(1);
  }
  return null;
}

/// 시간축 목록의 묶음 머리 — 굵은 말만(구역 머리로 위계를 준다, 카드로 감싸지 않는다).
class _GroupHead extends StatelessWidget {
  const _GroupHead({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpace.xl, bottom: AppSpace.xs),
        child: Semantics(
          header: true,
          child: Text(keepWordsTogether(label),
              semanticsLabel: label,
              style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appMuted)),
        ),
      );
}

/// 설정이 남은 루틴 줄의 오른쪽 글자 — '지금 하기'와 같은 두 낱말 꼴(평가 15차 10/18: '지금 하기'·'설정하기' 띄어쓰기가
/// 어긋나 보였다. '설정 하기'는 맞춤법에 어긋나 '설정 열기' — 누르면 그 가전 설정 화면이 열린다).
const kSetupActionLabel = '설정 열기';

/// 루틴 목록 위 표지 뜻 한 줄(결선 모의 평가 10/18) — (표지, 뜻, 강조색인가). 줄의 '다음'·'자동' 표지와 같은 모양으로 그린다.
const kRoutineMarkMeanings = [
  ('다음', '다음에 할 루틴', false),
  ('자동', '묻지 않고 해요', true),
];

/// 표지 뜻 한 줄의 낭독.
const kRoutineMarkLegend = "'다음'은 곧 할 루틴, '자동'은 묻지 않고 하는 루틴이에요";

/// 스위치 옆 상태 글자(접근성 감사 10/18 — 켜짐·꺼짐을 색만으로 말하지 않는다).
const kSwitchOnText = '켜짐';
const kSwitchOffText = '꺼짐';

/// 스위치 + 바로 아래 '켜짐'/'꺼짐'(접근성 감사 10/18) — 내 루틴·자동 규칙 같은 모양. 아래에 두어 이름 칸 폭을 줄이지 않는다.
/// 읽는 이름은 바깥 Semantics(toggled)가 말한다.
class SwitchWithWord extends StatelessWidget {
  const SwitchWithWord({super.key, required this.on, required this.wordKey, required this.child});

  final bool on;
  final Key wordKey;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          Text(on ? kSwitchOnText : kSwitchOffText,
              key: wordKey,
              style: TextStyle(
                  fontSize: AppFont.caption,
                  height: 1.0,
                  fontWeight: FontWeight.w700,
                  color: on ? context.appInk : context.appMuted)),
        ],
      );
}

/// 손가락이 닿는 칸의 최소 크기(dp).
const double kMinTouch = 48;

/// 루틴 줄 오른쪽 글자 단추 — '지금 하기 >'와 '설정하기 >'가 같은 꼴(평가 11차 10/18: 글자 단추와 회색 '설정 필요' 칩이
/// 섞여 있었다). 홈 '내 루틴' 줄과 같은 글자 크기·굵기.
class RowTextAction extends StatelessWidget {
  const RowTextAction({
    super.key,
    this.actionKey,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.enabled = true,
    this.running = false,
  });

  /// 눌리는 InkWell의 키(시험이 눌림 여부를 본다).
  final Key? actionKey;
  final String label;
  final String semanticLabel;
  final VoidCallback onTap;
  final bool enabled;
  final bool running;

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticLabel,
        container: true,
        button: true,
        enabled: enabled,
        excludeSemantics: true,
        child: InkWell(
          key: actionKey,
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpace.sm),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (running)
                  const Padding(
                    padding: EdgeInsets.only(right: AppSpace.sm),
                    child: SizedBox(
                        width: AppSpace.lg, height: AppSpace.lg, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                Text(keepWordsTogether(label),
                    semanticsLabel: label,
                    style: TextStyle(
                        fontSize: AppFont.caption,
                        fontWeight: FontWeight.w700,
                        color: enabled ? context.appInk : context.appMuted)),
                Icon(Icons.chevron_right, size: AppSpace.xl, color: context.appMuted),
              ]),
            ),
          ),
        ),
      );
}

/// 루틴 이름 옆 작은 표지 — '다음'·'자동'·'알려 드려요'. 면 없이 얇은 테두리 글자(평가 17차 10/18: 설명 줄 끝에
/// ' · 다음 · 자동'으로 이어 붙이니 가운뎃점으로 시작하는 줄이 혼자 남고, 설명이 데이터 나열처럼 보였다).
/// 설명 줄은 '매일 오후 10:00 · 공기청정기'처럼 짧게 두고, 표지는 이름 옆(자리가 모자라면 이름 아래)에 둔다.
class _LineMark extends StatelessWidget {
  const _LineMark(
      {super.key,
      required this.label,
      this.semanticLabel,
      this.accent = false,
      this.muted = false,
      this.filled = false,
      this.icon,
      this.onTap});

  final String label;
  final String? semanticLabel;
  final bool accent;
  final bool muted;

  /// 옅은 면을 깐다 — 켜진 자동('묻지 않고 해요')만(UI 정리 10/19: 켜진 자동과 '오늘은 건너뛰어요'가 같은 테두리 글자라
  /// 색으로만 갈렸다). 모양(면·아이콘)으로도 가른다.
  final bool filled;

  /// 글자 앞 작은 아이콘 — 켜진 자동은 번개, 건너뛰는 회차는 빈 달력. 뜻은 글자가 말한다(아이콘은 읽지 않는다).
  final IconData? icon;

  /// 있으면 누를 수 있는 표지(루틴 줄 '자동' → 그 규칙 스위치). 보이는 크기는 작게 두고, 손가락이 닿는 칸은
  /// 줄 높이를 늘리지 않는 투명 확장 영역([TapSlop])으로 48dp를 준다(평가 17차: 48dp 칸을 설명 줄 높이로 주니
  /// 이름과 설명 사이가 벌어져 설명이 다음 줄에 붙어 보였다).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = muted ? context.appMuted : accent ? context.appPrimary : context.appInk;
    final text = Text(keepWordsTogether(label),
        semanticsLabel: semanticLabel ?? label,
        style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: color, height: 1.25));
    final glyph = icon;
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.16) : null,
        border: Border.all(color: color.withValues(alpha: filled ? 0.9 : 0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: glyph == null
          ? text
          : Row(mainAxisSize: MainAxisSize.min, children: [
              // 글자 배율을 따라 커진다 — 큰 글씨에서 아이콘만 작게 남지 않게.
              ExcludeSemantics(
                  child: Icon(glyph, size: MediaQuery.textScalerOf(context).scale(AppFont.caption), color: color)),
              const SizedBox(width: AppSpace.xs),
              Flexible(child: text),
            ]),
    );
    final tap = onTap;
    if (tap == null) return tag;
    return Semantics(
      button: true,
      child: InkWell(borderRadius: BorderRadius.circular(6), onTap: tap, child: tag),
    );
  }
}

/// 안쪽 [target]의 보이는 칸이 [minSize]보다 작으면, 그 둘레(가운데 맞춘 [minSize] 칸)를 눌러도 [target]이 눌린 것으로
/// 받는다 — 줄 높이·간격은 그대로(평가 17차 10/18, 루틴 줄 '자동' 표지). 이 위젯의 칸 밖은 받지 못하므로 줄 전체를 감싼다.
class TapSlop extends SingleChildRenderObjectWidget {
  const TapSlop({super.key, required this.target, this.minSize = kMinTouch, super.child});

  final GlobalKey target;
  final double minSize;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderTapSlop(target, minSize);

  @override
  void updateRenderObject(BuildContext context, RenderTapSlop renderObject) {
    renderObject
      ..target = target
      ..minSize = minSize;
  }
}

class RenderTapSlop extends RenderProxyBox {
  RenderTapSlop(this.target, this.minSize);

  GlobalKey target;
  double minSize;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final box = target.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize && child != null) {
      final topLeft = box.localToGlobal(Offset.zero, ancestor: this);
      final rect = topLeft & box.size;
      final slop = Rect.fromCenter(
          center: rect.center,
          width: rect.width < minSize ? minSize : rect.width,
          height: rect.height < minSize ? minSize : rect.height);
      if (!rect.contains(position) && slop.contains(position)) {
        final inside = Offset(position.dx.clamp(rect.left + 0.5, rect.right - 0.5).toDouble(),
            position.dy.clamp(rect.top + 0.5, rect.bottom - 0.5).toDouble());
        return child!.hitTest(result, position: inside);
      }
    }
    return super.hitTestChildren(result, position: position);
  }
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
    this.onSetup,
    this.next,
    this.auto = false,
    this.autoRule,
    this.onAuto,
    this.onToggle,
    this.switchOn = false,
    this.switchLabel = '',
    this.toggling = false,
  });

  /// 정해진 시각 루틴의 켜기·끄기(보호자 과업 평가 10/18). null이면 스위치를 두지 않는다.
  final ValueChanged<bool>? onToggle;

  /// 스위치의 지금 값 — 자동 규칙이 붙었으면 그 규칙의 켜짐, 아니면 루틴 켜짐.
  final bool switchOn;

  /// 스위치를 읽는 이름('○○ 자동으로 하기' / '○○ 루틴 켜기').
  final String switchLabel;

  /// 바꾸는 중 — 두 번 누르지 않게 잠근다.
  final bool toggling;

  /// 묻지 않고 하는 시각 루틴(본체 /routines/next의 auto) — 홈 '다음' 카드와 같은 '자동' 표시.
  final bool auto;

  /// 이 루틴에 붙은 시각 자동 규칙([routineAutoRule]). 있으면 '자동'/'자동 꺼짐' 표시가 그 규칙의 켜짐을 따르고, 누를 수 있다.
  final AutoRule? autoRule;

  /// '자동' 표시를 누르면 — 그 규칙 스위치(시트). null이면 누를 수 없다.
  final VoidCallback? onAuto;

  /// 이 루틴이 다음에 할 일이면 그 예약 — 줄에 '다음' 배지(조용한 시간이라 건너뛰면 그 말).
  final RoutineNextRun? next;

  /// 가전 id → 아이콘. 줄 아이콘을 대상 가전 아이콘으로(평가 3차 10/18).
  final Map<String, IconData> applianceIcons;

  /// 설정이 필요한 가전의 상세로 — 있으면 '실행' 대신 '설정하기' 단추(홈과 같다).
  final VoidCallback? onSetup;

  final Routine routine;
  final Map<String, String> applianceNames;

  /// 행 전체 탭 = 편집(상세). 지우기도 그 안(확인 대화를 한 번 더 받는다).
  final VoidCallback onEdit;

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
    // 큰 글씨에서는 단추를 이름 아래로 — 한 줄에 두면 이름이 한 글자씩 꺾인다.
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    // 오른쪽 '지금 하기 >'는 글씨가 보통일 때만 이름 옆에 — 글씨를 조금만 키워도 이름 칸이 좁아진다.
    final inline = MediaQuery.textScalerOf(context).scale(1) <= 1.15;
    // 한 줄 구성(평가 10차 10/18) — 모든 줄이 같은 꼴: 이름 → 그 아래 한 줄 '언제 · 무슨 가전' + 표시(다음·자동으로 해요·
    // 알려 드려요). 예전에는 시각 줄만 시각이 이름 위에 있고 가전이 없어, 줄마다 모양과 '지금 하기' 높이가 달랐다.
    // 예시 루틴은 설명 문장이 그 한 줄이다.
    final line = r.isTemplate
        ? ((r.description ?? '').isNotEmpty ? r.description! : routineSubtitle(r, applianceNames))
        : routineListLine(r, applianceNames);
    final n = next;
    // 표지(평가 17차 10/18) — 이름 옆 작은 테두리 글자. 설명 줄 끝에 ' · '로 잇지 않는다.
    final notify = !r.isTemplate && r.mode == RoutineMode.notify && r.enabled;
    // 자동 표지 — 규칙이 있으면 규칙 켜짐, 없으면 본체 /routines/next의 auto.
    final autoOn = autoRule?.enabled ?? auto;
    final skipping = (n?.quietSkip ?? false) || (n?.skipped ?? false);
    // 스위치가 이 루틴 자체의 켜짐을 말하나(붙은 자동 규칙이 없을 때).
    final offBySwitch = onToggle != null && autoRule == null;
    final autoKey = GlobalObjectKey(this);
    // '다음' — 위에 따로 '다음: …' 줄을 두지 않고 그 줄에 붙인다. 조용한 시간이라 건너뛰면 그 말로.
    final Widget? nextMark = n == null
        ? null
        : _LineMark(
            key: Key('routine-next-badge-$key'),
            // 한 번 건너뛴 회차(2026-10-18)는 본체 말 '오늘은 건너뛰어요'(modeText) — 바로 옆 '되돌리기'와 짝.
            label: skipping ? n.modeText : '다음',
            // 건너뛰는 회차는 흐린 테두리 + 빈 달력 — 켜진 자동(면 + 번개)과 모양으로 갈린다(UI 정리 10/19).
            icon: skipping ? Icons.event_busy : null,
            muted: skipping,
          );
    // 건너뛰는 회차 표지는 이름 옆이 아니라 아래 건너뛰기 줄에서 '되돌리기'와 한 줄(평가 10/19: 이름 옆 표지가
    // '오늘은 건너뛰어요'·'자동 꺼짐' 두 줄로 쌓이고, '되돌리기'는 '지금 하기' 아래 혼자 떨어져 무엇을 되돌리는지 몰랐다).
    final skipLine = skipping && !r.isTemplate;
    final badges = <Widget>[
      if (nextMark != null && !skipLine) nextMark,
      // 홈 '다음' 카드와 같은 '자동'. 규칙이 있으면 그 켜짐이 먼저 — 꺼 둔 규칙도 '자동 꺼짐'으로 이 줄에서 닿는다.
      if (!r.isTemplate && (autoRule != null || (auto && !(n?.quietSkip ?? false) && !(n?.skipped ?? false))))
        KeyedSubtree(
          key: Key('routine-auto-badge-$key'),
          child: _LineMark(
            key: autoKey,
            label: autoOn ? '자동' : '자동 꺼짐',
            semanticLabel: autoOn
                ? '자동 루틴${onAuto != null ? ', 눌러서 끄고 켜기' : ''}'
                : '자동 꺼짐${onAuto != null ? ', 눌러서 켜기' : ''}',
            accent: autoOn && !skipping,
            muted: !autoOn || skipping,
            filled: autoOn && !skipping,
            icon: autoOn && !skipping ? Icons.bolt : null,
            onTap: onAuto,
          ),
        ),
      // 알림만 루틴(평가 4차 10/18) — 가전을 움직이지 않는 줄이라는 뜻.
      if (notify) const _LineMark(label: '알려 드려요'),
      // 꺼 둔 루틴(보호자 과업 평가 10/18) — 스위치를 끈 뒤 줄에서도 보인다(설명 줄 끝 '꺼짐' 대신).
      // 이 줄 스위치가 루틴 자체를 켜고 끄면 스위치 아래 '꺼짐'이 같은 말을 한다 — 표지는 두지 않고 낭독만 남긴다(UI 정리 10/19).
      if (!r.isTemplate && !r.enabled && !offBySwitch)
        _LineMark(key: Key('routine-off-badge-$key'), label: '꺼짐', muted: true),
    ];
    final lineStyle = TextStyle(fontSize: AppFont.caption, color: context.appMuted);
    // '누를 버튼 2개'·'매일 오전 7:00' 같은 묶음 안에서 줄이 갈리지 않게(평가 4차 10/18). 낭독은 원문.
    final lineShown = r.isTemplate ? keepWordsTogether(line) : keepPhrasesTogether(line, wholeParts: !big);
    // 표지를 두지 않은 '꺼 둠'도 낭독은 한다.
    final offSpoken = !r.isTemplate && !r.enabled && offBySwitch ? ', 꺼짐' : '';
    final Widget? lineText = line.isEmpty
        ? null
        : Text(lineShown, key: Key('routine-line-$key'), semanticsLabel: '$line$offSpoken', style: lineStyle);
    // 이름은 최대 두 줄(평가 8차 10/18). 넘치면 줄임표 — 낭독은 이름 전체.
    final nameText = Text(keepWordsTogether(r.name),
        semanticsLabel: line.isEmpty ? '${r.name}$offSpoken' : r.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(fontWeight: FontWeight.w700));
    // 이름 + 표지 — 자리가 있으면 이름 옆, 모자라면 이름 아래 줄(큰 글씨). 표지끼리는 가운뎃점 없이 간격으로만.
    final Widget nameLine = badges.isEmpty
        ? nameText
        : Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              nameText,
              Wrap(
                key: Key('routine-marks-$key'),
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: badges,
              ),
            ],
          );
    // 홈 '내 루틴' 줄과 같은 촘촘한 틀(평가 17차 10/18): 이름 바로 아래 설명. 설명 칸에 높이를 따로 주지 않는다.
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        nameLine,
        if (lineText != null)
          Padding(
            key: Key('routine-line-box-$key'),
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: lineText,
          ),
      ],
    );
    // 아이콘은 회색 원 안에 — 강조색(갈색)은 주 행동에만 쓴다(평가 5차 10/18).
    // 큰 글씨에서는 원·아이콘도 글자 배율을 따라 커진다(평가 15차 10/18, 상한 있음 — [textScaledIcon]).
    final circle = textScaledIcon(context, AppSpace.xxxl + AppSpace.sm);
    final icon = Container(
      key: Key('routine-icon-box-$key'),
      width: circle,
      height: circle,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: context.appOverlayFaint, shape: BoxShape.circle),
      child: RoutineIcon(
          routine: r,
          iconOf: applianceIcons,
          size: textScaledIcon(context, AppSpace.xxl),
          color: r.enabled ? context.appInk : context.appMuted),
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

    // 휴리스틱·보호자 과업 평가(10/18): 오른쪽 '지금 하기 >'가 줄 이동처럼 보여 줄을 누르기 겁났고, 정해진 시각 루틴을
    // 끄는 길이 없었다. 그래서 — 줄 누르기는 **고치기**(오른쪽 > 와 '고치기' 단추가 말한다), '지금 하기'는 이름 아래 따로
    // 작은 단추(누르면 먼저 묻는다), 정해진 시각 루틴은 오른쪽에 켜기·끄기 스위치(자동 규칙이 붙었으면 그 규칙, 아니면 루틴).
    // 설정이 남은 루틴은 '지금 하기' 자리에 '설정 열기'. 가전은 여전히 승인 화면에서 허락해야 움직인다.
    final run = onRun;
    final setup = onSetup;
    final Widget? action = setup != null
        ? RowTextAction(
            actionKey: Key('routine-setup-$key'),
            label: kSetupActionLabel,
            semanticLabel: '${r.name} 가전 설정하기',
            onTap: setup,
          )
        : run != null
            ? Semantics(
                label: '${r.name} 지금 하기',
                button: true,
                enabled: !busy,
                excludeSemantics: true,
                child: OutlinedButton.icon(
                  key: Key('routine-run-$key'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(kMinTouch, kMinTouch),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                  ),
                  onPressed: busy ? null : run,
                  icon: running
                      ? const SizedBox(
                          width: AppSpace.lg, height: AppSpace.lg, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.play_arrow_rounded, size: AppSpace.xl, color: context.appInk),
                  label: Text(keepWordsTogether('지금 하기'),
                      style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appInk)),
                ),
              )
            : null;
    // '고치기' 단추는 두지 않는다(결선 모의 평가 10/18 — 줄마다 '지금 하기 / 고치기'가 같은 무게로 되풀이돼 위계가 평평했다).
    // 고치기는 줄 누르기 — 모든 줄 오른쪽 끝의 > 가 말한다(스위치가 있는 줄도). 낭독 이름은 줄이 '○○ 고치기'로 읽는다.
    // 정해진 시각 루틴의 켜기·끄기 — 줄 오른쪽(큰 글씨에서는 단추 줄 끝).
    final toggle = onToggle;
    final Widget? switchWidget = toggle == null
        ? null
        : Semantics(
            label: switchLabel,
            toggled: switchOn,
            excludeSemantics: true,
            // 켜짐·꺼짐을 색만으로 말하지 않는다 — 스위치 바로 아래 글자(접근성 감사 10/18). 옆에 두면 이름 칸이 좁아져 줄이 꺾였다.
            child: SwitchWithWord(
              on: switchOn,
              wordKey: Key('routine-switch-text-$key'),
              child: SizedBox(
                height: kMinTouch,
                child: Switch(
                  key: Key('routine-switch-$key'),
                  value: switchOn,
                  onChanged: toggling ? null : toggle,
                ),
              ),
            ),
          );
    // 왼쪽 열은 모든 줄이 같은 폭의 가전 아이콘(평가 6차 10/18).
    final leadWidth = circle + AppSpace.md;
    // 아이콘 · 이름과 설명 · 오른쪽(스위치, 없으면 고치기 >)이 같은 세로 가운데 — 홈 '내 루틴' 줄과 같은 틀.
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: leadWidth, child: Align(alignment: Alignment.centerLeft, child: icon)),
        Expanded(child: Semantics(container: true, child: text)),
        if (inline && switchWidget != null) ...[const SizedBox(width: AppSpace.xs), switchWidget],
        // > 는 줄 누르기(고치기)의 표시 — 큰 글씨에서 스위치가 아래 단추 줄로 내려간 줄은 이름 칸(두 줄)이 모자라 두지 않는다.
        if (inline || switchWidget == null) Icon(Icons.chevron_right, color: context.appMuted),
      ],
    );
    final actions = [
      if (action != null) action,
      if (!inline && switchWidget != null) switchWidget,
    ];
    return Padding(
      key: Key('routine-row-$key'),
      padding: const EdgeInsets.only(bottom: AppSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: '${r.name} 고치기',
            button: true,
            child: InkWell(
              // 행 전체를 누르면 고치기(편집). '지금 하기'·스위치는 제 몫을 먼저 받는다.
              key: Key('routine-$key'),
              borderRadius: BorderRadius.circular(12),
              onTap: onEdit,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                  // '자동' 표지의 48dp 손가락 칸 — 줄 높이를 늘리지 않는 투명 확장 영역.
                  child: TapSlop(target: autoKey, child: head),
                ),
              ),
            ),
          ),
          // 건너뛰는 회차 — 표지와 그 '되돌리기'를 한 줄에(평가 10/19). '지금 하기'보다 먼저(상태 → 행동).
          if (skipLine && nextMark != null)
            Padding(
              key: Key('routine-skip-line-$key'),
              padding: EdgeInsets.only(left: leadWidth, bottom: AppSpace.xs),
              child: Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  nextMark,
                  if (n != null && n.canSkip) SkipNextControl(next: n),
                ],
              ),
            ),
          // 단추 줄 — 이름 첫 글자와 같은 세로줄. 단추가 없으면(알림만 루틴 등) 두지 않는다.
          if (actions.isNotEmpty)
            Padding(
              key: Key('routine-action-box-$key'),
              padding: EdgeInsets.only(left: leadWidth, bottom: AppSpace.xs),
              child: Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ),
          // '다음' 줄에만 '오늘은 건너뛰기' / '되돌리기'(2026-10-18) — 그 회차 한 번만. 줄 누름(편집)과 따로 받는다.
          if (n != null && n.canSkip && !r.isTemplate && !skipLine)
            Padding(
              padding: EdgeInsets.only(left: leadWidth, bottom: AppSpace.xs),
              child: SkipNextControl(next: n),
            ),
          if (error case final message?)
            Padding(
              padding: EdgeInsets.only(left: leadWidth, bottom: AppSpace.xs),
              // 어절 단위로 줄을 바꾼다('자리/를' 방지, UI 평가 10/17).
              child: Text(keepWordsTogether(message),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
            ),
        ],
      ),
    );
  }
}

/// 자동 규칙 스위치 한 번 — 끄기는 바로, 켜기는 늘 확인 시트(서버가 준 조건·동작을 보여 주고 그 지문으로만 켠다).
/// 실제로 바꿨으면 true, 취소했거나 켤 수 없으면 false(까닭은 알림으로 말한다). 루틴 줄 스위치와 '자동 규칙' 탭이 함께 쓴다.
Future<bool> setAutoRuleSwitch(BuildContext context, RpiApiService api, AutoRule rule, bool on) async {
  if (!on) {
    await api.setAutoRuleEnabled(rule.id, false);
    return true;
  }
  final fp = rule.fingerprint;
  if (fp == null) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('어느 가전인지 몰라서 켤 수 없어요. 가전 연결을 봐 주세요')));
    return false;
  }
  final ok = await showAutoRuleConfirmSheet(
    context,
    conditionText: withAmPmSpoken(rule.conditionText, rule.conditionTime),
    actionText: rule.actionText,
    caveat: rule.caveat,
    title: '다음부터 자동으로 할까요?',
    confirmLabel: '허락하기',
  );
  if (!ok) return false;
  await api.setAutoRuleEnabled(rule.id, true, fingerprint: fp);
  return true;
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
    await setAutoRuleSwitch(context, api, rule, true);
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
        title: "이 '자동으로 하기'를 지울까요?",
        body: autoRuleSentence(widget.rule));
    if (ok) await api.deleteAutoRule(widget.rule.id);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rule;
    final reason = r.disabledReason;
    final quietNote = quietRuleNote(ref.watch(quietHoursProvider).valueOrNull, r);
    // 상태는 서버 문장(status_label)이 아니라 enabled 값으로(2차 평가 10/18).
    // 끈 규칙은 한 줄 — 꺼진 까닭이 있으면 그 말이 배지다(평가 6차 10/18: '지금은 안 해요' 아래 '자동으로 하기를
    // 꺼 두셨어요'가 같은 말을 두 번 했다). 까닭이 없으면 '지금은 안 해요'.
    // 평가 8차(10/18): 사용자가 끈 규칙은 스위치가 이미 '꺼짐'을 말한다 — '자동으로 하기를 꺼 두셨어요' 배지를 두지 않는다.
    // 정지·값 바꿈·재시작처럼 다른 까닭으로 꺼졌으면 그 까닭이 배지다(스위치만으로는 왜 꺼졌는지 모른다).
    final offLabel = (reason ?? '').trim().replaceAll(RegExp(r'[.。]$'), '');
    final userOff = offLabel.isEmpty || offLabel == kUserOffReason;
    // 평가 11차(10/18): 켜진 규칙의 '자동으로 해요'·사용자가 끈 규칙의 '꺼 둠'은 바로 옆 스위치와 같은 뜻이라 두지 않는다.
    // 정지·값 바꿈·재시작처럼 다른 까닭으로 꺼졌을 때만 그 까닭 배지(스위치만으로는 왜 꺼졌는지 모른다).
    final Widget? badge = r.enabled || userOff
        ? null
        : StatusBadge(key: Key('auto-rule-off-${r.id}'), icon: AppIcons.off, label: keepWordsTogether(offLabel));
    // 면·그림자 없는 줄(평가 15차 10/18 — '내 루틴' 목록과 같은 문법). 줄 사이 구분은 목록이 긋는다.
    return Padding(
      key: Key('auto-rule-${r.id}'),
      padding: EdgeInsets.zero,
      child: SizedBox(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 카드마다 붙던 순환 아이콘은 뺀다(평가 14차 10/18 — 장식). 켜짐은 스위치가 말한다.
                  Expanded(
                    // 끝 짧은 낱말('세게'·'켜기')은 앞 낱말과 함께 넘긴다(평가 16차 10/18: '공기청정기 / 세게').
                    child: Text(keepActionNameTogether(r.name),
                        semanticsLabel: r.name,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  // 켜기/끄기 — 켤 때는 늘 확인 시트(서버가 준 조건·동작과 지문으로만 켠다), 끌 때는 바로.
                  Semantics(
                    label: '${r.name} 자동',
                    toggled: r.enabled,
                    excludeSemantics: true,
                    // 켜짐·꺼짐을 색만으로 말하지 않는다 — 스위치 바로 아래 글자(접근성 감사 10/18, 내 루틴 스위치와 같은 모양).
                    child: SwitchWithWord(
                      on: r.enabled,
                      wordKey: Key('auto-rule-switch-text-${r.id}'),
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
                padding: const EdgeInsets.only(right: AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 언제·무엇을 한 문장(2차 평가 10/18) — 화살표·'조건:/동작:' 표를 쓰지 않는다.
                    // 평가 14차(10/18): 이름이 이미 다 말하면(이름 '전자레인지가 멈추면 공기청정기 세게') 되풀이하지 않는다.
                    // 값을 바꿔 이름과 달라졌으면 남긴다([autoRuleNameSaysAll]).
                    if (!autoRuleNameSaysAll(r))
                      Text(keepWordsTogether(autoRuleSentence(r)),
                          semanticsLabel: autoRuleSentence(r),
                          style: const TextStyle(fontSize: AppFont.body)),
                    if (badge != null) ...[
                      const SizedBox(height: AppSpace.sm),
                      badge,
                    ],
                    // 조용한 시간이 켜져 있어 실제로 건너뛸 때만 눈에 띄게(앰버·굵게). 꺼져 있을 때의 '켜면 …'은
                    // 조용한 시간 설정 줄에만 둔다(평가 6차 10/18: 카드마다 늘 굵게 서 있었다).
                    if (quietNote != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(keepWordsTogether(quietNote),
                          semanticsLabel: quietNote,
                          style: TextStyle(
                              fontSize: AppFont.caption, fontWeight: FontWeight.w600, color: context.appWarning)),
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
  const _Note(this.text, {super.key, this.textKey});
  final String text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        // 낱말 단위로만 줄을 바꾼다(평가 10차 10/18). 낭독은 원문.
        // 끝 짧은 낱말은 앞 낱말과 함께 넘긴다(평가 16차 10/18: '끌 수 / 있어요').
        child: Text(keepActionNameTogether(text),
            key: textKey,
            semanticsLabel: text,
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
      );
}

/// 루틴에 붙은 시각 규칙 — 조건 종류가 시각이고, 본체가 규칙 이름으로 주는 루틴 이름과 시각이 이 루틴과 같은 것.
/// 본체 규칙 목록(`/routines/auto-rules`)에는 루틴 id가 없어 이름·시각으로만 잇는다 — 맞지 않으면 null(탭에 남는다).
AutoRule? routineAutoRule(Routine r, List<AutoRule> rules) {
  if (r.isTemplate || r.id == null) return null;
  final clock = routineClock(r);
  if (clock == null) return null;
  final matches = [
    for (final rule in rules)
      if (rule.isTime &&
          rule.name.trim() == r.name.trim() &&
          (rule.conditionTime == null || rule.conditionTime!.padLeft(5, '0') == clock.padLeft(5, '0')))
        rule,
  ];
  // 이름·시각이 같은 규칙이 둘이면 어느 쪽인지 모른다 — 잇지 않고 탭에 둔다.
  return matches.length == 1 ? matches.single : null;
}

/// '자동 규칙' 탭에 둘 규칙 — 루틴 줄에 닿지 않는 것 전부(사건 규칙, 루틴을 찾지 못한 시각 규칙).
List<AutoRule> standaloneAutoRules(List<AutoRule> rules, List<Routine> routines) {
  final count = <String, int>{};
  for (final r in routines) {
    final rule = routineAutoRule(r, rules);
    if (rule != null) count[rule.id] = (count[rule.id] ?? 0) + 1;
  }
  // 같은 규칙에 루틴 둘이 이어지면 어느 쪽인지 모른다 — 탭에도 둔다.
  return [for (final rule in rules) if (count[rule.id] != 1) rule];
}

/// 규칙 이름이 언제·무엇을 이미 다 말하는가(평가 14차 10/18: 카드 설명이 이름을 거의 되풀이했다).
///
/// 이름은 본체가 시나리오로 정해 값을 바꿔도 그대로다 — 그래서 바람 세기 규칙만, **지금 값의 말이 이름에 있을 때만** 참.
/// 이름이 '세게'인데 값이 중간이면 거짓(설명을 남긴다). 그 밖의 규칙은 설명을 둔다.
bool autoRuleNameSaysAll(AutoRule rule) {
  if (rule.isTime || rule.action != 'set_wind_strength') return false;
  final word = switch ((rule.value ?? '').toUpperCase()) {
    'HIGH' => '세게',
    'MID' => '중간',
    'LOW' => '약하게',
    _ => null,
  };
  return word != null && rule.name.contains(word);
}

/// 본체가 사용자가 끈 규칙에 붙이는 까닭(끝 마침표 뺌) — 이 말이면 배지 없이 스위치만.
const kUserOffReason = '자동으로 하기를 꺼 두셨어요';

/// 규칙 값 바꾸기 단추 이름 — 무엇의 값인지 말한다(UI 평가 3차 10/17: '세기'는 무엇의 세기인지 몰랐다).
///
/// 서버(bcc4cdb)가 규칙 문장에서 '풍량'을 뺐다 — 문장이 아니라 동작 이름으로 가른다(옛 서버는 문장으로).
String autoRuleValueLabel(AutoRule rule) =>
    rule.action == 'set_wind_strength' ||
            (rule.action == null && rule.actionText.contains('풍량'))
        ? '바람 세기 바꾸기'
        : '설정 바꾸기';

/// 규칙 한 문장 — 언제 + 무엇을(화살표 없이). 서버 문장이 '…면'·'…해요'로 이어 읽히게 만든다(2차 평가 10/18).
///
/// 본체 문장의 '매일 밤 10시에'는 그 규칙의 시각(`condition_time`)과 정확히 맞을 때만 '매일 오후 10:00에'로 —
/// 폰의 다른 시각과 같은 꼴(평가 8차 10/18). 맞지 않으면 본체 문장 그대로.
String autoRuleSentence(AutoRule rule) => [
      withAmPmSpoken(rule.conditionText.trim(), rule.conditionTime),
      rule.actionText.trim(),
    ].where((t) => t.isNotEmpty).join(' ');

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
