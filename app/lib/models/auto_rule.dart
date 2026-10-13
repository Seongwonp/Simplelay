// 자동 실행 허용 규칙(서버 2026-10-13, 시연 v4) — 조리 완료(확인된 사건) → ThinQ 공기청정기 동작 하나.
//
// 규칙은 제안 카드에서 사용자가 '다음부터도 자동으로'를 고르고 조건·동작 확인을 본 뒤에만 생긴다.
// 서버가 낮은 위험 동작·모의/실물 출처·같은 사건 1회·비상정지를 강제한다. 폰은 서버가 준 문장을
// 그대로 보여 주고, 허용할 때 그 내용의 지문(`fingerprint`)을 함께 보낸다 — 화면과 다르면 서버가 거절한다.

/// 카드의 '다음부터도 자동으로' 내용(서버 `auto_rule_offer`). 없으면 그 카드는 자동으로 정할 수 없다.
class AutoRuleOffer {
  const AutoRuleOffer({
    required this.conditionText,
    required this.actionText,
    required this.fingerprint,
  });

  /// 예: "전자레인지 조리 완료가 확인됐을 때"
  final String conditionText;

  /// 예: "거실 공기청정기 풍량을 강으로 변경"
  final String actionText;
  final String fingerprint;

  static AutoRuleOffer? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final condition = json['condition_text'];
    final action = json['action_text'];
    final fp = json['fingerprint'];
    if (condition is! String || action is! String || fp is! String) return null;
    return AutoRuleOffer(conditionText: condition, actionText: action, fingerprint: fp);
  }
}

/// 루틴 목록의 자동 실행 규칙 한 줄(GET /routines/auto-rules).
class AutoRule {
  const AutoRule({
    required this.id,
    required this.name,
    required this.conditionText,
    required this.actionText,
    required this.enabled,
    required this.statusLabel,
    this.disabledReason,
    this.fingerprint,
    this.value,
    this.allowedValues = const [],
    this.lastRunNotices = const [],
  });

  final String id;
  final String name;
  final String conditionText;
  final String actionText;

  /// 서버가 허용 지문까지 맞다고 본 켜짐. 거짓이면 다시 허용해야 켜진다.
  final bool enabled;

  /// "자동 실행 켜짐" / "자동 실행 꺼짐" — 서버 문장 그대로.
  final String statusLabel;
  final String? disabledReason;

  /// 다시 허용할 때 보낼 지문(지금 등록된 대상 기기 기준). null이면 대상이 없어 켤 수 없다.
  final String? fingerprint;
  final String? value;

  /// 바꿀 수 있는 설정값(값, 사람 말 이름).
  final List<(String, String)> allowedValues;

  /// 마지막 자동 실행의 장치별 결과 문장(확인된 것만 '바꿨어요').
  final List<String> lastRunNotices;

  factory AutoRule.fromJson(Map<String, dynamic> json) {
    final last = json['last_run'];
    return AutoRule(
      id: json['id'] as String,
      name: json['name'] as String? ?? '자동 실행',
      conditionText: json['condition_text'] as String? ?? '',
      actionText: json['action_text'] as String? ?? '',
      enabled: json['enabled'] == true,
      statusLabel: json['status_label'] as String? ??
          (json['enabled'] == true ? '자동 실행 켜짐' : '자동 실행 꺼짐'),
      disabledReason: json['disabled_reason'] as String?,
      fingerprint: json['fingerprint'] as String?,
      value: json['value'] as String?,
      allowedValues: [
        for (final v in (json['allowed_values'] as List<dynamic>?) ?? const [])
          if (v is Map<String, dynamic> && v['value'] is String)
            (v['value'] as String, v['label'] as String? ?? v['value'] as String),
      ],
      lastRunNotices: last is Map<String, dynamic>
          ? [
              for (final n in (last['notices'] as List<dynamic>?) ?? const [])
                if (n is String) n,
            ]
          : const [],
    );
  }
}
