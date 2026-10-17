/// 사용자 루틴 — 서버 `/routines` 문서(docs/devlog/devlog_2026-09-30-routines.md §2)의 거울.
///
/// **폰은 루틴을 실행하지 않는다.** 서버도 루틴 코드에는 실행 진입점이 없고, 실행은
/// 제안 카드 승인(`POST /suggestions/{id}/approve`) 하나로만 일어난다. 여기 있는
/// 것은 저장·편집·보여 주기용 모양뿐이다.
library;

/// 요일 이름(0=월 … 6=일). 서버 `WEEKDAY_LABELS`와 같다.
const kWeekdayLabels = ['월', '화', '수', '목', '금', '토', '일'];

/// 단계 종류.
enum RoutineStepKind {
  pressSequence('press_sequence'),
  thinqCommand('thinq_command'),
  announce('announce'),
  waitUntilDone('wait_until_done');

  const RoutineStepKind(this.value);
  final String value;

  static RoutineStepKind? parse(String? raw) {
    for (final k in RoutineStepKind.values) {
      if (k.value == raw) return k;
    }
    return null;
  }
}

class RoutineStep {
  const RoutineStep({
    required this.kind,
    this.applianceId,
    this.buttons = const [],
    this.action,
    this.args = const {},
    this.text,
    this.note,
  });

  const RoutineStep.press(String applianceId, List<String> buttons)
      : this(
          kind: RoutineStepKind.pressSequence,
          applianceId: applianceId,
          buttons: buttons,
        );

  const RoutineStep.wait(String applianceId)
      : this(kind: RoutineStepKind.waitUntilDone, applianceId: applianceId);

  /// ThinQ 가전 조작(2026-10-15) — 서버 `thinq_command` 단계. 동작·인자는 허브
  /// 대응표 이름 그대로(예: `set_wind_strength` · `{wind_strength: HIGH}`).
  const RoutineStep.thinq(
      String applianceId, String action, Map<String, dynamic> args)
      : this(
          kind: RoutineStepKind.thinqCommand,
          applianceId: applianceId,
          action: action,
          args: args,
        );

  const RoutineStep.announce(String text)
      : this(kind: RoutineStepKind.announce, text: text);

  final RoutineStepKind kind;
  final String? applianceId;

  /// press_sequence — 버튼 ID 또는 이름(서버가 적은 그대로 저장한다).
  final List<String> buttons;

  /// thinq_command
  final String? action;
  final Map<String, dynamic> args;

  /// announce
  final String? text;
  final String? note;

  /// 모르는 종류는 null — 목록 전체를 버리지 않고 그 단계만 건너뛴다.
  static RoutineStep? fromJson(Map<String, dynamic> json) {
    final kind = RoutineStepKind.parse(json['kind'] as String?);
    if (kind == null) return null;
    return RoutineStep(
      kind: kind,
      applianceId: json['appliance_id'] as String?,
      buttons: (json['buttons'] as List<dynamic>?)?.cast<String>() ?? const [],
      action: json['action'] as String?,
      args: (json['args'] as Map<String, dynamic>?) ?? const {},
      text: json['text'] as String?,
      note: json['note'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.value,
        if (applianceId != null) 'appliance_id': applianceId,
        if (kind == RoutineStepKind.pressSequence) 'buttons': buttons,
        if (kind == RoutineStepKind.thinqCommand) ...{
          'action': action,
          'args': args,
        },
        if (kind == RoutineStepKind.announce) 'text': text,
        if (note != null && note!.isNotEmpty) 'note': note,
      };

  RoutineStep copyWith({List<String>? buttons, String? text}) => RoutineStep(
        kind: kind,
        applianceId: applianceId,
        buttons: buttons ?? this.buttons,
        action: action,
        args: args,
        text: text ?? this.text,
        note: note,
      );
}

/// 트리거 종류.
enum RoutineTriggerKind {
  time('time'),
  approach('approach'),
  afterDone('after_done'),
  event('event'),
  manual('manual');

  const RoutineTriggerKind(this.value);
  final String value;

  static RoutineTriggerKind parse(String? raw) {
    for (final k in RoutineTriggerKind.values) {
      if (k.value == raw) return k;
    }
    return RoutineTriggerKind.manual;
  }
}

class RoutineTrigger {
  const RoutineTrigger({
    required this.kind,
    this.days = const [],
    this.time,
    this.zone,
    this.applianceId,
    this.routineId,
    this.event,
  });

  const RoutineTrigger.manual() : this(kind: RoutineTriggerKind.manual);

  final RoutineTriggerKind kind;

  /// time — 0=월 … 6=일
  final List<int> days;

  /// time — "HH:MM"
  final String? time;

  /// approach — arrival · room · near
  final String? zone;
  final String? applianceId;
  final String? routineId;
  final String? event;

  factory RoutineTrigger.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const RoutineTrigger.manual();
    return RoutineTrigger(
      kind: RoutineTriggerKind.parse(json['kind'] as String?),
      days: (json['days'] as List<dynamic>?)
              ?.whereType<num>()
              .map((d) => d.toInt())
              .toList() ??
          const [],
      time: json['time'] as String?,
      zone: json['zone'] as String?,
      applianceId: json['appliance_id'] as String?,
      routineId: json['routine_id'] as String?,
      event: json['event'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.value,
        if (kind == RoutineTriggerKind.time) ...{'days': days, 'time': time},
        if (zone != null) 'zone': zone,
        if (applianceId != null) 'appliance_id': applianceId,
        if (routineId != null) 'routine_id': routineId,
        if (event != null) 'event': event,
      };

  /// 화면 '언제' 줄. 서버 `describe`와 같은 말을 쓴다 -- 서버가 준 `when`이
  /// 있으면 그것이 먼저고, 이것은 아직 저장하지 않은 초안에서만 쓴다.
  String describe({
    Map<String, String> applianceNames = const {},
    Map<String, String> routineNames = const {},
  }) {
    switch (kind) {
      case RoutineTriggerKind.time:
        final sorted = [...days]..sort();
        final String dayText;
        if (sorted.length == 7) {
          dayText = '매일';
        } else if (_same(sorted, const [0, 1, 2, 3, 4])) {
          dayText = '평일';
        } else if (_same(sorted, const [5, 6])) {
          dayText = '주말';
        } else if (sorted.isEmpty) {
          dayText = '요일 없음';
        } else {
          dayText = sorted.map((d) => kWeekdayLabels[d]).join('·');
        }
        return '$dayText ${time ?? '--:--'}';
      case RoutineTriggerKind.approach:
        return switch (zone) {
          'arrival' => '집에 도착할 때',
          'room' => '방에 들어오면',
          _ => '가전 앞에 오면',
        };
      case RoutineTriggerKind.afterDone:
        if (routineId != null) {
          return "'${routineNames[routineId] ?? routineId}' 루틴이 끝나면";
        }
        return '${applianceNames[applianceId] ?? applianceId ?? '가전'} 동작이 끝나면';
      case RoutineTriggerKind.event:
        return knownEventLabel(event) ?? "가전 알림 '${event ?? ''}'이 오면";
      case RoutineTriggerKind.manual:
        return '직접 실행할 때';
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 서버가 아는 가전 알림(event)을 사람 말로. 모르는 값은 null(지어내지 않는다).
/// 서버 `ThinqEventRequest.event`(wash_complete·wash_start)와 같다.
String? knownEventLabel(String? event) => switch (event) {
      'wash_complete' => '세탁이 끝나면',
      'wash_start' => '세탁을 시작하면',
      _ => null,
    };

/// 실행 방식. **알림만(notify)은 어떤 경우에도 실행하지 않는다**(서버 규칙).
enum RoutineMode {
  approve('approve', '물어보고 하기'),
  notify('notify', '알림만');

  const RoutineMode(this.value, this.label);
  final String value;
  final String label;

  static RoutineMode parse(String? raw) =>
      raw == 'notify' ? RoutineMode.notify : RoutineMode.approve;
}

class Routine {
  const Routine({
    this.id,
    required this.name,
    required this.steps,
    this.trigger = const RoutineTrigger.manual(),
    this.conditions = const [],
    this.mode = RoutineMode.approve,
    this.enabled = true,
    this.icon,
    this.when,
    this.templateId,
    this.description,
    this.caution,
  });

  /// 저장 전 초안·템플릿은 null.
  final String? id;
  final String name;
  final List<RoutineStep> steps;
  final RoutineTrigger trigger;

  /// 조건은 편집기가 아직 고치지 않는다 -- 받은 그대로 되돌려 보내 잃지 않는다.
  final List<Map<String, dynamic>> conditions;
  final RoutineMode mode;
  final bool enabled;
  final String? icon;

  /// 서버가 쓴 '언제' 문장(예: "평일 07:30"). 초안에는 없다.
  final String? when;

  /// 예시 루틴(템플릿)이면 그 ID. 템플릿은 **사용자 데이터가 아니다.**
  final String? templateId;
  final String? description;
  final String? caution;

  bool get isTemplate => templateId != null;

  /// 버튼을 누르는 단계가 걸린 가전들(순서 유지, 중복 없음).
  List<String> get applianceIds {
    final seen = <String>[];
    for (final s in steps) {
      final id = s.applianceId;
      if (id != null && !seen.contains(id)) seen.add(id);
    }
    return seen;
  }

  /// 실제로 가전을 조작하는 단계(버튼 누름·ThinQ 명령)가 있는가.
  /// 알림·대기만 있는 루틴은 '실행하기'로 가전을 움직이지 않는다.
  bool get operatesAppliance => steps.any((s) =>
      s.kind == RoutineStepKind.pressSequence ||
      s.kind == RoutineStepKind.thinqCommand);

  /// 목록·홈에서 '실행하기'를 내걸 수 있는 루틴(2026-10-13): 저장된 사용자 루틴,
  /// 켜짐, 승인 후 실행, 가전 조작 단계 있음. 실행은 승인 카드를 만들 뿐이다.
  bool get isRunCandidate =>
      id != null &&
      !isTemplate &&
      enabled &&
      mode == RoutineMode.approve &&
      operatesAppliance;

  factory Routine.fromJson(Map<String, dynamic> json) => Routine(
        id: json['id'] as String?,
        name: json['name'] as String? ?? '',
        steps: [
          for (final s in (json['steps'] as List<dynamic>?) ?? const [])
            if (s is Map<String, dynamic>) RoutineStep.fromJson(s),
        ].whereType<RoutineStep>().toList(),
        trigger: RoutineTrigger.fromJson(json['trigger'] as Map<String, dynamic>?),
        conditions: [
          for (final c in (json['conditions'] as List<dynamic>?) ?? const [])
            if (c is Map<String, dynamic>) c,
        ],
        mode: RoutineMode.parse(json['mode'] as String?),
        enabled: json['enabled'] as bool? ?? true,
        icon: json['icon'] as String?,
        when: json['when'] as String?,
        templateId: json['template_id'] as String?,
        description: json['description'] as String?,
        caution: json['caution'] as String?,
      );

  /// `POST /routines`·`PUT /routines/{id}` 본문. id·시각은 서버가 정한다.
  Map<String, dynamic> toRequestJson() => {
        'name': name,
        if (icon != null) 'icon': icon,
        'steps': steps.map((s) => s.toJson()).toList(),
        'trigger': trigger.toJson(),
        'conditions': conditions,
        'mode': mode.value,
        'enabled': enabled,
      };

  Routine copyWith({
    String? name,
    List<RoutineStep>? steps,
    RoutineTrigger? trigger,
    RoutineMode? mode,
    bool? enabled,
  }) =>
      Routine(
        id: id,
        name: name ?? this.name,
        steps: steps ?? this.steps,
        trigger: trigger ?? this.trigger,
        conditions: conditions,
        mode: mode ?? this.mode,
        enabled: enabled ?? this.enabled,
        icon: icon,
        when: when,
        templateId: templateId,
        description: description,
        caution: caution,
      );

  /// 템플릿을 **새 루틴 초안**으로. 템플릿 ID를 떼어 사용자 것으로 저장하게 한다.
  Routine asNewDraft() => Routine(
        name: name,
        steps: steps,
        trigger: trigger,
        conditions: conditions,
        mode: mode,
        enabled: enabled,
        icon: icon,
        caution: caution,
      );
}

/// "다음 실행" 카드 한 장 — `GET /routines/next` 항목.
class RoutineNextRun {
  const RoutineNextRun({
    required this.routineId,
    required this.name,
    required this.at,
    required this.when,
    required this.modeLabel,
    this.auto = false,
    this.dayLabel = '',
  });

  final String routineId;
  final String name;
  final DateTime? at;
  final String when;
  final String modeLabel;

  /// 허용한 시각 규칙이 켜져 카드 없이 실행한다(2026-10-16). 옛 서버는 false.
  final bool auto;

  /// 오늘·내일·요일(2026-10-16). 옛 서버는 빈 문자열.
  final String dayLabel;

  factory RoutineNextRun.fromJson(Map<String, dynamic> json) => RoutineNextRun(
        routineId: json['routine_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        at: DateTime.tryParse(json['at'] as String? ?? '')?.toLocal(),
        when: json['when'] as String? ?? '',
        modeLabel: json['mode_label'] as String? ?? '',
        auto: json['auto'] as bool? ?? false,
        dayLabel: json['day_label'] as String? ?? '',
      );
}

/// '지금 실행' 결과. 승인 루틴은 **카드를 만들 뿐**이고 실행은 카드 승인 뒤다.
class RoutineTriggerResult {
  const RoutineTriggerResult({this.suggestionId, this.notice});

  /// 만들어진 제안 카드 ID. 알림 루틴이면 null.
  final String? suggestionId;

  /// 알림 루틴이 남긴 알림 문장(있으면).
  final String? notice;

  bool get madeCard => suggestionId != null;
}
