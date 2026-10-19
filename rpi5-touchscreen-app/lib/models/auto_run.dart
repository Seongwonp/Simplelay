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
    this.valuePhrase,
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

  /// 결과 문장 속 설정 이름(서버 `value_phrase`, 예: "강풍", 2026-10-14). 옛 서버는 null.
  final String? valuePhrase;

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
      valuePhrase: s('value_phrase'),
    );
  }
}

/// 한 줄 알림 — 실제 결과 그대로 짧게. 모의면 같은 줄 끝에 "연습 모드"(2026-10-14 문구 정리).
///
/// - 상태 재조회로 확인: "공기청정기 풍량을 강으로 바꿨어요"
/// - 결과 미확인: "공기청정기 설정이 바뀌었는지 확인하지 못했어요"
/// - 이미 목표값(보내지 않음, 2026-10-14): "공기청정기는 이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요"
/// - 보낸 뒤 목표값·전 값 모름: "공기청정기가 강풍으로 설정된 것을 확인했어요"('바꿨어요' 아님)
String autoRunNotice(KioskAutoRun run) {
  final target = (run.targetName == null || run.targetName!.trim().isEmpty)
      ? '가전'
      : run.targetName!.trim();
  final mock = run.executionMode == 'mock' ? '. 연습이에요' : '';
  if (run.outcome == 'blocked') {
    return '$target 자동으로 하지 않았어요$mock';
  }
  // 설정 이름은 job을 만들 때의 사본(서버 last_auto_run). 없으면 "풍량 강"처럼 속성 이름을 붙인다.
  final phrase = _phraseOf(run);
  final stem = _stem(target);
  if (run.status == 'succeeded' && run.confirmation == 'already_at_target') {
    // 보내지 않았다 — 바꿨다고도, 확인 못 했다고도 하지 않는다.
    if (phrase == null) return '$target 설정은 이미 그 값이라 보내지 않았어요$mock';
    return '$target${_topicParticle(stem)} 이미 $phrase${_directionParticle(phrase)} 돼 있어 보내지 않았어요$mock';
  }
  if (run.status == 'succeeded' &&
      run.confirmation == 'state_confirmed_unknown_before') {
    if (phrase == null) return '$target 설정을 확인했어요$mock';
    return '$target${_subjectParticle(stem)} $phrase${_directionParticle(phrase)} 된 것을 봤어요$mock';
  }
  if (run.status == 'succeeded' &&
      run.confirmation == 'state_confirmed' &&
      (run.valuePhrase ?? '').isNotEmpty) {
    return '$target${_objectParticle(stem)} ${run.valuePhrase}${_directionParticle(run.valuePhrase!)} 바꿨어요$mock';
  }
  if (run.status == 'succeeded' && run.confirmation == 'state_confirmed') {
    final label = run.settingLabel, value = run.valueLabel;
    if (label != null && label.isNotEmpty && value != null && value.isNotEmpty) {
      return '$target $label${_objectParticle(label)} $value${_directionParticle(value)} 바꿨어요$mock';
    }
    return '$target 설정을 바꿨어요$mock';
  }
  if (run.status == 'unconfirmed' || run.status == 'succeeded') {
    return '$target 설정이 바뀌었는지 몰라요$mock';
  }
  if (run.receipt == 'not_dispatched') {
    return '$target에 전하지 못했어요$mock';
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

/// 은/는 — 한글이 아니면 '은'.
String _topicParticle(String word) => _finalConsonant(word) == 0 ? '는' : '은';

/// 이/가 — 한글이 아니면 '이'.
String _subjectParticle(String word) => _finalConsonant(word) == 0 ? '가' : '이';

/// 조사 고를 낱말 — 끝의 괄호 표기("(모의)")는 건너뛴다.
String _stem(String word) {
  var s = word.trim();
  while (s.endsWith(')') && s.contains('(')) {
    s = s.substring(0, s.lastIndexOf('(')).trimRight();
  }
  return s.isEmpty ? word : s;
}

String? _phraseOf(KioskAutoRun run) {
  final p = run.valuePhrase;
  if (p != null && p.isNotEmpty) return p;
  final label = run.settingLabel, value = run.valueLabel;
  if (label != null && label.isNotEmpty && value != null && value.isNotEmpty) {
    return '$label $value';
  }
  return null;
}

/// 으로/로 — 받침 없음·ㄹ 받침이면 '로'.
String _directionParticle(String word) {
  final f = _finalConsonant(word);
  return (f == 0 || f == 8) ? '로' : '으로';
}
