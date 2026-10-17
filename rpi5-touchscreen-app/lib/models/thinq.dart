/// ThinQ 가전 상태·공기질 — 키오스크용 순수 함수(2026-10-16, 사용자 요청).
///
/// 상태 줄·조작 표는 폰(`app/lib/widgets/thinq_state_card.dart`의 `thinqStateRows`·`kAirPurifierControls`)에서
/// 필요한 만큼만 옮겼다. 칸 이름·값 이름은 서버 대응표(`rpi/services/thinq/bindings.py`)·공기질 판정
/// (`rpi/services/air_quality.py`)과 같다 — 새로 짓지 않는다. 모르는 값은 원래 값 그대로 보이고(지어내지 않는다),
/// 등급은 **가전이 매긴 것**만 쓴다(우리 임계값 없음).
library;

/// 가전 등급 → 말(서버 `LEVEL_WORDS`와 같다).
const kAirGradeWords = {
  'GOOD': '좋음',
  'NORMAL': '보통',
  'BAD': '나쁨',
  'VERY_BAD': '매우 나쁨',
};

/// 이보다 오래된 공기질은 보이지 않는다(서버 `POWER_STALE_SECONDS`와 같다 — 서버도 거른다).
const kAirStaleSeconds = 600.0;

/// GET /thinq/air 한 줄 — 서버가 최근 조회로 아는 센서 공기질(클라우드를 새로 부르지 않는다).
class KioskAirReading {
  const KioskAirReading({
    required this.applianceId,
    required this.grade,
    this.pm25,
    this.pm25Level,
    this.gradeSource,
    this.pm10,
    this.pm10Level,
    this.power,
    this.ageSeconds = 0,
    this.mock = false,
  });

  final String applianceId;

  /// 가전이 매긴 등급(GOOD·NORMAL·BAD·VERY_BAD).
  final String grade;
  final num? pm25;

  /// 가전이 매긴 초미세먼지 등급(GOOD·NORMAL·BAD·VERY_BAD) — 종합 등급([grade])과 다를 수 있다.
  final String? pm25Level;

  /// 등급의 출처 — total(가전 종합 등급) · pm2(초미세먼지 등급) · null(모름).
  final String? gradeSource;
  final num? pm10;

  /// 가전이 매긴 미세먼지 등급 — 있으면 종합 등급이 왜 그런지 함께 보인다(UI 평가 4차 10/17).
  final String? pm10Level;

  /// on · off · null(모름).
  final String? power;
  final double ageSeconds;

  /// 모의(연습) 값인가 — 서버 execution_mode가 mock.
  final bool mock;

  /// 서버 항목 → 읽기. 등급을 모르거나 오래됐으면 null(보이지 않는다).
  static KioskAirReading? fromJson(Map<String, dynamic> json, {bool mock = false}) {
    final id = json['appliance_id'];
    final grade = json['grade'];
    if (id is! String || grade is! String || !kAirGradeWords.containsKey(grade)) {
      return null;
    }
    final age = json['age_s'];
    final ageSeconds = age is num ? age.toDouble() : 0.0;
    if (ageSeconds < 0 || ageSeconds > kAirStaleSeconds) return null;
    num? n(Object? v) => v is num ? v : null;
    final power = json['power'];
    return KioskAirReading(
      applianceId: id,
      grade: grade,
      pm25: n(json['pm25']),
      pm25Level: kAirGradeWords.containsKey(json['pm25_level']) ? json['pm25_level'] as String : null,
      gradeSource: json['grade_source'] is String ? json['grade_source'] as String : null,
      pm10: n(json['pm10']),
      pm10Level: kAirGradeWords.containsKey(json['pm10_level']) ? json['pm10_level'] as String : null,
      power: power == 'on' || power == 'off' ? power as String : null,
      ageSeconds: ageSeconds,
      mock: mock,
    );
  }

  String get gradeWord => kAirGradeWords[grade]!;

  /// 앞 글 — '실내 공기 좋음'.
  /// 가전 종합 등급이면 '종합'을 밝힌다 — 아래 초미세먼지 등급과 다를 수 있다(외부 평가 10/16 3차).
  String get headline => '실내 공기 ${isTotal ? '종합 ' : ''}$gradeWord';

  bool get isTotal => gradeSource == 'total';

  /// 뒤 글 — '초미세먼지 8 좋음 · 공기청정기 켜짐'. 아는 것만. 초미세먼지 등급을 붙여 종합 등급과 헷갈리지 않게 한다
  /// (외부 평가 10/16 2차 — 종합 '보통'과 초미세먼지 8이 모순처럼 읽혔다).
  List<String> get details => [
        // 미세먼지는 등급을 알 때만 — 종합 '보통'이 어디서 왔는지 보인다(UI 평가 4차 10/17).
        // 두 먼지 등급이 같으면 한 줄로(실패널 10/17 — 줄이 넷이면 마지막 줄이 잘렸다).
        if (pm10 != null && pm10Level != null && pm25 != null && pm25Level == pm10Level)
          '미세먼지 ${_num(pm10!)} · 초미세먼지 ${_num(pm25!)} ${kAirGradeWords[pm10Level]}'
        else ...[
          if (pm10 != null && pm10Level != null) '미세먼지 ${_num(pm10!)} ${kAirGradeWords[pm10Level]}',
          if (pm25 != null)
            '초미세먼지 ${_num(pm25!)}${pm25Level != null ? ' ${kAirGradeWords[pm25Level]}' : ''}',
        ],
        // 종합이 보이는 먼지 등급보다 나쁘면 그 이유를 지어내지 않고 출처만 밝힌다(실패널 10/17 — 모두 '좋음'인데 종합 '보통').
        if (_totalWorseThanShown) '종합은 가전이 매긴 등급',
        if (power == 'on') '공기청정기 켜짐',
        if (power == 'off') '공기청정기 꺼짐',
        if (mock) '연습 값',
      ];

  static const _gradeRank = {'GOOD': 0, 'NORMAL': 1, 'BAD': 2, 'VERY_BAD': 3};

  bool get _totalWorseThanShown {
    if (!isTotal) return false;
    final shown = [pm25Level, if (pm10 != null) pm10Level].whereType<String>().toList();
    if (shown.isEmpty) return false;
    final total = _gradeRank[grade] ?? 0;
    return shown.every((l) => (_gradeRank[l] ?? 0) < total);
  }

  /// 한 줄 전체(읽는 이름에도 쓴다).
  String get line => [headline, ...details].join(' · ');
}

String _num(num v) => v == v.roundToDouble() ? v.round().toString() : v.toString();

/// GET /thinq/status/{id} 결과. 실패면 [failure]에 이유(서버 문장)를 담고 값은 없다.
class KioskThinqStatus {
  const KioskThinqStatus({
    this.state,
    this.executionMode,
    this.readAt,
    this.failure,
  });

  final Object? state;
  final String? executionMode;
  final DateTime? readAt;
  final String? failure;

  bool get ok => failure == null;
  bool get mock => executionMode == 'mock';

  /// 칸 모양 상태(공기청정기·제습기). 세탁기처럼 목록이면 빈 맵.
  Map<String, dynamic> get stateMap =>
      state is Map ? Map<String, dynamic>.from(state as Map) : const {};
}

/// 상태 한 줄 — 이름·값, 공기질 줄이면 가전 등급(색).
class ThinqStateRow {
  const ThinqStateRow(this.label, this.value, {this.grade});
  final String label;
  final String value;
  final String? grade;
}

const _power = {'POWER_ON': '켜짐', 'POWER_OFF': '꺼짐'};
const _jobMode = {'CLEAN': '청정', 'SLEEP': '수면', 'AUTO': '자동', 'SILENT': '조용'};
const _wind = {'LOW': '약풍', 'MID': '중풍', 'HIGH': '강풍', 'AUTO': '자동', 'POWER': '파워'};

/// ThinQ 상태 → 줄. 아는 칸만 사람 말로, 없는 칸은 줄을 만들지 않는다(폰 `thinqStateRows`와 같은 칸·순서).
List<ThinqStateRow> thinqStateRows(Map<String, dynamic> state) {
  Object? at(String resource, String prop) {
    final r = state[resource];
    return r is Map ? r[prop] : null;
  }

  String word(Map<String, String> table, Object? v) => table[v?.toString()] ?? v.toString();

  final rows = <ThinqStateRow>[];
  final op = state['operation'];
  if (op is Map) {
    final key = op.keys.map((k) => k.toString()).where((k) => k.endsWith('OperationMode')).firstOrNull;
    if (key != null && op[key] != null) rows.add(ThinqStateRow('전원', word(_power, op[key])));
  }
  final job = at('airPurifierJobMode', 'currentJobMode');
  if (job != null) rows.add(ThinqStateRow('운전 모드', word(_jobMode, job)));
  final wind = at('airFlow', 'windStrengthDetail') ?? at('airFlow', 'windStrength');
  if (wind != null) rows.add(ThinqStateRow('풍량', word(_wind, wind)));

  void dust(String label, String value, String level) {
    final v = at('airQualitySensor', value);
    if (v == null) return;
    final l = at('airQualitySensor', level)?.toString();
    final known = l != null && kAirGradeWords.containsKey(l);
    rows.add(ThinqStateRow(label, l == null ? '$v' : '$v · ${kAirGradeWords[l] ?? l}',
        grade: known ? l : null));
  }

  dust('초미세먼지', 'PM2', 'PM2Level');
  dust('미세먼지', 'PM10', 'PM10Level');
  final filter = at('filterInfo', 'filterRemainPercent');
  if (filter != null) rows.add(ThinqStateRow('필터 남은 양', '$filter%'));
  return rows;
}

/// 공기청정기 전원이 꺼져 있다고 읽혔는가. 전원 칸이 없으면(모름) false.
bool thinqPowerOff(Map<String, dynamic> state) {
  final op = state['operation'];
  return op is Map && op['airPurifierOperationMode']?.toString() == 'POWER_OFF';
}

/// 공기청정기인데 미세먼지 값이 없을 때 이유 한 줄(폰 `thinqDustNote`와 같은 문장). 값이 있거나 공기청정기가 아니면 null.
String? thinqDustNote(Map<String, dynamic> state) {
  final op = state['operation'];
  if (op is! Map || op['airPurifierOperationMode'] == null) return null;
  final sensor = state['airQualitySensor'];
  final hasDust = sensor is Map && (sensor['PM2'] != null || sensor['PM10'] != null);
  if (hasDust) return null;
  return thinqPowerOff(state)
      ? '전원이 꺼져 있어 미세먼지 값이 오지 않아요'
      : '미세먼지 값을 아직 받지 못했어요(켠 직후에는 잠시 걸려요)';
}

/// 'HH:MM에 읽음' — 읽은 시각(연습이면 ' (연습)').
String thinqReadTimeLine(DateTime t, {bool mock = false}) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}에 읽음'
    '${mock ? ' (연습)' : ''}';

/// 조작 줄 하나 — 허브 동작 이름·인자와 고를 값들, 지금 값.
class ThinqControl {
  const ThinqControl({
    required this.label,
    required this.action,
    required this.arg,
    required this.choices,
    this.current,
  });

  final String label;
  final String action;
  final String arg;
  final List<(String, String)> choices;
  final String? current;

  ThinqControl withCurrent(String? current) =>
      ThinqControl(label: label, action: action, arg: arg, choices: choices, current: current);

  bool get isPower => action == 'set_power';

  /// 확인 질문 — '공기청정기 풍량을 강으로 바꿀까요?' · '공기청정기 전원을 켤까요?'.
  String question(String applianceName, String value, String word) => isPower
      ? '$applianceName 전원을 ${value == 'POWER_OFF' ? '끌까요' : '켤까요'}?'
      : '$applianceName $label${_eulReul(label)} $word${_ro(word)} 바꿀까요?';

  /// 실행 화면 제목 — '공기청정기 풍량 강으로 바꾸기' · '공기청정기 전원 켜기'.
  String doneLabel(String applianceName, String word) => isPower
      ? '$applianceName 전원 $word'
      : '$applianceName $label $word${_ro(word)} 바꾸기';
}

int? _jong(String word) {
  if (word.isEmpty) return null;
  final code = word.codeUnitAt(word.length - 1);
  if (code < 0xAC00 || code > 0xD7A3) return null;
  return (code - 0xAC00) % 28;
}

/// '으로'/'로' — 받침이 없거나 ㄹ이면 '로'. 한글이 아니면 '(으)로'.
String _ro(String word) {
  final j = _jong(word);
  if (j == null) return '(으)로';
  return j == 0 || j == 8 ? '로' : '으로';
}

String _eulReul(String word) => _jong(word) == 0 ? '를' : '을';

/// 키오스크의 공기청정기 조작 — 전원과 풍량만(사용자 요청 범위). 값은 폰 표·서버 대응표와 같다.
/// 이 모델이 허용하지 않는 값은 서버가 보내기 전에 거절한다(그 이유를 그대로 보인다).
const kKioskAirPurifierControls = <ThinqControl>[
  ThinqControl(
    label: '전원',
    action: 'set_power',
    arg: 'power',
    choices: [('POWER_ON', '켜기'), ('POWER_OFF', '끄기')],
  ),
  ThinqControl(
    label: '풍량',
    action: 'set_wind_strength',
    arg: 'wind_strength',
    choices: [('LOW', '약'), ('MID', '중'), ('HIGH', '강'), ('AUTO', '자동')],
  ),
];

/// 공기청정기 상태일 때만 조작 줄을 만든다(전원 칸이 없으면 지금 값을 모른다 — 빈 목록).
List<ThinqControl> thinqControlsFor(Map<String, dynamic> state) {
  final op = state['operation'];
  final power = op is Map ? op['airPurifierOperationMode']?.toString() : null;
  if (power == null) return const [];
  final flow = state['airFlow'];
  final wind = flow is Map ? (flow['windStrengthDetail'] ?? flow['windStrength'])?.toString() : null;
  final current = {'set_power': power, 'set_wind_strength': wind};
  return [for (final c in kKioskAirPurifierControls) c.withCurrent(current[c.action])];
}

/// 허브가 응답으로 거절한 조작의 문장(폰 `thinqCommandRefusal`과 같은 규칙). null이면 '결과를 모른다'.
String? thinqCommandRefusal(int statusCode, String detail) {
  const busy = '다른 작업이 실행 중이에요. 끝난 뒤 다시 눌러 주세요.';
  switch (statusCode) {
    case 401:
      return 'SimpleLay 본체가 이 화면을 받지 않았어요 — 본체 설정을 확인해 주세요.';
    case 409 || 412 || 422 || 423:
      final message = detail.trim();
      if (message.contains('already in progress')) return busy;
      if (message.isNotEmpty) return message;
      return statusCode == 409 ? busy : 'SimpleLay 본체가 이 조작을 지금 받지 않았어요.';
    default:
      return null;
  }
}

/// 응답 없이 끝난 조작 요청(시간 초과·연결 끊김) — 허브가 이미 받았을 수 있다.
const kThinqUnknownOutcome = '요청 결과를 확인하지 못했어요. 상태를 다시 읽어 확인해 주세요.';
