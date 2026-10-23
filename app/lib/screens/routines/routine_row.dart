part of '../routines_screen.dart';

class _RoutineRow extends StatelessWidget {
  const _RoutineRow({
    required this.routine,
    required this.applianceNames,
    required this.onEdit,
    required this.onRun,
    required this.running,
    required this.busy,
    required this.error,
    this.applianceIcons = const {},
    this.onSetup,
    this.next,
    this.auto = false,
    this.autoRule,
    this.onAuto,
    this.onToggle,
    this.switchOn = false,
    this.switchLabel = '',
    this.toggling = false,
  });

  /// 정해진 시각 루틴의 켜기·끄기(보호자 과업 평가 10/18). null이면 스위치를 두지 않는다.
  final ValueChanged<bool>? onToggle;

  /// 스위치의 지금 값 — 자동 규칙이 붙었으면 그 규칙의 켜짐, 아니면 루틴 켜짐.
  final bool switchOn;

  /// 스위치를 읽는 이름('○○ 자동으로 하기' / '○○ 루틴 켜기').
  final String switchLabel;

  /// 바꾸는 중 — 두 번 누르지 않게 잠근다.
  final bool toggling;

  /// 묻지 않고 하는 시각 루틴(본체 /routines/next의 auto) — 홈 '다음' 카드와 같은 '자동' 표시.
  final bool auto;

  /// 이 루틴에 붙은 시각 자동 규칙([routineAutoRule]). 있으면 '자동'/'자동 꺼짐' 표시가 그 규칙의 켜짐을 따르고, 누를 수 있다.
  final AutoRule? autoRule;

  /// '자동' 표시를 누르면 — 그 규칙 스위치(시트). null이면 누를 수 없다.
  final VoidCallback? onAuto;

  /// 이 루틴이 다음에 할 일이면 그 예약 — 줄에 '다음' 배지(조용한 시간이라 건너뛰면 그 말).
  final RoutineNextRun? next;

  /// 가전 id → 아이콘. 줄 아이콘을 대상 가전 아이콘으로(평가 3차 10/18).
  final Map<String, IconData> applianceIcons;

  /// 설정이 필요한 가전의 상세로 — 있으면 '실행' 대신 '설정하기' 단추(홈과 같다).
  final VoidCallback? onSetup;

  final Routine routine;
  final Map<String, String> applianceNames;

  /// 행 전체 탭 = 편집(상세). 지우기도 그 안(확인 대화를 한 번 더 받는다).
  final VoidCallback onEdit;

  /// null이면 실행 단추를 두지 않는다(알림만·꺼짐·템플릿·가전 조작 없음).
  final VoidCallback? onRun;

  /// 이 행의 카드 요청 중.
  final bool running;

  /// 어느 행이든 카드 요청 중(다른 행 실행도 잠근다).
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final r = routine;
    final key = r.id ?? r.templateId ?? r.name;
    // 큰 글씨에서는 단추를 이름 아래로 — 한 줄에 두면 이름이 한 글자씩 꺾인다.
    final big = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    // 오른쪽 '지금 하기 >'는 글씨가 보통일 때만 이름 옆에 — 글씨를 조금만 키워도 이름 칸이 좁아진다.
    final inline = MediaQuery.textScalerOf(context).scale(1) <= 1.15;
    // 한 줄 구성(평가 10차 10/18) — 모든 줄이 같은 꼴: 이름 → 그 아래 한 줄 '언제 · 무슨 가전' + 표시(다음·자동으로 해요·
    // 알려 드려요). 예전에는 시각 줄만 시각이 이름 위에 있고 가전이 없어, 줄마다 모양과 '지금 하기' 높이가 달랐다.
    // 예시 루틴은 설명 문장이 그 한 줄이다.
    final line = r.isTemplate
        ? ((r.description ?? '').isNotEmpty ? r.description! : routineSubtitle(r, applianceNames))
        : routineListLine(r, applianceNames);
    final n = next;
    // 표지(평가 17차 10/18) — 이름 옆 작은 테두리 글자. 설명 줄 끝에 ' · '로 잇지 않는다.
    final notify = !r.isTemplate && r.mode == RoutineMode.notify && r.enabled;
    // 자동 표지 — 규칙이 있으면 규칙 켜짐, 없으면 본체 /routines/next의 auto.
    final autoOn = autoRule?.enabled ?? auto;
    final skipping = (n?.quietSkip ?? false) || (n?.skipped ?? false);
    // 스위치가 이 루틴 자체의 켜짐을 말하나(붙은 자동 규칙이 없을 때).
    final offBySwitch = onToggle != null && autoRule == null;
    final autoKey = GlobalObjectKey(this);
    // '다음' — 위에 따로 '다음: …' 줄을 두지 않고 그 줄에 붙인다. 조용한 시간이라 건너뛰면 그 말로.
    final Widget? nextMark = n == null
        ? null
        : _LineMark(
            key: Key('routine-next-badge-$key'),
            // 한 번 건너뛴 회차(2026-10-18)는 본체 말 '오늘은 건너뛰어요'(modeText) — 바로 옆 '되돌리기'와 짝.
            label: skipping ? n.modeText : '다음',
            // 건너뛰는 회차는 흐린 테두리 + 빈 달력 — 켜진 자동(면 + 번개)과 모양으로 갈린다(UI 정리 10/19).
            icon: skipping ? Icons.event_busy : null,
            muted: skipping,
          );
    // 건너뛰는 회차 표지는 이름 옆이 아니라 아래 건너뛰기 줄에서 '되돌리기'와 한 줄(평가 10/19: 이름 옆 표지가
    // '오늘은 건너뛰어요'·'자동 꺼짐' 두 줄로 쌓이고, '되돌리기'는 '지금 하기' 아래 혼자 떨어져 무엇을 되돌리는지 몰랐다).
    final skipLine = skipping && !r.isTemplate;
    final badges = <Widget>[
      if (nextMark != null && !skipLine) nextMark,
      // 홈 '다음' 카드와 같은 '자동'. 규칙이 있으면 그 켜짐이 먼저 — 꺼 둔 규칙도 '자동 꺼짐'으로 이 줄에서 닿는다.
      if (!r.isTemplate && (autoRule != null || (auto && !(n?.quietSkip ?? false) && !(n?.skipped ?? false))))
        KeyedSubtree(
          key: Key('routine-auto-badge-$key'),
          child: _LineMark(
            key: autoKey,
            label: autoOn ? '자동' : '자동 꺼짐',
            semanticLabel: autoOn
                ? '자동 루틴${onAuto != null ? ', 눌러서 끄고 켜기' : ''}'
                : '자동 꺼짐${onAuto != null ? ', 눌러서 켜기' : ''}',
            accent: autoOn && !skipping,
            muted: !autoOn || skipping,
            filled: autoOn && !skipping,
            icon: autoOn && !skipping ? Icons.bolt : null,
            onTap: onAuto,
          ),
        ),
      // 알림만 루틴(평가 4차 10/18) — 가전을 움직이지 않는 줄이라는 뜻.
      if (notify) const _LineMark(label: '알려 드려요'),
      // 꺼 둔 루틴(보호자 과업 평가 10/18) — 스위치를 끈 뒤 줄에서도 보인다(설명 줄 끝 '꺼짐' 대신).
      // 이 줄 스위치가 루틴 자체를 켜고 끄면 스위치 아래 '꺼짐'이 같은 말을 한다 — 표지는 두지 않고 낭독만 남긴다(UI 정리 10/19).
      if (!r.isTemplate && !r.enabled && !offBySwitch)
        _LineMark(key: Key('routine-off-badge-$key'), label: '꺼짐', muted: true),
    ];
    final lineStyle = TextStyle(fontSize: AppFont.caption, color: context.appMuted);
    // '누를 버튼 2개'·'매일 오전 7:00' 같은 묶음 안에서 줄이 갈리지 않게(평가 4차 10/18). 낭독은 원문.
    final lineShown = r.isTemplate ? keepWordsTogether(line) : keepPhrasesTogether(line, wholeParts: !big);
    // 표지를 두지 않은 '꺼 둠'도 낭독은 한다.
    final offSpoken = !r.isTemplate && !r.enabled && offBySwitch ? ', 꺼짐' : '';
    final Widget? lineText = line.isEmpty
        ? null
        : Text(lineShown, key: Key('routine-line-$key'), semanticsLabel: '$line$offSpoken', style: lineStyle);
    // 이름은 최대 두 줄(평가 8차 10/18). 넘치면 줄임표 — 낭독은 이름 전체.
    final nameText = Text(keepWordsTogether(r.name),
        semanticsLabel: line.isEmpty ? '${r.name}$offSpoken' : r.name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: AppText.body.copyWith(fontWeight: FontWeight.w700));
    // 이름 + 표지 — 자리가 있으면 이름 옆, 모자라면 이름 아래 줄(큰 글씨). 표지끼리는 가운뎃점 없이 간격으로만.
    final Widget nameLine = badges.isEmpty
        ? nameText
        : Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              nameText,
              Wrap(
                key: Key('routine-marks-$key'),
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: badges,
              ),
            ],
          );
    // 홈 '내 루틴' 줄과 같은 촘촘한 틀(평가 17차 10/18): 이름 바로 아래 설명. 설명 칸에 높이를 따로 주지 않는다.
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        nameLine,
        if (lineText != null)
          Padding(
            key: Key('routine-line-box-$key'),
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: lineText,
          ),
      ],
    );
    // 아이콘은 회색 원 안에 — 강조색(갈색)은 주 행동에만 쓴다(평가 5차 10/18).
    // 큰 글씨에서는 원·아이콘도 글자 배율을 따라 커진다(평가 15차 10/18, 상한 있음 — [textScaledIcon]).
    final circle = textScaledIcon(context, AppSpace.xxxl + AppSpace.sm);
    final icon = Container(
      key: Key('routine-icon-box-$key'),
      width: circle,
      height: circle,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: context.appOverlayFaint, shape: BoxShape.circle),
      child: RoutineIcon(
          routine: r,
          iconOf: applianceIcons,
          size: textScaledIcon(context, AppSpace.xxl),
          color: r.enabled ? context.appInk : context.appMuted),
    );

    // 예시 루틴은 낭독에서도 예시라고 말하고, 누르면 무엇이 되는지 말한다(2026-10-14 UI 정리).
    if (r.isTemplate) {
      final about = (r.description ?? '').isNotEmpty ? '${r.description}. ' : '';
      return Semantics(
        label: '예시 루틴 ${r.name}. $about고쳐서 저장하면 내 루틴이 돼요',
        button: true,
        container: true,
        excludeSemantics: true,
        onTap: onEdit,
        child: InkWell(
          key: Key('routine-$key'),
          onTap: onEdit,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              child: Row(children: [
                icon,
                const SizedBox(width: AppSpace.md),
                Expanded(child: text),
                Icon(Icons.chevron_right, color: context.appMuted),
              ]),
            ),
          ),
        ),
      );
    }

    // 휴리스틱·보호자 과업 평가(10/18): 오른쪽 '지금 하기 >'가 줄 이동처럼 보여 줄을 누르기 겁났고, 정해진 시각 루틴을
    // 끄는 길이 없었다. 그래서 — 줄 누르기는 **고치기**(오른쪽 > 와 '고치기' 단추가 말한다), '지금 하기'는 이름 아래 따로
    // 작은 단추(누르면 먼저 묻는다), 정해진 시각 루틴은 오른쪽에 켜기·끄기 스위치(자동 규칙이 붙었으면 그 규칙, 아니면 루틴).
    // 설정이 남은 루틴은 '지금 하기' 자리에 '설정 열기'. 가전은 여전히 승인 화면에서 허락해야 움직인다.
    final run = onRun;
    final setup = onSetup;
    final Widget? action = setup != null
        ? RowTextAction(
            actionKey: Key('routine-setup-$key'),
            label: kSetupActionLabel,
            semanticLabel: '${r.name} 가전 설정하기',
            onTap: setup,
          )
        : run != null
            ? Semantics(
                label: '${r.name} 지금 하기',
                button: true,
                enabled: !busy,
                excludeSemantics: true,
                child: OutlinedButton.icon(
                  key: Key('routine-run-$key'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(kMinTouch, kMinTouch),
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                  ),
                  onPressed: busy ? null : run,
                  icon: running
                      ? const SizedBox(
                          width: AppSpace.lg, height: AppSpace.lg, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.play_arrow_rounded, size: AppSpace.xl, color: context.appInk),
                  label: Text(keepWordsTogether('지금 하기'),
                      style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: context.appInk)),
                ),
              )
            : null;
    // '고치기' 단추는 두지 않는다(결선 모의 평가 10/18 — 줄마다 '지금 하기 / 고치기'가 같은 무게로 되풀이돼 위계가 평평했다).
    // 고치기는 줄 누르기 — 모든 줄 오른쪽 끝의 > 가 말한다(스위치가 있는 줄도). 낭독 이름은 줄이 '○○ 고치기'로 읽는다.
    // 정해진 시각 루틴의 켜기·끄기 — 줄 오른쪽(큰 글씨에서는 단추 줄 끝).
    final toggle = onToggle;
    final Widget? switchWidget = toggle == null
        ? null
        : Semantics(
            label: switchLabel,
            toggled: switchOn,
            excludeSemantics: true,
            // 켜짐·꺼짐을 색만으로 말하지 않는다 — 스위치 바로 아래 글자(접근성 감사 10/18). 옆에 두면 이름 칸이 좁아져 줄이 꺾였다.
            child: SwitchWithWord(
              on: switchOn,
              wordKey: Key('routine-switch-text-$key'),
              child: SizedBox(
                height: kMinTouch,
                child: Switch(
                  key: Key('routine-switch-$key'),
                  value: switchOn,
                  onChanged: toggling ? null : toggle,
                ),
              ),
            ),
          );
    // 왼쪽 열은 모든 줄이 같은 폭의 가전 아이콘(평가 6차 10/18).
    final leadWidth = circle + AppSpace.md;
    // 아이콘 · 이름과 설명 · 오른쪽(스위치, 없으면 고치기 >)이 같은 세로 가운데 — 홈 '내 루틴' 줄과 같은 틀.
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: leadWidth, child: Align(alignment: Alignment.centerLeft, child: icon)),
        Expanded(child: Semantics(container: true, child: text)),
        if (inline && switchWidget != null) ...[const SizedBox(width: AppSpace.xs), switchWidget],
        // > 는 줄 누르기(고치기)의 표시 — 큰 글씨에서 스위치가 아래 단추 줄로 내려간 줄은 이름 칸(두 줄)이 모자라 두지 않는다.
        if (inline || switchWidget == null) Icon(Icons.chevron_right, color: context.appMuted),
      ],
    );
    final actions = [
      if (action != null) action,
      if (!inline && switchWidget != null) switchWidget,
    ];
    return Padding(
      key: Key('routine-row-$key'),
      padding: const EdgeInsets.only(bottom: AppSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: '${r.name} 고치기',
            button: true,
            child: InkWell(
              // 행 전체를 누르면 고치기(편집). '지금 하기'·스위치는 제 몫을 먼저 받는다.
              key: Key('routine-$key'),
              borderRadius: BorderRadius.circular(12),
              onTap: onEdit,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                  // '자동' 표지의 48dp 손가락 칸 — 줄 높이를 늘리지 않는 투명 확장 영역.
                  child: TapSlop(target: autoKey, child: head),
                ),
              ),
            ),
          ),
          // 건너뛰는 회차 — 표지와 그 '되돌리기'를 한 줄에(평가 10/19). '지금 하기'보다 먼저(상태 → 행동).
          if (skipLine && nextMark != null)
            Padding(
              key: Key('routine-skip-line-$key'),
              padding: EdgeInsets.only(left: leadWidth, bottom: AppSpace.xs),
              child: Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  nextMark,
                  if (n != null && n.canSkip) SkipNextControl(next: n),
                ],
              ),
            ),
          // 단추 줄 — 이름 첫 글자와 같은 세로줄. 단추가 없으면(알림만 루틴 등) 두지 않는다.
          if (actions.isNotEmpty)
            Padding(
              key: Key('routine-action-box-$key'),
              padding: EdgeInsets.only(left: leadWidth, bottom: AppSpace.xs),
              child: Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              ),
            ),
          // '다음' 줄에만 '오늘은 건너뛰기' / '되돌리기'(2026-10-18) — 그 회차 한 번만. 줄 누름(편집)과 따로 받는다.
          if (n != null && n.canSkip && !r.isTemplate && !skipLine)
            Padding(
              padding: EdgeInsets.only(left: leadWidth, bottom: AppSpace.xs),
              child: SkipNextControl(next: n),
            ),
          if (error case final message?)
            Padding(
              padding: EdgeInsets.only(left: leadWidth, bottom: AppSpace.xs),
              // 어절 단위로 줄을 바꾼다('자리/를' 방지, UI 평가 10/17).
              child: Text(keepWordsTogether(message),
                  style: TextStyle(fontSize: AppFont.caption, color: context.appDanger)),
            ),
        ],
      ),
    );
  }
}

/// 자동 규칙 스위치 한 번 — 끄기는 바로, 켜기는 늘 확인 시트(서버가 준 조건·동작을 보여 주고 그 지문으로만 켠다).
/// 실제로 바꿨으면 true, 취소했거나 켤 수 없으면 false(까닭은 알림으로 말한다). 루틴 줄 스위치와 '자동 규칙' 탭이 함께 쓴다.
Future<bool> setAutoRuleSwitch(BuildContext context, RpiApiService api, AutoRule rule, bool on) async {
  if (!on) {
    await api.setAutoRuleEnabled(rule.id, false);
    return true;
  }
  final fp = rule.fingerprint;
  if (fp == null) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('어느 가전인지 확인하지 못해 켤 수 없어요. 가전 연결을 봐 주세요')));
    return false;
  }
  final ok = await showAutoRuleConfirmSheet(
    context,
    conditionText: withAmPmSpoken(rule.conditionText, rule.conditionTime),
    actionText: rule.actionText,
    caveat: rule.caveat,
    title: '다음부터 자동으로 할까요?',
    confirmLabel: '허락하기',
  );
  if (!ok) return false;
  await api.setAutoRuleEnabled(rule.id, true, fingerprint: fp);
  return true;
}

/// 자동 실행 허용 규칙 한 줄 — '자동 실행 켜짐/꺼짐', 끄기·다시 허용·설정값 바꾸기·삭제.
///
/// 켜는 일(다시 허용)은 늘 확인 시트를 거친다 — 서버가 준 조건·동작을 보여 주고 그 지문으로만 켠다.
/// 설정값을 바꾸면 서버가 자동 실행을 끄므로, 바꾼 내용으로 다시 허용할지 이어서 묻는다.
