/// 조용한 시간(2026-10-14, 서버 `GET/PUT /quiet-hours`). 키오스크는 같은 상태를 /health의 `quiet`로 본다.
///
/// 매일 시간대(사용자 설정)와 '제안 잠시 쉬기'를 서버가 한 판정으로 묶는다. 실제 범위는 서버 `scope` 문장 그대로
/// 보인다 — 새 제안과 일반 안내 소리, 아직 시작하지 않은 자동 실행만. 직접 실행·정지는 그대로다.
class QuietHoursStatus {
  const QuietHoursStatus({
    required this.enabled,
    required this.start,
    required this.end,
    required this.active,
    this.reason,
    this.scope,
  });

  final bool enabled;
  final String start;
  final String end;
  final bool active;

  /// `schedule`(매일 시간대) · `pause`(잠시 쉬기) · null.
  final String? reason;
  final String? scope;

  static QuietHoursStatus? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final start = json['start'], end = json['end'];
    if (start is! String || end is! String) return null;
    return QuietHoursStatus(
      enabled: json['enabled'] == true,
      start: start,
      end: end,
      active: json['active'] == true,
      reason: json['reason'] as String?,
      scope: json['scope'] as String?,
    );
  }

  /// 설정 줄 — "매일 22:00~07:00 · 지금 조용한 시간이에요" / "· 꺼져 있어요".
  String get summary {
    final range = '매일 $start~$end';
    if (!enabled) return '$range · 꺼져 있어요';
    return reason == 'schedule' ? '$range · 지금 조용한 시간이에요' : range;
  }
}

/// 잠시 쉬기가 끝나는 시각 "HH:MM"(이 기기 현지 시각, 2026-10-14 마감 확인 A5). 남은 시간만으로는 '언제까지'를 셈해야 한다.
String pauseEndClock(DateTime until) {
  final t = until.toLocal();
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
