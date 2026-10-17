// 자동 실행 허용 규칙(서버 2026-10-13, 시연 v4) — 전자레인지 가열 종료 감지(조리 완료가 아닐 수 있음) → ThinQ 공기청정기 동작 하나.
//
// 규칙은 제안 카드에서 사용자가 '다음부터도 자동으로'를 고르고 조건·동작 확인을 본 뒤에만 생긴다.
// 서버가 낮은 위험 동작·모의/실물 출처·같은 사건 1회·비상정지를 강제한다. 폰은 서버가 준 문장을
// 그대로 보여 주고, 허용할 때 그 내용의 지문(`fingerprint`)을 함께 보낸다 — 화면과 다르면 서버가 거절한다.

/// 조건 판단의 한계 문장 — 서버가 `caveat` 칸을 보내지 않던 옛 서버(가열 종료 규칙뿐)의 문장(2026-10-16).
const kCookCaveat = '가전이 전기를 덜 쓰면 가열이 끝났다고 봐요. 요리가 다 된 건 아닐 수 있어요.';

/// 서버 `caveat` 칸 읽기 — 칸이 없으면(옛 서버) 가열 종료 문장, null이면 보이지 않음, 문자열이면 그대로.
String? caveatFrom(Map<String, dynamic> json) =>
    json.containsKey('caveat') ? json['caveat'] as String? : kCookCaveat;

/// 카드의 '다음부터도 자동으로' 내용(서버 `auto_rule_offer`). 없으면 그 카드는 자동으로 정할 수 없다.
class AutoRuleOffer {
  const AutoRuleOffer({
    required this.conditionText,
    required this.actionText,
    required this.fingerprint,
    this.caveat = kCookCaveat,
  });

  /// 예: "전자레인지 가열 종료가 감지됐을 때(조리 완료가 아닐 수 있어요)"
  final String conditionText;

  /// 예: "거실 공기청정기 풍량을 강으로 변경"
  final String actionText;
  final String fingerprint;

  /// 조건 판단의 한계(서버 문장, 2026-10-16 시각 규칙). null이면 보이지 않는다.
  final String? caveat;

  static AutoRuleOffer? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final condition = json['condition_text'];
    final action = json['action_text'];
    final fp = json['fingerprint'];
    if (condition is! String || action is! String || fp is! String) return null;
    return AutoRuleOffer(
        conditionText: condition, actionText: action, fingerprint: fp, caveat: caveatFrom(json));
  }
}

/// 루틴 목록의 자동 실행 규칙 한 줄(GET /routines/auto-rules).
class AutoRule {
  const AutoRule({
    required this.id,
    required this.name,
    required this.conditionText,
    this.caveat = kCookCaveat,
    required this.actionText,
    required this.enabled,
    required this.statusLabel,
    this.disabledReason,
    this.fingerprint,
    this.value,
    this.allowedValues = const [],
    this.lastRunNotices = const [],
    this.conditionTime,
    this.action,
  });

  /// 서버 동작 이름(`set_wind_strength`·`set_power` 등, 옛 서버는 null). 값 바꾸기 이름을 문장이 아니라 이것으로 가른다.
  final String? action;

  /// 시각 규칙의 'HH:MM'(서버 `condition_time`, 그 밖은 null) — 조용한 시간과 겹치는지 미리 말한다(UI 평가 6차 10/17).
  final String? conditionTime;

  final String id;
  final String name;
  final String conditionText;
  final String actionText;

  /// 조건 판단의 한계(서버 문장). null이면 보이지 않는다.
  final String? caveat;

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
      name: json['name'] as String? ?? '자동으로 하기',
      conditionText: json['condition_text'] as String? ?? '',
      actionText: json['action_text'] as String? ?? '',
      caveat: caveatFrom(json),
      enabled: json['enabled'] == true,
      statusLabel: json['status_label'] as String? ??
          // 화면은 이 값을 쓰지 않는다(배지는 enabled로) — 옛 서버 대비 기본값만 같은 말로.
          (json['enabled'] == true ? '자동으로 해요' : '지금은 안 해요'),
      disabledReason: json['disabled_reason'] as String?,
      fingerprint: json['fingerprint'] as String?,
      value: json['value'] as String?,
      conditionTime: json['condition_time'] is String ? json['condition_time'] as String : null,
      action: json['action'] is String ? json['action'] as String : null,
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
