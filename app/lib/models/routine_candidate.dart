/// 가전 사용 기록으로 만든 루틴 초안(2026-10-14, 서버 `GET /routines/candidates`).
///
/// 가전·버튼 순서가 이미 채워져 있다. 사용자는 이름과 '직접 실행할 때만 / 정해진 때 물어보기'만
/// 고른다. **저장만 한다** — 저장으로 실행·카드·자동 실행 허용이 생기지 않는다.
class RoutineCandidate {
  const RoutineCandidate({
    required this.key,
    required this.applianceId,
    required this.applianceName,
    required this.buttons,
    required this.suggestedName,
    required this.evidence,
    required this.askTime,
    required this.runChoices,
    required this.notice,
  });

  final String key;
  final String applianceId;
  final String applianceName;
  final List<String> buttons;
  final String suggestedName;

  /// 서버 문장 그대로("최근 28일 중 아침에 4일 사용했어요") — 사람을 단정하지 않는 가전 기록 문장.
  final String evidence;
  final String? askTime;

  /// (run, label) — `manual` "직접 실행할 때만" · `ask_at_time` "매일 07:30에 물어보기".
  final List<(String, String)> runChoices;
  final String notice;

  String get sequenceText => buttons.join(' → ');

  static RoutineCandidate? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final key = json['key'];
    final appliance = json['appliance_id'];
    final buttons = json['buttons'];
    if (key is! String || appliance is! String || buttons is! List || buttons.isEmpty) {
      return null; // 버튼 순서가 없는 초안은 보이지 않는다(빈 폼 금지)
    }
    final choices = <(String, String)>[
      for (final c in (json['run_choices'] as List? ?? const []))
        if (c is Map && c['run'] is String && c['label'] is String)
          (c['run'] as String, c['label'] as String),
    ];
    return RoutineCandidate(
      key: key,
      applianceId: appliance,
      applianceName: json['appliance_name'] as String? ?? appliance,
      buttons: [for (final b in buttons) '$b'],
      suggestedName: json['suggested_name'] as String? ?? '',
      evidence: json['evidence'] as String? ?? '',
      askTime: json['ask_time'] as String?,
      runChoices: choices.isEmpty ? const [('manual', '직접 실행할 때만')] : choices,
      notice: json['notice'] as String? ??
          '저장해도 바로 하지 않아요. 할 때마다 허락을 받아요.',
    );
  }
}
