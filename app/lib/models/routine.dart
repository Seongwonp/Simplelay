/// 사용자 루틴 — 서버 `/routines` 문서(docs/devlog/devlog_2026-09-30-routines.md §2)의 거울.
///
/// **폰은 루틴을 실행하지 않는다.** 서버도 루틴 코드에는 실행 진입점이 없고, 실행은
/// 제안 카드 승인(`POST /suggestions/{id}/approve`) 하나로만 일어난다. 여기 있는
/// 것은 저장·편집·보여 주기용 모양뿐이다.
library;

import 'clock_text.dart';

/// 요일 이름(0=월 … 6=일). 서버 `WEEKDAY_LABELS`와 같다.
const kWeekdayLabels = ['월', '화', '수', '목', '금', '토', '일'];

/// 본체에 없는(지운) 가전을 가리키는 루틴의 가전 이름 — 내부 ID('washer')를 화면에 내지 않는다(평가 10/19).
const kDeletedApplianceName = '지운 가전';

/// 루틴이 가리키는 가전의 보일 이름. 목록에 없으면 [kDeletedApplianceName], 가전을 정하지 않았으면 '가전'.
String routineApplianceName(Map<String, String> applianceNames, String? applianceId) =>
    applianceNames[applianceId] ?? (applianceId == null ? '가전' : kDeletedApplianceName);

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
          // 지운 루틴의 ID는 내지 않는다(평가 10/19).
          final routineName = routineNames[routineId];
          return routineName == null ? '앞 루틴이 끝나면' : "'$routineName' 루틴이 끝나면";
        }
        return '${routineApplianceName(applianceNames, applianceId)} 동작이 끝나면';
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
    this.atText = '',
    this.mode = '',
    this.quietSkip = false,
    this.skipped = false,
    this.skipLabel,
    this.skipActionLabel = '',
    this.afterSkipAtText = '',
    this.afterSkipDayLabel = '',
  });

  /// 건너뛴 회차 다음 회차의 본체 시각 원문(서버 `next_after_skip_at`, 2026-10-24). 옛 본체·건너뛰지 않음이면 빈 문자열.
  final String afterSkipAtText;

  /// 그 회차의 날짜 말('내일'·'○요일'·'다음 주 ○요일', 서버 `next_after_skip_day_label`). 폰이 날짜 말을 만들지 않는다.
  final String afterSkipDayLabel;

  /// 건너뛴 줄에 덧붙일 '다음은 내일 오후 10:00'(2026-10-24 사용자 평가 — 언제 다시 하는지 몰랐다).
  /// 시각은 [clock]과 같이 본체 벽시계 그대로. 본체가 값을 주지 않았으면 null(지어내지 않는다).
  String? get afterSkipText {
    if (!skipped || afterSkipDayLabel.isEmpty) return null;
    final m = RegExp(r'T(\d{2}):(\d{2})').firstMatch(afterSkipAtText);
    if (m == null || DateTime.tryParse(afterSkipAtText) == null) return null;
    return '다음은 $afterSkipDayLabel ${ampmClock('${m[1]}:${m[2]}')}';
  }

  /// '오늘은 건너뛰기'로 이 회차 한 번만 하지 않는다(서버 `skipped`, 2026-10-18). 옛 서버는 false.
  final bool skipped;

  /// 건너뛸 때 표시 말('오늘은 건너뛰어요'·'내일은 건너뛰어요'·'○요일은 건너뛰어요') — 본체 말 그대로(폰이 날짜 말을
  /// 만들지 않는다). 건너뛰지 않으면 null.
  final String? skipLabel;

  /// 건너뛰기 단추 말('오늘은 건너뛰기' 등) — 본체 말 그대로. 옛 서버는 빈 문자열(단추를 두지 않는다).
  final String skipActionLabel;

  /// 건너뛰기·되돌리기 단추를 둘 수 있는 회차 — 본체가 단추 말을 주고, 조용한 시간이라 어차피 하지 않는 회차가 아닐 때.
  bool get canSkip =>
      !quietSkip && routineId.isNotEmpty && atText.isNotEmpty && skipActionLabel.isNotEmpty;

  /// 건너뛴 회차의 표시 말. 본체가 말을 주지 않았으면 날짜를 지어내지 않고 '이번엔 건너뛰어요'.
  String get skipText => (skipLabel ?? '').isNotEmpty ? skipLabel! : '이번엔 건너뛰어요';

  /// 루틴 실행 방식 값('approve'·'notify'). 옛 서버는 빈 문자열.
  final String mode;

  /// 조용한 시간에 들어 이번엔 하지 않는다(서버 `quiet_skip`).
  final bool quietSkip;

  /// 다음 실행 줄·배지의 말 — 상태 말 하나로(평가 4차 10/18: '자동'·'자동 실행'·'자동으로 해요'가 섞였다).
  /// 서버 표시 말(`mode_label`)은 문장이 바뀌어 와도 화면 말이 흔들리지 않게 값으로 가른다.
  String get modeText {
    if (quietSkip) return '조용한 시간이라 안 해요';
    if (skipped) return skipText;
    if (auto) return '자동으로 해요';
    if (mode == RoutineMode.notify.value || modeLabel == RoutineMode.notify.label) return '알려 드려요';
    if (mode == RoutineMode.approve.value || modeLabel == '승인 후 실행') return '물어보고 해요';
    return modeLabel;
  }

  /// 본체가 준 시각 문자열 그대로(본체 시간대 오프셋 포함).
  final String atText;

  /// 화면에 쓸 'HH:MM' — **본체 벽시계 그대로**. [at]은 폰 시간대로 바뀐 값이라
  /// 폰(에뮬레이터 UTC)과 본체(+09:00)가 다르면 '매일 07:00'인데 22:00으로 그렸다(2차 평가 10/18).
  String get clock {
    final m = RegExp(r'T(\d{2}):(\d{2})').firstMatch(atText);
    if (m != null && DateTime.tryParse(atText) != null) return '${m[1]}:${m[2]}';
    return '--:--';
  }

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
        atText: json['at'] as String? ?? '',
        mode: json['mode'] as String? ?? '',
        quietSkip: json['quiet_skip'] == true,
        skipped: json['skipped'] == true,
        skipLabel: json['skip_label'] as String?,
        skipActionLabel: json['skip_action_label'] as String? ?? '',
        afterSkipAtText: json['next_after_skip_at'] is String ? json['next_after_skip_at'] as String : '',
        afterSkipDayLabel:
            json['next_after_skip_day_label'] is String ? json['next_after_skip_day_label'] as String : '',
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
