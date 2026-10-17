import 'auto_rule.dart';

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
    this.persisted,
  });

  final bool enabled;
  final String start;
  final String end;
  final bool active;

  /// `schedule`(매일 시간대) · `pause`(잠시 쉬기) · null.
  final String? reason;
  final String? scope;

  /// 바꾸는 응답(PUT)에만 — true 저장됨 · false 저장 실패(이번 세션만 적용) · null 저장소 없음·옛 서버·조회 응답.
  final bool? persisted;

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
      persisted: json['persisted'] is bool ? json['persisted'] as bool : null,
    );
  }

  /// 설정 줄 — "매일 22:00~07:00 · 지금 조용한 시간이에요" / "· 꺼져 있어요".
  String get summary {
    final range = '매일 $start~$end';
    if (!enabled) return '$range · 꺼져 있어요';
    return reason == 'schedule' ? '$range · 지금 조용한 시간이에요' : range;
  }
}

/// 'HH:MM'이 조용한 시간대 안인가 — 서버 판정(`window_contains`)과 같게 시작은 포함, 끝은 제외, 자정을 넘을 수 있다.
bool quietWindowContains(String start, String end, String hhmm) {
  int? minutes(String v) {
    final p = v.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    return h == null || m == null ? null : h * 60 + m;
  }

  final s = minutes(start), e = minutes(end), t = minutes(hhmm);
  if (s == null || e == null || t == null || s == e) return false;
  return s < e ? (s <= t && t < e) : (t >= s || t < e);
}

/// 조용한 시간 때문에 건너뛸 자동 실행(켜진 시각 규칙만)을 한 줄로. 없으면 null.
/// 켜져 있으면 '조용한 시간이라 …', 꺼져 있으면 '켜면 …'(UI 평가 6차 10/17 — 켜는 순간 소리 없이 건너뛰어졌다).
String? quietSkipLine(QuietHoursStatus s, List<AutoRule> rules) {
  final hit = [
    for (final r in rules)
      if (r.enabled && r.conditionTime != null && quietWindowContains(s.start, s.end, r.conditionTime!))
        '${r.name}(${r.conditionTime})',
  ];
  if (hit.isEmpty) return null;
  return '${s.enabled ? '조용한 시간이라 이 자동 실행은 건너뛰어요' : '켜면 이 자동 실행은 건너뛰어요'}: ${hit.join(', ')}';
}

/// 규칙 카드의 한 줄 — 이 시각 규칙이 조용한 시간과 겹치면(UI 평가 7차 10/17: 설정 화면에서만 경고됐다). 아니면 null.
String? quietRuleNote(QuietHoursStatus? s, AutoRule r) {
  final t = r.conditionTime;
  if (s == null || t == null || !quietWindowContains(s.start, s.end, t)) return null;
  final range = '조용한 시간(${s.start}~${s.end})';
  return s.enabled ? '$range이라 이 자동 실행은 건너뛰어요' : '$range을 켜면 이 자동 실행은 건너뛰어요';
}

/// '제안 잠시 쉬기'를 [minutes]분 켜면 그 안에 시각이 드는 켜진 시각 규칙('이름(HH:MM)'). 다음에 오는 그 시각을
/// 센다(지금과 같으면 아직 시작 전이라 포함). 요일은 규칙 목록이 주지 않아 매일로 본다(UI 평가 7차 10/17).
List<String> pauseSkippedRules(DateTime now, int minutes, List<AutoRule> rules) {
  final end = now.add(Duration(minutes: minutes));
  final out = <String>[];
  for (final r in rules) {
    final t = r.conditionTime;
    if (!r.enabled || t == null) continue;
    final p = t.split(':');
    final h = p.length == 2 ? int.tryParse(p[0]) : null, m = p.length == 2 ? int.tryParse(p[1]) : null;
    if (h == null || m == null) continue;
    var at = DateTime(now.year, now.month, now.day, h, m);
    if (at.isBefore(now)) at = at.add(const Duration(days: 1));
    if (at.isBefore(end)) out.add('${r.name}($t)');
  }
  return out;
}

/// 설정 저장이 실패해 이번 세션에만 적용됐을 때(서버 `persisted: false`, 2026-10-14 HIGH 재확인 M-R1) — 잠시 쉬기·
/// 조용한 시간 공통. 허브를 다시 켜면 마지막으로 저장된 설정으로 시작한다.
const kSettingNotSavedNotice = '저장하지 못해 지금만 적용돼요. 허브를 다시 켜면 이전 설정으로 돌아가요.';

/// 잠시 쉬기가 끝나는 시각 "HH:MM"(이 기기 현지 시각, 2026-10-14 마감 확인 A5). 남은 시간만으로는 '언제까지'를 셈해야 한다.
String pauseEndClock(DateTime until) {
  final t = until.toLocal();
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
