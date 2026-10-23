part of '../routines_screen.dart';

List<String> routineDoParts(Routine r, Map<String, String> applianceNames) {
  final pressTargets = <String>[];
  var presses = 0;
  final results = <String>[];
  for (final s in r.steps) {
    final name = routineApplianceName(applianceNames, s.applianceId);
    if (s.kind == RoutineStepKind.pressSequence) {
      if (!pressTargets.contains(name)) pressTargets.add(name);
      presses += s.buttons.length;
    }
    if (s.kind == RoutineStepKind.thinqCommand) {
      results.add(thinqResultPhrase(name, s.action, s.args));
    }
  }
  return [
    if (pressTargets.isNotEmpty) pressTargets.join(', '),
    if (presses > 0) '누를 버튼 $presses개',
    ...results,
  ];
}

/// LG 가전 단계 하나 → 결과 말('공기청정기 켜기'·'공기청정기 바람 세게'). 모르는 동작·값은 지어내지 않고 '바꾸기'.
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
      return '$name 운전 방식 바꾸기';
  }
  return '$name 설정 바꾸기';
}

/// 루틴 탭 시간축 묶음 — (키, 머리 말, 루틴들). 빈 묶음은 뺀다. 정해진 시각 묶음은 이른 시각부터.
/// 머리에 아이콘을 두지 않는다(평가 14차 10/18: 시계·손·종 장식이 줄 아이콘과 겹쳤다).
List<(String, String, List<Routine>)> _routineGroups(List<Routine> routines) {
  final timed = [for (final r in routines) if (routineClock(r) != null) r];
  // 'H:MM'도 'HH:MM'과 같은 자리로 비교한다.
  String sortKey(Routine r) => routineClock(r)!.padLeft(5, '0');
  final ordered = [...timed]..sort((a, b) => sortKey(a).compareTo(sortKey(b)));
  final manual = [
    for (final r in routines)
      if (routineClock(r) == null && r.trigger.kind == RoutineTriggerKind.manual) r,
  ];
  final other = [
    for (final r in routines)
      if (routineClock(r) == null && r.trigger.kind != RoutineTriggerKind.manual) r,
  ];
  return [
    if (ordered.isNotEmpty) ('time', '정해진 시각', ordered),
    if (manual.isNotEmpty) ('manual', '필요할 때', manual),
    if (other.isNotEmpty) ('event', '이럴 때', other),
  ];
}

/// 정해진 시각 루틴의 'HH:MM'. 시각이 없는 루틴은 null.
String? routineClock(Routine r) {
  if (r.trigger.kind == RoutineTriggerKind.time && (r.trigger.time ?? '').isNotEmpty) {
    return r.trigger.time;
  }
  // 목록의 루틴은 trigger 없이 서버 `when`('매일 22:00')만 올 수 있다.
  if (r.trigger.kind == RoutineTriggerKind.manual) {
    final m = RegExp(r'\b(\d{1,2}:\d{2})\b').firstMatch(r.when ?? '');
    if (m != null) return m.group(1);
  }
  return null;
}

/// 시간축 목록의 묶음 머리 — 굵은 말만(구역 머리로 위계를 준다, 카드로 감싸지 않는다).
class _GroupHead extends StatelessWidget {
  const _GroupHead({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpace.xl, bottom: AppSpace.xs),
        child: Semantics(
          header: true,
          child: Text(keepWordsTogether(label),
              semanticsLabel: label,
              style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appMuted)),
        ),
      );
}

/// 설정이 남은 루틴 줄의 오른쪽 글자 — '지금 하기'와 같은 두 낱말 꼴(평가 15차 10/18: '지금 하기'·'설정하기' 띄어쓰기가
/// 어긋나 보였다. '설정 하기'는 맞춤법에 어긋나 '설정 열기' — 누르면 그 가전 설정 화면이 열린다).
const kSetupActionLabel = '설정 열기';

/// 루틴 목록 위 표지 뜻 한 줄(결선 모의 평가 10/18) — (표지, 뜻, 강조색인가). 줄의 '다음'·'자동' 표지와 같은 모양으로 그린다.
const kRoutineMarkMeanings = [
  ('다음', '다음에 할 루틴', false),
  ('자동', '묻지 않고 해요', true),
];

/// 표지 뜻 한 줄의 낭독.
const kRoutineMarkLegend = "'다음'은 곧 할 루틴, '자동'은 묻지 않고 하는 루틴이에요";

/// 스위치 옆 상태 글자(접근성 감사 10/18 — 켜짐·꺼짐을 색만으로 말하지 않는다).
const kSwitchOnText = '켜짐';
const kSwitchOffText = '꺼짐';

/// 스위치 + 바로 아래 '켜짐'/'꺼짐'(접근성 감사 10/18) — 내 루틴·자동 규칙 같은 모양. 아래에 두어 이름 칸 폭을 줄이지 않는다.
/// 읽는 이름은 바깥 Semantics(toggled)가 말한다.
