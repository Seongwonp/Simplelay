class LearningStatus {
  LearningStatus.fromJson(Map<String, dynamic> json)
      : windowDays = json['window_days'] as int,
        minimumDays = json['minimum_days'] as int,
        minimumOccurrences = json['minimum_occurrences'] as int,
        paused = json['paused'] as bool,
        routines = (json['routines'] as List)
            .map((r) => LearningRoutine.fromJson(r as Map<String, dynamic>))
            .toList(),
        // 밤 정리 문장(2026-10-26) — 옛 서버에는 없다.
        summary = json['summary'] is Map<String, dynamic>
            ? LifestyleSummary.fromJson(json['summary'] as Map<String, dynamic>)
            : null;

  final int windowDays;
  final int minimumDays;
  final int minimumOccurrences;
  final bool paused;
  final List<LearningRoutine> routines;
  final LifestyleSummary? summary;
}

/// 밤마다 만든 생활 습관 정리 두 문장. 자동으로 소리 내 읽지 않는다.
class LifestyleSummary {
  LifestyleSummary.fromJson(Map<String, dynamic> json)
      : text = json['text'] as String,
        source = json['source'] as String? ?? 'template',
        generatedAt = DateTime.tryParse(json['generated_at'] as String? ?? '');

  final String text;

  /// `llm`(본체 안 언어 모델) · `template`(사용 기록으로 만든 정해진 문장).
  final String source;
  final DateTime? generatedAt;

  bool get byModel => source == 'llm';
}

class LearningRoutine {
  LearningRoutine.fromJson(Map<String, dynamic> json)
      : purpose = json['purpose'] as String,
        applianceId = json['appliance_id'] as String?,
        timeBand = json['time_band'] as String,
        occurrences = json['occurrences'] as int,
        distinctDays = json['distinct_days'] as int,
        established = json['established'] as bool,
        muted = json['muted'] as bool,
        // 실제로 쓴 날(ISO, 오래된 날부터) — 옛 서버에는 없다.
        recentDays = [
          for (final d in (json['recent_days'] as List<dynamic>? ?? const []))
            if (DateTime.tryParse(d as String) case final day?) day,
        ],
        // '알게 된 것'(2026-10-26) — 옛 서버에는 없다(없으면 시간대·숨김·습관 여부로 대신 보인다).
        whenText = json['when_text'] as String?,
        state = json['state'] as String?,
        pausedUntil = DateTime.tryParse(json['paused_until'] as String? ?? ''),
        routineName = json['routine_name'] as String?;

  final String purpose;
  final String? applianceId;
  final String timeBand;
  final int occurrences;
  final int distinctDays;
  final bool established;
  final bool muted;
  final List<DateTime> recentDays;
  final String? whenText;
  final String? state;
  final DateTime? pausedUntil;
  final String? routineName;

  /// auto · hidden · paused · asking · learning.
  String get effectiveState =>
      state ?? (muted ? 'hidden' : established ? 'asking' : 'learning');
}

/// 습관 상태 한 마디(명사형) — 자동 실행 중 · 숨김 · 잠시 묻지 않음(~까지, 연달아 거절한 뒤. 방해 금지와 다른 말) · 물어보는 중 · 알아 가는 중.
String habitStateLabel(LearningRoutine routine) {
  switch (routine.effectiveState) {
    case 'auto':
      return '자동 실행 중';
    case 'hidden':
      return '숨김';
    case 'paused':
      final until = routine.pausedUntil;
      return until == null ? '잠시 묻지 않음' : '잠시 묻지 않음 (${untilText(until)}까지)';
    case 'asking':
      return '물어보는 중';
    default:
      return '알아 가는 중';
  }
}

/// '10월 27일 오후 10시' — 쉬는 끝 시각(현지).
String untilText(DateTime at) {
  final local = at.toLocal();
  final h = local.hour;
  final clock = h == 0
      ? '밤 12시'
      : h < 12
          ? '오전 $h시'
          : h == 12
              ? '낮 12시'
              : '오후 ${h - 12}시';
  final minute = local.minute == 0 ? '' : ' ${local.minute}분';
  return '${local.month}월 ${local.day}일 $clock$minute';
}

/// 실제로 쓴 날 한 줄(2026-10-25, '왜 습관인지' 근거) — '쓴 날: 10월 21일 · 22일 · 23일'. 없으면 null.
String? usedDaysLine(List<DateTime> days) {
  if (days.isEmpty) return null;
  final parts = <String>[];
  int? month;
  for (final d in days) {
    parts.add(d.month == month ? '${d.day}일' : '${d.month}월 ${d.day}일');
    month = d.month;
  }
  return '쓴 날: ${parts.join(' · ')}';
}
