class LearningStatus {
  LearningStatus.fromJson(Map<String, dynamic> json)
      : windowDays = json['window_days'] as int,
        minimumDays = json['minimum_days'] as int,
        minimumOccurrences = json['minimum_occurrences'] as int,
        paused = json['paused'] as bool,
        routines = (json['routines'] as List)
            .map((r) => LearningRoutine.fromJson(r as Map<String, dynamic>))
            .toList();

  final int windowDays;
  final int minimumDays;
  final int minimumOccurrences;
  final bool paused;
  final List<LearningRoutine> routines;
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
        ];

  final String purpose;
  final String? applianceId;
  final String timeBand;
  final int occurrences;
  final int distinctDays;
  final bool established;
  final bool muted;
  final List<DateTime> recentDays;
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
