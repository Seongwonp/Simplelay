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
        muted = json['muted'] as bool;

  final String purpose;
  final String? applianceId;
  final String timeBand;
  final int occurrences;
  final int distinctDays;
  final bool established;
  final bool muted;
}
