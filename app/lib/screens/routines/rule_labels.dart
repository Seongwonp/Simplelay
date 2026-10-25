part of '../routines_screen.dart';

class _Note extends StatelessWidget {
  const _Note(this.text, {super.key, this.textKey});
  final String text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
        // 낱말 단위로만 줄을 바꾼다(평가 10차 10/18). 낭독은 원문.
        // 끝 짧은 낱말은 앞 낱말과 함께 넘긴다(평가 16차 10/18: '끌 수 / 있어요').
        child: Text(keepActionNameTogether(text),
            key: textKey,
            semanticsLabel: text,
            style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
      );
}

/// 루틴에 붙은 시각 규칙 — 조건 종류가 시각이고, 본체가 규칙 이름으로 주는 루틴 이름과 시각이 이 루틴과 같은 것.
/// 본체 규칙 목록(`/routines/auto-rules`)에는 루틴 id가 없어 이름·시각으로만 잇는다 — 맞지 않으면 null(탭에 남는다).
AutoRule? routineAutoRule(Routine r, List<AutoRule> rules) {
  if (r.isTemplate || r.id == null) return null;
  final clock = routineClock(r);
  if (clock == null) return null;
  final matches = [
    for (final rule in rules)
      if (rule.isTime &&
          rule.name.trim() == r.name.trim() &&
          (rule.conditionTime == null || rule.conditionTime!.padLeft(5, '0') == clock.padLeft(5, '0')))
        rule,
  ];
  // 이름·시각이 같은 규칙이 둘이면 어느 쪽인지 모른다 — 잇지 않고 탭에 둔다.
  return matches.length == 1 ? matches.single : null;
}

/// '자동 규칙' 탭에 둘 규칙 — 루틴 줄에 닿지 않는 것 전부(사건 규칙, 루틴을 찾지 못한 시각 규칙).
List<AutoRule> standaloneAutoRules(List<AutoRule> rules, List<Routine> routines) {
  final count = <String, int>{};
  for (final r in routines) {
    final rule = routineAutoRule(r, rules);
    if (rule != null) count[rule.id] = (count[rule.id] ?? 0) + 1;
  }
  // 같은 규칙에 루틴 둘이 이어지면 어느 쪽인지 모른다 — 탭에도 둔다.
  return [for (final rule in rules) if (count[rule.id] != 1) rule];
}

/// 규칙 이름이 언제·무엇을 이미 다 말하는가(평가 14차 10/18: 카드 설명이 이름을 거의 되풀이했다).
///
/// 이름은 본체가 시나리오로 정해 값을 바꿔도 그대로다 — 그래서 바람 세기 규칙만, **지금 값의 말이 이름에 있을 때만** 참.
/// 이름이 '세게'인데 값이 중간이면 거짓(설명을 남긴다). 그 밖의 규칙은 설명을 둔다.
bool autoRuleNameSaysAll(AutoRule rule) {
  if (rule.isTime || rule.action != 'set_wind_strength') return false;
  final word = switch ((rule.value ?? '').toUpperCase()) {
    'HIGH' => '세게',
    'MID' => '중간',
    'LOW' => '약하게',
    _ => null,
  };
  return word != null && rule.name.contains(word);
}

/// 루틴 줄 스위치의 지금 값 — 루틴마다 '자동 실행' 하나(용어·스위치 통일 2026-10-25, 사용자 승인). 자동 규칙이 붙은
/// 루틴은 규칙과 루틴이 **둘 다** 켜져야 켜짐(한쪽만 켜진 '켰는데 안 도는' 상태를 켜짐으로 보이지 않는다).
bool autoRunSwitchOn(Routine r, AutoRule? rule) => rule == null ? r.enabled : rule.enabled && r.enabled;

/// 루틴 줄 스위치를 읽는 이름 — '실행 허용'·'루틴 켜기'로 나누지 않는다.
String autoRunSwitchLabel(Routine r) => '${r.name} 자동 실행';

/// 스위치 아래 한 줄 — 지금 값으로 실제 무엇이 되는지. 켜짐: 자동 규칙이 붙었으면 '매일 오후 10:00에 묻지 않고
/// 공기청정기를 켜요'(본체 문장), 묻는 루틴은 '시간이 되면 먼저 물어봐요', 알림만이면 '시간이 되면 알려 드려요'.
/// 꺼짐: '시간이 돼도 하지 않아요'.
String autoRunSwitchNote(Routine r, AutoRule? rule) {
  if (!autoRunSwitchOn(r, rule)) return '시간이 돼도 하지 않아요';
  if (rule != null) {
    return [withAmPmSpoken(rule.conditionText.trim(), rule.conditionTime), '묻지 않고', rule.actionText.trim()]
        .where((t) => t.isNotEmpty)
        .join(' ');
  }
  if (r.mode == RoutineMode.notify) return '시간이 되면 알려 드려요';
  return '시간이 되면 먼저 물어봐요';
}

/// 본체가 사용자가 끈 규칙에 붙이는 까닭(끝 마침표 뺌) — 이 말이면 배지 없이 스위치만.
const kUserOffReason = '자동 실행을 꺼 두셨어요';

/// 규칙 값 바꾸기 단추 이름 — 무엇의 값인지 말한다(UI 평가 3차 10/17: '세기'는 무엇의 세기인지 몰랐다).
///
/// 서버(bcc4cdb)가 규칙 문장에서 '풍량'을 뺐다 — 문장이 아니라 동작 이름으로 가른다(옛 서버는 문장으로).
String autoRuleValueLabel(AutoRule rule) =>
    rule.action == 'set_wind_strength' ||
            (rule.action == null && rule.actionText.contains('풍량'))
        ? '바람 세기 바꾸기'
        : '설정 바꾸기';

/// 규칙 한 문장 — 언제 + 무엇을(화살표 없이). 서버 문장이 '…면'·'…해요'로 이어 읽히게 만든다(2차 평가 10/18).
///
/// 본체 문장의 '매일 밤 10시에'는 그 규칙의 시각(`condition_time`)과 정확히 맞을 때만 '매일 오후 10:00에'로 —
/// 폰의 다른 시각과 같은 꼴(평가 8차 10/18). 맞지 않으면 본체 문장 그대로.
String autoRuleSentence(AutoRule rule) => [
      withAmPmSpoken(rule.conditionText.trim(), rule.conditionTime),
      rule.actionText.trim(),
    ].where((t) => t.isNotEmpty).join(' ');

/// [+ 새 루틴]에서 고른 것 — 빈 루틴이면 [template]이 null.
