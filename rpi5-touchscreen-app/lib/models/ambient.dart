/// 평소 화면이 읽는 서버 값 — `GET /ambient`·`GET /connections`·`GET /routines`.
///
/// 문구는 서버가 사용자 말로 만들어 보낸다(docs/devlog/devlog_2026-09-30-ambient-api.md).
/// 화면은 고르고 배치만 한다 -- 같은 사실을 폰과 다르게 말하지 않게.
library;

import 'josa.dart';
import 'kiosk_time.dart';

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
    this.hour,
    this.temp,
    this.pop,
    this.precip = false,
  });

  final String label;

  /// 칸 시각(0~23시, 서버 `hour`). 옛 서버면 칸 이름('15시')에서 읽는다. 모르면 null.
  final int? hour;

  /// 칸 시각 — [hour], 없으면 칸 이름에서.
  int? get slotHour => hour ?? _hourOfLabel(label);

  /// clear | partly | cloudy | rain | snow
  final String icon;
  final int? temp;
  final int? pop;

  /// 비·눈 칸 — 강조색으로 칠하고 강수확률을 보인다.
  final bool precip;

  factory AmbientHour.fromJson(Map<String, dynamic> json) => AmbientHour(
        label: json['label'] as String? ?? '',
        hour: (json['hour'] as num?)?.toInt() ?? _hourOfLabel(json['label'] as String?),
        icon: json['icon'] as String? ?? '',
        temp: (json['temp'] as num?)?.toInt(),
        pop: (json['pop'] as num?)?.toInt(),
        precip: json['precip'] as bool? ?? false,
      );
}

int? _hourOfLabel(String? label) {
  final m = RegExp(r'^(\d{1,2})시$').firstMatch((label ?? '').trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  return h <= 23 ? h : null;
}

class AmbientInfo {
  const AmbientInfo({
    required this.greeting,
    this.tip,
    this.hourly = const [],
    this.now,
    this.nowKnown = false,
    this.weatherSource = 'none',
    this.stale = false,
  });

  final String greeting;
  final AmbientTip? tip;
  final List<AmbientHour> hourly;

  /// 지금 날씨 한 칸(서버 `now`, 10/18) — 예보 1시간 칸 중 지금에 가장 가까운 것. 옛 서버·값 없음이면 null.
  final AmbientHour? now;

  /// 서버 응답에 `now` 키가 있었나(평가 15차 10/18). 있으면 그 값만 '지금' 칸으로 쓴다 — null이면 '지금' 칸이 없다
  /// (서버 '지금'은 날씨 안내 문장과 같은 정의다). 키가 없는 옛 서버일 때만 화면이 3시간 칸에서 대신 고른다.
  final bool nowKnown;

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
        now: json['now'] is Map<String, dynamic>
            ? AmbientHour.fromJson(json['now'] as Map<String, dynamic>)
            : null,
        nowKnown: json.containsKey('now'),
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
    // 할 일 두 단계(2차 평가 10/18) — 공유기 전원 → 본체 껐다 켜기. 다 하면 창의 '다시 연결해 보기'.
    fixes: [
      '공유기 전원이 켜져 있는지 봐 주세요.',
      '그래도 안 되면 본체 전원을 껐다가 다시 켜 주세요.',
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
    this.routineId,
    this.at,
    this.skipped = false,
    this.skipLabel,
    this.skipActionLabel,
    this.auto = false,
  });

  /// 카드 없이 자동으로 실행하는 회차(서버 `auto`, 허용한 시각 규칙). [kindLabel]은 옛 서버를 위해 `mode_label`('자동 실행')도 본다.
  final bool auto;

  /// 조용한 시간이라 이 회차를 건너뛴다(서버 `quiet_skip`, UI 평가 8차 10/17).
  final bool quietSkip;

  /// 서버 루틴 ID·회차 시각(ISO 원문) — '오늘은 건너뛰기' 요청 본문에 그대로 돌려보낸다(2026-10-18).
  final String? routineId;
  final String? at;

  /// 이 회차는 한 번 건너뛴다(서버 `skipped`, 2026-10-18). 회차가 지나기 전까지 되돌릴 수 있다.
  final bool skipped;

  /// 건너뛸 때 서버 말 — '오늘은 건너뛰어요'·'내일은 건너뛰어요'·'○요일은 건너뛰어요'. 키오스크는 날짜 말을 만들지 않는다.
  final String? skipLabel;

  /// 건너뛰기 단추 말(서버 `skip_action_label`) — '오늘은 건너뛰기' 등. 없으면(옛 서버) 단추를 두지 않는다.
  final String? skipActionLabel;

  /// 건너뛰기·되돌리기 단추를 둘 수 있나 — 서버가 회차를 알려 주고, 조용한 시간이라 이미 건너뛰는 회차가 아닐 때.
  bool get canSkip =>
      !quietSkip &&
      (routineId?.isNotEmpty ?? false) &&
      (at?.isNotEmpty ?? false) &&
      (skipped ? (skipLabel?.isNotEmpty ?? false) : (skipActionLabel?.isNotEmpty ?? false));

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
      routineId: json['routine_id'] is String ? json['routine_id'] as String : null,
      at: at,
      skipped: json['skipped'] == true,
      skipLabel: json['skip_label'] is String ? json['skip_label'] as String : null,
      skipActionLabel: json['skip_action_label'] is String ? json['skip_action_label'] as String : null,
      auto: json['auto'] == true,
    );
  }

  /// 평소 화면 시계 아래 줄의 '언제' — '오후 10:00'(오늘이면 날 말을 빼고), '내일 오전 7:00'.
  /// 분까지 쓴다 — 폰 루틴 화면('오후 10:00')과 같은 루틴이 다르게 보였다(평가 13차 10/18).
  String get whenShort =>
      [if (dayLabel.isNotEmpty && dayLabel != '오늘') dayLabel, clockHhmm(hhmm)].join(' ');

  /// 시계 아래 묶음의 작은 머리말(사용자 결정 10/18) — 무슨 루틴인지 사실대로. 카드 없이 자동으로 하는 회차만 '자동 루틴',
  /// 카드로 물어보는 회차는 '물어볼 루틴', 알림만이면 '알림 루틴'. 조용한 시간이라 건너뛰는 회차·모르는 방식은 '다음 루틴'.
  String get kindLabel {
    if (quietSkip) return '다음 루틴';
    if (auto || modeLabel == '자동 실행' || modeLabel == '자동') return '자동 루틴';
    return switch (modeLabel) {
      '승인 후 실행' => '물어볼 루틴',
      '알림만' => '알림 루틴',
      _ => '다음 루틴',
    };
  }

  /// 건너뛴 회차의 머리말 뒤 말 — '오늘은 안 해요'(2차 독립 평가 B, 10/18: 아래 '오늘은 건너뛰어요 · 되돌리기'만 바뀌고 위
  /// '오후 10:00 · 저녁 공기청정기 켜기'는 그대로라 '그래도 켜지나?'로 읽혔다). 건너뛰지 않았거나 조용한 시간 건너뜀이면 null.
  String? get skippedHead {
    if (!skipped || quietSkip) return null;
    return '${dayLabel.isEmpty ? '이번에는' : withTopic(dayLabel)} 안 해요';
  }

  /// 시계 아래 묶음의 작은 말 — 조용한 시간이면 그 이유, 건너뛰면 서버 말('오늘은 건너뛰어요'). 평소에는 없다
  /// (실행 방식은 머리말 [kindLabel]이 말한다 — '자동으로 해요'는 없앴다, 사용자 결정 10/18).
  String get statusWord {
    if (quietSkip) return '조용한 시간이라 건너뛰어요';
    // 건너뛴 회차는 머리말 [skippedHead]('오늘은 안 해요')가 말한다 — 끝 줄에 '오늘은 건너뛰어요'를 또 두지 않는다(10/19,
    // 같은 말 두 번). 끝 줄은 '되돌리기'만.
    return '';
  }

  /// 첫 줄은 언제, 둘째 줄은 무엇 — 이어 쓰면 '22:00 저녁 / 공기청정기 켜기'처럼 루틴 이름 첫 낱말이 시간대로
  /// 읽혔다(UI 평가 10/17).
  /// 조용한 시간이라 건너뛰면 긴 서버 말 대신 첫 줄에 '조용한 시간', 둘째 줄에 '건너뜀'(줄 길이를 늘리지 않게).
  String get line => '다음 루틴 · $when'
      '${quietSkip ? ' · 조용한 시간' : ''}\n'
      '${[name, if (quietSkip) '건너뜀' else if (modeWord.isNotEmpty) modeWord].join(' · ')}';

  /// 언제 — '오늘 오전 7시'(평가 4차 10/18: 시계는 오전/오후인데 루틴만 '07:00' 24시였다).
  String get when => [if (dayLabel.isNotEmpty) dayLabel, spokenHhmm(hhmm)].join(' ');

  /// 실행 방식 한 마디 — 자동 계열 이름은 '자동으로 해요' 하나로(평가 4차 10/18: '자동 실행'·'자동으로 하기'가 섞였다).
  /// 서버 말(`mode_label`)을 사람 말로만 바꾼다. 모르는 말은 그대로.
  String get modeWord => switch (modeLabel) {
        '자동 실행' || '자동' => '자동으로 해요',
        '승인 후 실행' => '물어보고 해요',
        _ => modeLabel,
      };

  /// 큰 글씨용 짧은 문장 — '오늘'·'루틴'을 빼고 실행 방식은 한 낱말로('다음 22:00 저녁 공기청정기 켜기 · 자동').
  String get shortLine => [
        '다음 ${[if (dayLabel.isNotEmpty && dayLabel != '오늘') dayLabel, spokenHhmm(hhmm)].join(' ')} $name',
        if (quietSkip) '건너뜀' else if (modeWord.isNotEmpty) modeWord,
      ].join(' · ');
}

/// '오늘은 건너뛰기'·'되돌리기' 요청의 결과(2026-10-18). [item]이 있으면 성공(바뀐 항목), 아니면 [message]를 짧게 보인다.
class KioskSkipResult {
  const KioskSkipResult({this.item, this.message, this.reload = false});

  final KioskNextRun? item;

  /// 실패 안내 — 409·404·422는 서버의 한국어 `detail` 그대로, 그 밖에는 아래 두 말 중 하나.
  final String? message;

  /// 다음 루틴을 다시 불러와야 하나(409 — 회차가 지났거나 바뀌었다, 404 — 루틴이 없어졌다).
  final bool reload;

  static const failed = '바꾸지 못했어요. 잠시 뒤 다시 눌러 주세요';
  static const unreachable = '본체에 닿지 못했어요. 잠시 뒤 다시 눌러 주세요';
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
    this.thinqSteps = const [],
    this.mode = 'approve',
    this.enabled = true,
  });

  final String id;
  final String name;

  /// 단계들이 다루는 가전(순서대로, 중복 없음).
  final List<String> applianceIds;

  /// 누름 장치가 누를 버튼 수(버튼 누르기 단계들의 버튼 합).
  final int pressCount;

  /// ThinQ로 바꾸는 가전 설정 단계 수(누르지 않는다).
  final int settingCount;

  /// LG 가전 단계들(순서대로) — 결과 말('공기청정기 켜기')을 만드는 데 쓴다.
  final List<KioskThinqStep> thinqSteps;

  /// 루틴 카드 아래 한 마디(2026-10-15 B3) — 예전 'N단계'는 실제로 버튼 수 합계였다.
  /// 평가 6차(10/18, 폰 평가 5차와 같은 말): '버튼 2번'은 한 버튼을 두 번 누르는 것으로 읽혔다 → '누를 버튼 N개',
  /// 'LG 가전 설정 1번'은 무엇이 되는지 말하지 않았다 → 결과 말('공기청정기 켜기'). 알림만 루틴은 '알림만'.
  /// [names]는 가전 id → 이름(모르면 'LG 가전').
  String sizeLabelWith(Map<String, String> names) {
    if (mode == 'notify') return '알림만';
    final results = [
      for (final s in thinqSteps) thinqResultPhrase(names[s.applianceId] ?? 'LG 가전', s.action, s.args),
    ];
    // 단계 내용 없이 수만 받은 경우(옛 생성 경로) — 지어내지 않고 '바꾸기'.
    final unnamed = settingCount - thinqSteps.length;
    return [
      if (pressCount > 0) '누를 버튼 $pressCount개',
      ...results,
      for (var i = 0; i < unnamed; i++) 'LG 가전 바꾸기',
    ].join(' · ');
  }

  String get sizeLabel => sizeLabelWith(const {});

  /// approve(승인 후 실행) | notify(알림만)
  final String mode;
  final bool enabled;

  bool involves(String applianceId) => applianceIds.contains(applianceId);

  factory KioskRoutine.fromJson(Map<String, dynamic> json) {
    final ids = <String>[];
    var presses = 0;
    var settings = 0;
    final thinq = <KioskThinqStep>[];
    for (final s in (json['steps'] as List<dynamic>?) ?? const []) {
      if (s is! Map<String, dynamic>) continue;
      final id = s['appliance_id'];
      if (id is String && !ids.contains(id)) ids.add(id);
      final buttons = s['buttons'];
      if (buttons is List) presses += buttons.length;
      if (s['kind'] == 'thinq_command') {
        settings++;
        final args = s['args'];
        thinq.add(KioskThinqStep(
          applianceId: id is String ? id : null,
          action: s['action'] as String?,
          args: args is Map<String, dynamic> ? args : const {},
        ));
      }
    }
    return KioskRoutine(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      applianceIds: ids,
      pressCount: presses,
      settingCount: settings,
      thinqSteps: thinq,
      mode: json['mode'] as String? ?? 'approve',
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

/// 루틴의 LG 가전 단계 하나(서버 `thinq_command` 단계의 가전·동작·값).
class KioskThinqStep {
  const KioskThinqStep({this.applianceId, this.action, this.args = const {}});

  final String? applianceId;
  final String? action;
  final Map<String, dynamic> args;
}

/// LG 가전 단계 하나 → 결과 말('공기청정기 켜기'·'공기청정기 바람 세게') — 폰 `thinqResultPhrase`와 같은 말.
/// 모르는 동작·값은 지어내지 않고 '바꾸기'.
String thinqResultPhrase(String name, String? action, Map<String, dynamic> args) {
  switch (action) {
    case 'set_power':
      final v = '${args['power'] ?? ''}'.toUpperCase();
      if (v == 'POWER_ON' || v == 'ON') return '$name 켜기';
      if (v == 'POWER_OFF' || v == 'OFF') return '$name 끄기';
      return '$name 전원 바꾸기';
    case 'set_wind_strength':
      final word = switch ('${args['wind_strength'] ?? ''}'.toUpperCase()) {
        'HIGH' => '세게',
        'MID' => '중간으로',
        'LOW' => '약하게',
        'AUTO' => '자동으로',
        _ => null,
      };
      return word == null ? '$name 바람 세기 바꾸기' : '$name 바람 $word';
    case 'set_job_mode':
      return '$name 모드 바꾸기';
  }
  return '$name 바꾸기';
}
