part of '../routines_screen.dart';

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
/// 시각은 오전/오후 형식으로 표시한다. [withClock]이 false면 시각 설명을 생략한다.
///
/// [skipNamed]가 true면 이름과 중복되는 동작 설명을 생략한다.
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

/// 루틴 이름 아래 표시할 시각과 대상 가전 요약.
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

/// 루틴의 대상 가전과 버튼 수 또는 LG 가전 동작을 설명한다.
