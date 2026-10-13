/// 자동 실행 허용 규칙의 마지막 결과(서버 /status `last_auto_run`, 2026-10-14) — 키오스크 짧은 알림용.
///
/// 키오스크가 시작한 실행이 아니라 '남의 실행'으로만 보이던 자동 실행 결과를, 실제 결과 그대로 한 줄로 알린다.
/// 상태 재조회로 확인한 것만 바꿨다고 말하고, 공기 상태(깨끗함)는 말하지 않는다.
class KioskAutoRun {
  const KioskAutoRun({
    required this.jobId,
    this.outcome,
    this.status,
    this.receipt,
    this.confirmation,
    this.executionMode,
    this.targetName,
    this.settingLabel,
    this.valueLabel,
  });

  final String jobId;

  /// sent | blocked(보내기 직전 재검사에 걸림)
  final String? outcome;

  /// succeeded | unconfirmed | failed | stopped
  final String? status;
  final String? receipt;
  final String? confirmation;
  final String? executionMode;
  final String? targetName;
  final String? settingLabel;
  final String? valueLabel;

  static KioskAutoRun? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final jobId = json['job_id'];
    if (jobId is! String || jobId.isEmpty) return null;
    String? s(String key) => json[key] is String ? json[key] as String : null;
    return KioskAutoRun(
      jobId: jobId,
      outcome: s('outcome'),
      status: s('status'),
      receipt: s('receipt'),
      confirmation: s('confirmation'),
      executionMode: s('execution_mode'),
      targetName: s('target_name'),
      settingLabel: s('setting_label'),
      valueLabel: s('value_label'),
    );
  }
}

/// 한 줄 알림 — 실제 결과 그대로 짧게. 모의면 같은 줄 안에 모의 표시.
///
/// - 상태 재조회로 확인: "공기청정기 풍량을 강으로 바꿨어요"
/// - 결과 미확인: "공기청정기 설정이 바뀌었는지 확인하지 못했어요"
String autoRunNotice(KioskAutoRun run) {
  final target = (run.targetName == null || run.targetName!.trim().isEmpty)
      ? '가전'
      : run.targetName!.trim();
  final mock = run.executionMode == 'mock' ? ' · 모의 실행(실제 조작 아님)' : '';
  if (run.outcome == 'blocked') {
    return '$target 자동 실행을 보내지 않았어요$mock';
  }
  if (run.status == 'succeeded' && run.confirmation == 'state_confirmed') {
    final label = run.settingLabel, value = run.valueLabel;
    if (label != null && label.isNotEmpty && value != null && value.isNotEmpty) {
      return '$target $label${_objectParticle(label)} $value${_directionParticle(value)} 바꿨어요$mock';
    }
    return '$target 설정을 바꿨어요$mock';
  }
  if (run.status == 'unconfirmed' || run.status == 'succeeded') {
    return '$target 설정이 바뀌었는지 확인하지 못했어요$mock';
  }
  if (run.receipt == 'not_dispatched') {
    return '$target 설정 명령을 보내지 못했어요$mock';
  }
  return '$target 설정을 바꾸지 못했어요$mock';
}

int? _finalConsonant(String word) {
  final trimmed = word.trim();
  if (trimmed.isEmpty) return null;
  final code = trimmed.runes.last;
  if (code < 0xAC00 || code > 0xD7A3) return null;
  return (code - 0xAC00) % 28;
}

/// 을/를 — 한글이 아니면 '을'.
String _objectParticle(String word) => _finalConsonant(word) == 0 ? '를' : '을';

/// 으로/로 — 받침 없음·ㄹ 받침이면 '로'.
String _directionParticle(String word) {
  final f = _finalConsonant(word);
  return (f == 0 || f == 8) ? '로' : '으로';
}
