import '../models/appliance.dart';
import '../models/routine.dart';
import 'rpi_api_service.dart';

class RoutineTimeHint {
  const RoutineTimeHint(this.time, this.days, this.count);
  final String time;
  final List<int> days;
  final int count;
}

/// 최근 30일, 같은 가전·버튼 순서의 실기기 성공 기록만 사용한다.
/// 30분 구간에 서로 다른 날짜 3개 이상·60% 이상이 모여야 제안한다.
/// 기록은 누르기 종료 시각이므로 실행 예약을 자동으로 저장하지 않는다.
RoutineTimeHint? routineTimeHint(Routine draft, List<ApplianceMap> appliances,
    List<RpiHistoryEntry> history, DateTime now) {
  if (draft.steps.isEmpty) return null;
  final first = draft.steps.first;
  if (first.kind != RoutineStepKind.pressSequence || first.buttons.isEmpty) return null;
  final appliance = appliances.where((a) => a.id == first.applianceId).firstOrNull;
  if (appliance == null) return null;
  final labels = first.buttons.map(appliance.labelFor).join('\u0000');
  final groups = <int, Map<String, DateTime>>{};
  final jobs = <String>{};
  for (final h in history) {
    final at = h.finishedAt.toLocal();
    if (h.applianceId != first.applianceId || h.executionMode != 'real' ||
        h.status != 'succeeded' || (h.outcome != null && h.outcome != 'success') ||
        h.buttons.any((b) => !b.success) ||
        h.buttons.map((b) => b.button).join('\u0000') != labels ||
        at.isAfter(now) || now.difference(at) > const Duration(days: 30) ||
        !jobs.add(h.jobId)) {
      continue;
    }
    final bucket = (at.hour * 60 + at.minute) ~/ 30;
    (groups[bucket] ??= {})['${at.year}-${at.month}-${at.day}'] = at;
  }
  final ranked = groups.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length));
  if (ranked.isEmpty) return null;
  final top = ranked.first;
  final total = ranked.fold<int>(0, (n, g) => n + g.value.length);
  if (top.value.length < 3 || top.value.length / total < 0.6 ||
      (ranked.length > 1 && ranked[1].value.length == top.value.length)) {
    return null;
  }
  final minutes = top.value.values.map((t) => t.hour * 60 + t.minute).toList()..sort();
  final minute = (minutes[minutes.length ~/ 2] ~/ 5) * 5;
  final days = top.value.values.map((t) => t.weekday - 1).toSet().toList()..sort();
  return RoutineTimeHint('${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}', days, top.value.length);
}
