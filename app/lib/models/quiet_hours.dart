import 'clock_text.dart';
import 'auto_rule.dart';

/// 서버 `GET/PUT /quiet-hours`의 조용한 시간 상태.
///
/// 매일 시간대와 일시 중지를 한 판정으로 표현한다. 적용 범위는 서버 `scope`를 따른다.
/// 직접 실행과 정지는 제한하지 않는다.
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

  /// 설정 화면에 표시할 시간대와 현재 상태.
  String get summary {
    final range = '매일 ${ampmRange(start, end)}';
    if (!enabled) return '$range, 꺼져 있어요';
    return reason == 'schedule' ? '$range, 지금 조용한 시간이에요' : range;
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

/// 조용한 시간과 겹치는 활성 시각 규칙 안내. 없으면 null.
String? quietSkipLine(QuietHoursStatus s, List<AutoRule> rules) {
  final hit = [
    for (final r in rules)
      if (r.enabled && r.conditionTime != null && quietWindowContains(s.start, s.end, r.conditionTime!))
        '${r.name}(${ampmClock(r.conditionTime!)})',
  ];
  if (hit.isEmpty) return null;
  // 자동 계열 말은 '자동으로 해요'/'안 해요' 하나로(평가 4차 10/18 — '자동 실행'·'자동'이 섞였다).
  return '${s.enabled ? '조용한 시간이라 이때는 자동으로 안 해요' : '켜면 이때는 자동으로 안 해요'}: ${hit.join(', ')}';
}

/// 조용한 시간이 활성화되어 규칙을 실제로 건너뛸 때만 표시한다.
String? quietRuleNote(QuietHoursStatus? s, AutoRule r) {
  final t = r.conditionTime;
  if (s == null || !s.enabled || t == null || !quietWindowContains(s.start, s.end, t)) return null;
  return '조용한 시간(${ampmRange(s.start, s.end)})이라 이때는 자동으로 안 해요';
}

/// [minutes]분의 일시 중지와 겹치는 다음 활성 시각 규칙.
/// 요일 정보가 없으므로 규칙을 매일 반복으로 계산한다.
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
    if (at.isBefore(end)) out.add('${r.name}(${ampmClock(t)})');
  }
  return out;
}

/// `persisted: false`일 때의 안내. 재시작하면 마지막 저장 설정으로 돌아간다.
const kSettingNotSavedNotice = '저장하지 못해 지금만 적용돼요. 본체를 다시 켜면 전 설정으로 돌아가요.';

/// 일시 중지가 끝나는 현지 시각.
String pauseEndClock(DateTime until) => ampmOf(until.toLocal());
