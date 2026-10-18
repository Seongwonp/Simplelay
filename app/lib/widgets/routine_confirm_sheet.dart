import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../models/display_status.dart';
import '../models/line_break.dart';
import '../models/routine.dart';
import '../screens/routines_screen.dart' show thinqResultPhrase;
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

/// 루틴 '지금 하기'를 누르면 먼저 묻는 말(휴리스틱 평가 10/18 — 한 번 탭으로 실물 누름이 바로 시작되는 것처럼 보였다).
///
/// 이 시트는 **묻기만** 한다. '지금 하기'를 고르면 예전과 같은 경로(승인 카드 → 승인 화면)를 탄다 — 서버 계약은 그대로다.
typedef RoutineRunPlan = ({String title, List<String> lines, String? note, bool practice});

/// 루틴이 무엇을 하는지 — 제목·할 일 줄·덧말. [appliances]는 이 폰의 가전(이름·연습 여부).
///
/// - 누름 장치 단계: '전자레인지 버튼 2개를 눌러요'(가전마다 한 줄).
/// - LG 가전 단계: '공기청정기 켜기'처럼 할 일 이름.
/// - 단계의 가전이 모두 연습 가전이면 제목은 '연습으로 해 볼까요?'.
RoutineRunPlan routineRunPlan(Routine r, List<ApplianceMap> appliances) {
  ApplianceMap? find(String? id) => appliances.where((a) => a.id == id).firstOrNull;
  String nameOf(String? id) {
    final a = find(id);
    return a == null ? (id ?? '가전') : applianceTileName(a);
  }

  final presses = <String, int>{};
  final lg = <String>[];
  final ids = <String?>[];
  for (final s in r.steps) {
    if (s.kind == RoutineStepKind.pressSequence) {
      presses[nameOf(s.applianceId)] = (presses[nameOf(s.applianceId)] ?? 0) + s.buttons.length;
      ids.add(s.applianceId);
    } else if (s.kind == RoutineStepKind.thinqCommand) {
      final phrase = thinqResultPhrase(nameOf(s.applianceId), s.action, s.args);
      if (!lg.contains(phrase)) lg.add(phrase);
      ids.add(s.applianceId);
    }
  }
  final practice = ids.isNotEmpty && ids.every((id) => find(id) != null && isPracticeAppliance(find(id)!));
  final lines = [
    for (final e in presses.entries) '${e.key} 버튼 ${e.value}개를 눌러요',
    ...lg,
  ];
  final name = r.name.trim();
  final title = practice ? '연습으로 해 볼까요?' : '지금 $name${objectParticle(name)} 할까요?';
  // 누르는 길과 LG 가전 길이 무엇이 다른지 한 줄. 연습이면 실제 가전과 다르다는 것을 먼저.
  final note = practice
      ? '연습 가전이라 실제 가전은 그대로예요'
      : lg.isNotEmpty && presses.isEmpty
          ? 'LG 가전에 바로 보내요'
          : null;
  return (title: title, lines: lines, note: note, practice: practice);
}

/// '지금 하기' 확인 시트. 고르면 true, 취소·닫기는 false.
Future<bool> showRoutineRunConfirm(
  BuildContext context, {
  required Routine routine,
  required List<ApplianceMap> appliances,
}) async {
  final plan = routineRunPlan(routine, appliances);
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => _RoutineConfirmSheet(plan: plan),
  );
  return ok == true;
}

class _RoutineConfirmSheet extends StatelessWidget {
  const _RoutineConfirmSheet({required this.plan});
  final RoutineRunPlan plan;

  @override
  Widget build(BuildContext context) {
    final buttons = [
      // 취소·지금 하기는 같은 크기(대등) — 어느 쪽도 실수로 누르기 쉽게 크지 않다.
      Expanded(
        child: OutlinedButton(
          key: const Key('routine-confirm-cancel'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 56)),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
      ),
      const SizedBox(width: AppSpace.md),
      Expanded(
        child: FilledButton(
          key: const Key('routine-confirm-run'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 56)),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('지금 하기'),
        ),
      ),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.sm, AppSpace.xl, AppSpace.xl),
      child: Column(
        key: const Key('routine-confirm-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(keepWordsTogether(plan.title), semanticsLabel: plan.title, style: AppText.title),
          ),
          const SizedBox(height: AppSpace.md),
          for (final line in plan.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.check, size: AppSpace.xl, color: context.appMuted),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(keepWordsTogether(line),
                      semanticsLabel: line, style: const TextStyle(fontSize: AppFont.body)),
                ),
              ]),
            ),
          if (plan.note case final note?) ...[
            const SizedBox(height: AppSpace.xs),
            Text(keepWordsTogether(note),
                semanticsLabel: note,
                style: TextStyle(
                    fontSize: AppFont.caption, color: plan.practice ? context.appPractice : context.appMuted)),
          ],
          const SizedBox(height: AppSpace.xs),
          // 확인 뒤에도 승인 화면에서 누를 순서를 한 번 더 보고 허락한다(경로 그대로) — 그 사실을 숨기지 않는다.
          Text(keepWordsTogether('다음 화면에서 한 번 더 보고 허락하면 시작해요'),
              semanticsLabel: '다음 화면에서 한 번 더 보고 허락하면 시작해요',
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          const SizedBox(height: AppSpace.xl),
          Row(children: buttons),
        ],
      ),
    );
  }
}
