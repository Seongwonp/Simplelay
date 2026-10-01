/// 평소 화면이 읽는 서버 값 — `GET /ambient`·`GET /connections`·`GET /routines`.
///
/// 문구는 서버가 사용자 말로 만들어 보낸다(docs/devlog_2026-09-30-ambient-api.md).
/// 화면은 고르고 배치만 한다 -- 같은 사실을 폰과 다르게 말하지 않게.
library;

/// `GET /ambient`의 안내 한 줄. 우선순위(확인 필요 가전 → 날씨 → 없음)는 서버가 정한다.
class AmbientTip {
  const AmbientTip({required this.kind, required this.text, required this.icon});

  /// appliance | alert | rain | snow | heat | cold
  final String kind;
  final String text;

  /// attention | rain | snow | hot | cold
  final String icon;

  factory AmbientTip.fromJson(Map<String, dynamic> json) => AmbientTip(
        kind: json['kind'] as String? ?? '',
        text: json['text'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
      );
}

/// 시간대 예보 한 칸.
class AmbientHour {
  const AmbientHour({
    required this.label,
    required this.icon,
    this.temp,
    this.pop,
    this.precip = false,
  });

  final String label;

  /// clear | partly | cloudy | rain | snow
  final String icon;
  final int? temp;
  final int? pop;

  /// 비·눈 칸 — 강조색으로 칠하고 강수확률을 보인다.
  final bool precip;

  factory AmbientHour.fromJson(Map<String, dynamic> json) => AmbientHour(
        label: json['label'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
        temp: (json['temp'] as num?)?.toInt(),
        pop: (json['pop'] as num?)?.toInt(),
        precip: json['precip'] as bool? ?? false,
      );
}

class AmbientInfo {
  const AmbientInfo({
    required this.greeting,
    this.tip,
    this.hourly = const [],
    this.weatherSource = 'none',
    this.stale = false,
  });

  final String greeting;
  final AmbientTip? tip;
  final List<AmbientHour> hourly;

  /// kma | mock | none
  final String weatherSource;
  final bool stale;

  factory AmbientInfo.fromJson(Map<String, dynamic> json) => AmbientInfo(
        greeting: json['greeting'] as String? ?? '',
        tip: json['tip'] is Map<String, dynamic>
            ? AmbientTip.fromJson(json['tip'] as Map<String, dynamic>)
            : null,
        hourly: [
          for (final h in (json['hourly'] as List<dynamic>?) ?? const [])
            if (h is Map<String, dynamic>) AmbientHour.fromJson(h),
        ],
        weatherSource: json['weather_source'] as String? ?? 'none',
        stale: json['stale'] as bool? ?? false,
      );
}

/// `GET /connections` 한 항목(와이파이·누름 장치·플러그).
class ConnectionItem {
  const ConnectionItem({
    required this.id,
    required this.state,
    required this.title,
    required this.message,
    this.fixes = const [],
    this.source = 'none',
  });

  /// network | press | plug
  final String id;

  /// ok | warn | error | not_installed | unknown
  final String state;
  final String title;
  final String message;
  final List<String> fixes;

  /// 확인용(real | mock | none | sysfs | server). 화면 문구로 쓰지 않는다.
  final String source;

  /// "!" 배지를 붙일 상태인가. 모름(unknown)은 회색과 별도 문구로 알린다 --
  /// 확인하지 못한 연결을 정상처럼 회색으로 두지 않는다. 설치 안 됨은 문제가
  /// 아니라 아직 없는 것이라 배지를 붙이지 않는다(누르면 설명은 열린다).
  bool get needsAttention =>
      state == 'warn' || state == 'error';

  factory ConnectionItem.fromJson(Map<String, dynamic> json) => ConnectionItem(
        id: json['id'] as String? ?? '',
        state: json['state'] as String? ?? 'unknown',
        title: json['title'] as String? ?? '',
        message: json['message'] as String? ?? '',
        fixes: (json['fixes'] as List<dynamic>?)?.whereType<String>().toList() ??
            const [],
        source: json['source'] as String? ?? 'none',
      );

  /// 화면이 허브에 닿지 못할 때 대신 세우는 와이파이 항목. 서버 문구가 없으니
  /// 여기서 같은 말투로 쓴다 -- 무엇을 못 하게 되는지까지.
  static const hubUnreachable = ConnectionItem(
    id: 'network',
    state: 'error',
    title: '허브와 연결되지 않았어요',
    message: '화면이 허브에 닿지 못하고 있어요. 지금은 가전을 대신 눌러 드릴 수 없고, '
        '날씨 안내도 볼 수 없어요.',
    fixes: [
      '허브 전원이 켜져 있는지 확인해 주세요.',
      "잠시 뒤 '다시 연결하기'를 눌러 주세요.",
    ],
    source: 'kiosk',
  );
}

/// `GET /routines` 한 항목 — 키오스크는 이름과 대상 가전, 단계 수만 쓴다.
/// 편집·녹화는 폰 앱에서 한다(UI 확정 §3-4).
class KioskRoutine {
  const KioskRoutine({
    required this.id,
    required this.name,
    this.applianceIds = const [],
    this.stepCount = 0,
    this.mode = 'approve',
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 단계들이 다루는 가전(순서대로, 중복 없음).
  final List<String> applianceIds;

  /// 누를 버튼 수(버튼 누르기 단계의 합). 버튼이 없는 루틴은 단계 수.
  final int stepCount;

  /// approve(승인 후 실행) | notify(알림만)
  final String mode;
  final bool enabled;

  bool involves(String applianceId) => applianceIds.contains(applianceId);

  factory KioskRoutine.fromJson(Map<String, dynamic> json) {
    final ids = <String>[];
    var presses = 0;
    var steps = 0;
    for (final s in (json['steps'] as List<dynamic>?) ?? const []) {
      if (s is! Map<String, dynamic>) continue;
      steps++;
      final id = s['appliance_id'];
      if (id is String && !ids.contains(id)) ids.add(id);
      final buttons = s['buttons'];
      if (buttons is List) presses += buttons.length;
    }
    return KioskRoutine(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      applianceIds: ids,
      stepCount: presses > 0 ? presses : steps,
      mode: json['mode'] as String? ?? 'approve',
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}
