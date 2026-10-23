part of '../routines_screen.dart';

class _AutoRuleRow extends ConsumerStatefulWidget {
  const _AutoRuleRow({required this.rule, required this.onChanged});

  final AutoRule rule;
  final VoidCallback onChanged;

  @override
  ConsumerState<_AutoRuleRow> createState() => _AutoRuleRowState();
}

class _AutoRuleRowState extends ConsumerState<_AutoRuleRow> {
  bool _busy = false;

  Future<void> _run(Future<void> Function(RpiApiService api) action) async {
    final api = ref.read(rpiApiServiceProvider);
    if (api == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action(api);
    } on RpiApiException catch (e) {
      _say(e.message.isNotEmpty ? e.message : '바꾸지 못했어요. 연결을 봐 주세요.');
    } catch (_) {
      _say('바꾸지 못했어요. 연결을 봐 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
      widget.onChanged();
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _reallow(RpiApiService api, AutoRule rule) async {
    await setAutoRuleSwitch(context, api, rule, true);
  }

  Future<void> _changeValue(RpiApiService api) async {
    final rule = widget.rule;
    final choices = rule.allowedValues.where((v) => v.$1 != rule.value).toList();
    if (choices.isEmpty) return;
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text(autoRuleValueLabel(rule)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.xxl, 0, AppSpace.xxl, AppSpace.sm),
            child: Text('바꾸면 다시 허락해야 자동으로 해요.',
                style: TextStyle(fontSize: AppFont.caption, color: dialogContext.appMuted)),
          ),
          for (final (v, label) in choices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, v),
              child: Text(label, style: const TextStyle(fontSize: AppFont.body)),
            ),
        ],
      ),
    );
    if (value == null || !mounted) return;
    final changed = await api.updateAutoRuleValue(rule.id, value);
    if (!mounted) return;
    await _reallow(api, changed);
  }

  Future<void> _delete(RpiApiService api) async {
    final ok = await confirmDelete(context,
        title: "이 '자동으로 하기'를 지울까요?",
        body: autoRuleSentence(widget.rule));
    if (ok) await api.deleteAutoRule(widget.rule.id);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.rule;
    final reason = r.disabledReason;
    final quietNote = quietRuleNote(ref.watch(quietHoursProvider).valueOrNull, r);
    // 상태는 서버 문장(status_label)이 아니라 enabled 값으로(2차 평가 10/18).
    // 끈 규칙은 한 줄 — 꺼진 까닭이 있으면 그 말이 배지다(평가 6차 10/18: '지금은 안 해요' 아래 '자동으로 하기를
    // 꺼 두셨어요'가 같은 말을 두 번 했다). 까닭이 없으면 '지금은 안 해요'.
    // 평가 8차(10/18): 사용자가 끈 규칙은 스위치가 이미 '꺼짐'을 말한다 — '자동으로 하기를 꺼 두셨어요' 배지를 두지 않는다.
    // 정지·값 바꿈·재시작처럼 다른 까닭으로 꺼졌으면 그 까닭이 배지다(스위치만으로는 왜 꺼졌는지 모른다).
    final offLabel = (reason ?? '').trim().replaceAll(RegExp(r'[.。]$'), '');
    final userOff = offLabel.isEmpty || offLabel == kUserOffReason;
    // 평가 11차(10/18): 켜진 규칙의 '자동으로 해요'·사용자가 끈 규칙의 '꺼 둠'은 바로 옆 스위치와 같은 뜻이라 두지 않는다.
    // 정지·값 바꿈·재시작처럼 다른 까닭으로 꺼졌을 때만 그 까닭 배지(스위치만으로는 왜 꺼졌는지 모른다).
    final Widget? badge = r.enabled || userOff
        ? null
        : StatusBadge(key: Key('auto-rule-off-${r.id}'), icon: AppIcons.off, label: keepWordsTogether(offLabel));
    // 면·그림자 없는 줄(평가 15차 10/18 — '내 루틴' 목록과 같은 문법). 줄 사이 구분은 목록이 긋는다.
    return Padding(
      key: Key('auto-rule-${r.id}'),
      padding: EdgeInsets.zero,
      child: SizedBox(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 카드마다 붙던 순환 아이콘은 뺀다(평가 14차 10/18 — 장식). 켜짐은 스위치가 말한다.
                  Expanded(
                    // 끝 짧은 낱말('세게'·'켜기')은 앞 낱말과 함께 넘긴다(평가 16차 10/18: '공기청정기 / 세게').
                    child: Text(keepActionNameTogether(r.name),
                        semanticsLabel: r.name,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  // 켜기/끄기 — 켤 때는 늘 확인 시트(서버가 준 조건·동작과 지문으로만 켠다), 끌 때는 바로.
                  Semantics(
                    label: '${r.name} 자동',
                    toggled: r.enabled,
                    excludeSemantics: true,
                    // 켜짐·꺼짐을 색만으로 말하지 않는다 — 스위치 바로 아래 글자(접근성 감사 10/18, 내 루틴 스위치와 같은 모양).
                    child: SwitchWithWord(
                      on: r.enabled,
                      wordKey: Key('auto-rule-switch-text-${r.id}'),
                      child: SizedBox(
                        height: 48,
                        child: Switch(
                          key: Key('auto-rule-switch-${r.id}'),
                          value: r.enabled,
                          onChanged: _busy
                              ? null
                              : (on) => on
                                  ? _run((api) => _reallow(api, r))
                                  : _run((api) => api.setAutoRuleEnabled(r.id, false)),
                        ),
                      ),
                    ),
                  ),
                  // 값 바꾸기·지우기는 ⋮ 안(2026-10-18 버튼 위계).
                  RowMenu(
                    menuKey: Key('auto-rule-menu-${r.id}'),
                    semanticLabel: '${r.name} 더 보기',
                    items: [
                      if (r.allowedValues.length > 1)
                        RowMenuItem(
                          key: Key('auto-rule-edit-${r.id}'),
                          label: autoRuleValueLabel(r),
                          icon: Icons.tune,
                          enabled: !_busy,
                          onSelected: () => _run(_changeValue),
                        ),
                      RowMenuItem(
                        key: Key('auto-rule-delete-${r.id}'),
                        label: '지우기',
                        icon: Icons.delete_outline,
                        danger: true,
                        enabled: !_busy,
                        onSelected: () => _run(_delete),
                      ),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 언제·무엇을 한 문장(2차 평가 10/18) — 화살표·'조건:/동작:' 표를 쓰지 않는다.
                    // 평가 14차(10/18): 이름이 이미 다 말하면(이름 '전자레인지가 멈추면 공기청정기 세게') 되풀이하지 않는다.
                    // 값을 바꿔 이름과 달라졌으면 남긴다([autoRuleNameSaysAll]).
                    if (!autoRuleNameSaysAll(r))
                      Text(keepWordsTogether(autoRuleSentence(r)),
                          semanticsLabel: autoRuleSentence(r),
                          style: const TextStyle(fontSize: AppFont.body)),
                    if (badge != null) ...[
                      const SizedBox(height: AppSpace.sm),
                      badge,
                    ],
                    // 조용한 시간이 켜져 있어 실제로 건너뛸 때만 눈에 띄게(앰버·굵게). 꺼져 있을 때의 '켜면 …'은
                    // 조용한 시간 설정 줄에만 둔다(평가 6차 10/18: 카드마다 늘 굵게 서 있었다).
                    if (quietNote != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(keepWordsTogether(quietNote),
                          semanticsLabel: quietNote,
                          style: TextStyle(
                              fontSize: AppFont.caption, fontWeight: FontWeight.w600, color: context.appWarning)),
                    ],
                    // 마지막 자동 실행의 장치별 결과 — 서버 문장 그대로(확인된 것만 '바꿨어요').
                    if (r.lastRunNotices.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.sm),
                      Text('최근 결과', style: context.appCaption.copyWith(fontWeight: FontWeight.w600)),
                      for (final n in r.lastRunNotices) Text(n, style: context.appCaption),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
