/// 평소 화면이 읽는 서버 값 — `GET /ambient`·`GET /connections`·`GET /routines`.
///
/// 문구는 서버가 사용자 말로 만들어 보낸다(docs/devlog/devlog_2026-09-30-ambient-api.md).
/// 화면은 고르고 배치만 한다 -- 같은 사실을 폰과 다르게 말하지 않게.
library;

/// `GET /ambient`의 안내 한 줄. 우선순위(위험 소리 → 확인 필요 가전 → 최근 루틴 안내 → 날씨 → 없음)는 서버가 정한다.
class AmbientTip {
  const AmbientTip({required this.kind, required this.text, required this.icon});

  /// appliance | alert | routine | rain | snow | heat | cold
  final String kind;
  final String text;

  /// attention | notice | rain | snow | hot | cold
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

  /// 화면이 SimpleLay 본체(서버)에 닿지 못할 때 대신 세우는 와이파이 항목. 서버 문구가 없으니
  /// 여기서 같은 말투로 쓴다 -- 무엇을 못 하게 되는지까지. '허브' 대신 'SimpleLay 본체'(2026-10-15 용어표).
  static const hubUnreachable = ConnectionItem(
    id: 'network',
    state: 'error',
    title: '본체와 연결되지 않았어요',
    message: '지금은 가전을 눌러 드릴 수 없어요.',
    fixes: [
      '본체 전원이 켜져 있는지 봐 주세요.',
      "잠시 뒤 '새로 보기'를 눌러 주세요.",
    ],
    source: 'kiosk',
  );
}

/// `GET /routines/next` 첫 항목 — 평소 화면 '다음 루틴' 한 줄(외부 평가 10/16 2차 k01).
/// 서버가 정한 말(오늘·내일·요일, 실행 방식)을 그대로 쓴다. 시각은 서버 시각 문자열의 HH:MM이다.
class KioskNextRun {
  const KioskNextRun({
    required this.name,
    required this.dayLabel,
    required this.hhmm,
    required this.modeLabel,
    this.quietSkip = false,
  });

  /// 조용한 시간이라 이 회차를 건너뛴다(서버 `quiet_skip`, UI 평가 8차 10/17).
  final bool quietSkip;

  final String name;
  final String dayLabel;
  final String hhmm;
  final String modeLabel;

  /// 이름이나 시각을 모르면 null(줄을 두지 않는다).
  static KioskNextRun? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final at = json['at'];
    if (name is! String || name.isEmpty || at is! String || at.length < 16) return null;
    final hhmm = at.substring(11, 16);
    if (!RegExp(r'^\d\d:\d\d$').hasMatch(hhmm)) return null;
    final day = json['day_label'];
    final mode = json['mode_label'];
    return KioskNextRun(
      name: name,
      dayLabel: day is String ? day : '',
      hhmm: hhmm,
      modeLabel: mode is String ? mode : '',
      quietSkip: json['quiet_skip'] == true,
    );
  }

  /// 첫 줄은 언제, 둘째 줄은 무엇 — 이어 쓰면 '22:00 저녁 / 공기청정기 켜기'처럼 루틴 이름 첫 낱말이 시간대로
  /// 읽혔다(UI 평가 10/17).
  /// 조용한 시간이라 건너뛰면 긴 서버 말 대신 첫 줄에 '조용한 시간', 둘째 줄에 '건너뜀'(줄 길이를 늘리지 않게).
  String get line => '다음 루틴 · ${[if (dayLabel.isNotEmpty) dayLabel, hhmm].join(' ')}'
      '${quietSkip ? ' · 조용한 시간' : ''}\n'
      '${[name, if (quietSkip) '건너뜀' else if (modeLabel.isNotEmpty) modeLabel].join(' · ')}';

  /// 큰 글씨용 짧은 문장 — '오늘'·'루틴'을 빼고 실행 방식은 한 낱말로('다음 22:00 저녁 공기청정기 켜기 · 자동').
  String get shortLine => [
        '다음 ${[if (dayLabel.isNotEmpty && dayLabel != '오늘') dayLabel, hhmm].join(' ')} $name',
        if (quietSkip) '건너뜀' else if (modeLabel == '자동 실행') '자동' else if (modeLabel.isNotEmpty) modeLabel,
      ].join(' · ');
}

/// `GET /routines` 한 항목 — 키오스크는 이름과 대상 가전, 누를 버튼 수만 쓴다.
/// 만들기·고치기는 휴대폰 앱에서 한다(UI 확정 §3-4).
class KioskRoutine {
  const KioskRoutine({
    required this.id,
    required this.name,
    this.applianceIds = const [],
    this.pressCount = 0,
    this.settingCount = 0,
    this.mode = 'approve',
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 단계들이 다루는 가전(순서대로, 중복 없음).
  final List<String> applianceIds;

  /// 작은 팔이 누를 버튼 수(버튼 누르기 단계들의 버튼 합).
  final int pressCount;

  /// ThinQ로 바꾸는 가전 설정 단계 수(누르지 않는다).
  final int settingCount;

  /// 루틴 카드 오른쪽 한 마디(2026-10-15 B3) — 예전 'N단계'는 실제로 버튼 수 합계였다.
  /// 알림만 루틴은 '알림만', 누를 버튼은 '버튼 N번', ThinQ 설정은 '가전 설정 N번'.
  String get sizeLabel {
    if (mode == 'notify') return '알림만';
    return [
      if (pressCount > 0) '버튼 $pressCount번',
      if (settingCount > 0) '가전 설정 $settingCount번',
    ].join(' · ');
  }

  /// approve(승인 후 실행) | notify(알림만)
  final String mode;
  final bool enabled;

  bool involves(String applianceId) => applianceIds.contains(applianceId);

  factory KioskRoutine.fromJson(Map<String, dynamic> json) {
    final ids = <String>[];
    var presses = 0;
    var settings = 0;
    for (final s in (json['steps'] as List<dynamic>?) ?? const []) {
      if (s is! Map<String, dynamic>) continue;
      final id = s['appliance_id'];
      if (id is String && !ids.contains(id)) ids.add(id);
      final buttons = s['buttons'];
      if (buttons is List) presses += buttons.length;
      if (s['kind'] == 'thinq_command') settings++;
    }
    return KioskRoutine(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      applianceIds: ids,
      pressCount: presses,
      settingCount: settings,
      mode: json['mode'] as String? ?? 'approve',
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}
