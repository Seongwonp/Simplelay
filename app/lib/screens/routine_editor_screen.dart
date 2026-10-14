import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/appliance.dart';
import '../models/routine.dart';
import '../providers/appliance_provider.dart';
import '../providers/routine_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../services/rpi_api_service.dart';
import '../services/routine_time_hint.dart';
import 'history_screen.dart' show historyProvider;
import '../theme/app_colors.dart';
import '../widgets/input_guard.dart';
import '../widgets/routine_run.dart';

/// 루틴 편집 — 문장형 카드 세 줄(언제 · 무엇을 · 그다음)과 '단계 추가'(UI 확정 §2).
///
/// 여러 가전을 잇는 시나리오도 같은 편집기로 만든다. 실행 방식은 "승인 후
/// 실행 / 알림만". **이 화면은 실행하지 않는다** -- '지금 실행'도 승인 카드를
/// 만들 뿐이고, 가전은 카드를 승인해야 움직인다.
class RoutineEditorScreen extends ConsumerStatefulWidget {
  const RoutineEditorScreen({super.key, this.initial});

  /// 고칠 루틴(id 있음) 또는 새 초안(id 없음). null이면 빈 새 루틴.
  final Routine? initial;

  @override
  ConsumerState<RoutineEditorScreen> createState() =>
      _RoutineEditorScreenState();
}

class _RoutineEditorScreenState extends ConsumerState<RoutineEditorScreen> {
  late Routine _draft = widget.initial ??
      const Routine(name: '', steps: [], trigger: RoutineTrigger.manual());
  late final TextEditingController _name =
      TextEditingController(text: _draft.name);
  bool _dirty = false;
  late bool _whenChosen = _draft.id != null || _draft.trigger.kind != RoutineTriggerKind.manual;
  bool _busy = false;
  String? _error;

  bool get _isNew => _draft.id == null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _update(Routine next) => setState(() {
        _draft = next;
        _dirty = true;
        _error = null;
      });

  @override
  Widget build(BuildContext context) {
    final appliances = ref.watch(installedAppliancesProvider);
    final names = {for (final a in appliances) a.id: a.name};
    final caution = _draft.caution;
    final hint = _isNew && !_whenChosen
        ? routineTimeHint(_draft, appliances, ref.watch(historyProvider).valueOrNull ?? [], DateTime.now())
        : null;

    return InputGuard(dirty: _dirty, child: Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '새 루틴' : _draft.name),
        actions: [
          if (!_isNew)
            IconButton(
              tooltip: '루틴 지우기',
              onPressed: _busy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          TextField(
            key: const Key('routine-name'),
            controller: _name,
            maxLength: 30,
            decoration: const InputDecoration(labelText: '루틴 이름'),
            onChanged: (v) => _update(_draft.copyWith(name: v)),
          ),
          if (caution != null && caution.isNotEmpty) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 18, color: context.appWarning),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(caution,
                      style: TextStyle(fontSize: 14, color: context.appWarning)),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          if (_isNew && !_whenChosen) ...[
            Text(hint == null ? '언제 실행할지 골라 주세요.'
              : '최근 30일 중 ${hint.count}일에 ${hint.time} 무렵 사용했어요.',
              key: const Key('routine-time-hint')),
            if (hint != null)
              FilledButton(onPressed: () {
                _whenChosen = true;
                _update(_draft.copyWith(trigger: RoutineTrigger(
                  kind: RoutineTriggerKind.time, time: hint.time, days: hint.days)));
              }, child: Text('${hint.time}로 정하기')),
            OutlinedButton(onPressed: () => _editTrigger(appliances),
              child: const Text('실행 시각 고르기')),
            TextButton(onPressed: () {
              _whenChosen = true;
              _update(_draft.copyWith(trigger: const RoutineTrigger.manual()));
            }, child: const Text('직접 실행으로 정하기')),
            const SizedBox(height: 12),
          ],

          // ── 문장 카드 ───────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: context.appSurfaceLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.appBorderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Line(
                  keyWord: '언제',
                  child: _Token(
                    key: const Key('routine-when'),
                    text: _draft.trigger.describe(applianceNames: names),
                    onTap: () => _editTrigger(appliances),
                  ),
                ),
                for (var i = 0; i < _draft.steps.length; i++)
                  _Line(
                    keyWord: i == 0 ? '무엇을' : '그다음',
                    trailing: _draft.steps.length > 1
                        ? IconButton(
                            tooltip: '이 단계 빼기',
                            onPressed: () => _update(_draft.copyWith(
                                steps: [..._draft.steps]..removeAt(i))),
                            icon: const Icon(Icons.close, size: 18),
                          )
                        : null,
                    child: _stepToken(i, appliances),
                  ),
                if (_draft.steps.isEmpty)
                  _Line(
                    keyWord: '무엇을',
                    child: Text('아래 "단계 추가"로 누를 버튼을 정해 주세요',
                        style: TextStyle(fontSize: 15, color: context.appMuted)),
                  ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('routine-add-step'),
                    onPressed: _draft.steps.length >= 10
                        ? null
                        : () => _addStep(appliances),
                    icon: const Icon(Icons.add),
                    label: const Text('단계 추가'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── 실행 방식 ───────────────────────────────────────────────────
          const Text('실행 방식',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SegmentedButton<RoutineMode>(
            segments: const [
              ButtonSegment(value: RoutineMode.approve, label: Text('승인 후 실행')),
              ButtonSegment(value: RoutineMode.notify, label: Text('알림만')),
            ],
            selected: {_draft.mode},
            showSelectedIcon: false,
            onSelectionChanged: (v) => _update(_draft.copyWith(mode: v.first)),
          ),
          const SizedBox(height: 6),
          Text(
            _draft.mode == RoutineMode.approve
                ? '때가 되면 카드로 물어봐요. 승인 없이 가전을 누르지 않아요.'
                : '알림만 보내요. 가전은 누르지 않아요.',
            style: TextStyle(fontSize: 14, color: context.appMuted),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('루틴 켜기'),
            subtitle: const Text('끄면 때가 되어도 묻지 않아요'),
            value: _draft.enabled,
            onChanged: (v) => _update(_draft.copyWith(enabled: v)),
          ),
          if (!_isNew)
            Text(
              '단계나 실행 방식을 바꾸면 이미 떠 있는 카드는 다시 확인해야 해요.',
              style: TextStyle(fontSize: 13, color: context.appMuted),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('routine-error'),
                style: TextStyle(fontSize: 15, color: context.appDanger)),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Row(
            children: [
              if (!_isNew && !_dirty) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _runNow,
                    child: const Text('지금 실행'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: FilledButton(
                  key: const Key('routine-save'),
                  onPressed: _busy ? null : _save,
                  child: const Text('저장'),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _stepToken(int index, List<ApplianceMap> appliances) {
    final s = _draft.steps[index];
    final a = appliances.where((a) => a.id == s.applianceId).firstOrNull;
    final who = a?.name ?? s.applianceId ?? '';
    switch (s.kind) {
      case RoutineStepKind.pressSequence:
        final labels = s.buttons.map((b) => a?.labelFor(b) ?? b).join(' → ');
        return Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            _Token(text: who, icon: a?.icon),
            const Text('에서'),
            _Token(
              key: Key('routine-step-$index'),
              text: labels,
              onTap: a == null || a.isThinq
                  ? null
                  : () => _rerecord(index, a),
            ),
            const Text('누르기'),
          ],
        );
      case RoutineStepKind.thinqCommand:
        return Wrap(
          spacing: 6,
          children: [
            _Token(text: who, icon: a?.icon),
            Text('ThinQ 명령 ${s.action ?? ''}'),
          ],
        );
      case RoutineStepKind.announce:
        return Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Token(
              text: s.text ?? '',
              onTap: () => _editAnnounce(index),
            ),
            const Text('알려 주기'),
          ],
        );
      case RoutineStepKind.waitUntilDone:
        return Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _Token(text: who, icon: a?.icon),
            const Text('동작이 끝날 때까지 기다리기'),
          ],
        );
    }
  }

  // ── 편집 동작 ─────────────────────────────────────────────────────────

  Future<void> _rerecord(int index, ApplianceMap a) async {
    final buttons = await context.push<List<String>>('/routine/record/${a.id}');
    if (buttons == null || buttons.isEmpty || !mounted) return;
    final steps = [..._draft.steps];
    steps[index] = steps[index].copyWith(buttons: buttons);
    _update(_draft.copyWith(steps: steps));
  }

  Future<void> _addStep(List<ApplianceMap> appliances) async {
    final kind = await showModalBottomSheet<RoutineStepKind>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.touch_app_outlined),
              title: const Text('버튼 누르기'),
              subtitle: const Text('가전을 골라 사진 속 버튼을 순서대로 짚어요'),
              onTap: () => Navigator.pop(sheet, RoutineStepKind.pressSequence),
            ),
            ListTile(
              leading: const Icon(Icons.hourglass_bottom),
              title: const Text('끝날 때까지 기다리기'),
              onTap: () => Navigator.pop(sheet, RoutineStepKind.waitUntilDone),
            ),
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: const Text('안내하기'),
              subtitle: const Text('알림함에 한 줄을 남겨요(음성 안내는 준비 중이에요)'),
              onTap: () => Navigator.pop(sheet, RoutineStepKind.announce),
            ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    switch (kind) {
      case RoutineStepKind.pressSequence:
        final a = await _pickAppliance(
            appliances.where((a) => !a.isThinq).toList());
        if (a == null || !mounted) return;
        final buttons =
            await context.push<List<String>>('/routine/record/${a.id}');
        if (buttons == null || buttons.isEmpty || !mounted) return;
        _update(_draft.copyWith(
            steps: [..._draft.steps, RoutineStep.press(a.id, buttons)]));
      case RoutineStepKind.waitUntilDone:
        final a = await _pickAppliance(appliances);
        if (a == null || !mounted) return;
        _update(_draft.copyWith(
            steps: [..._draft.steps, RoutineStep.wait(a.id)]));
      case RoutineStepKind.announce:
        final text = await _askText('안내할 문장', '');
        if (text == null || text.isEmpty || !mounted) return;
        _update(_draft.copyWith(
            steps: [..._draft.steps, RoutineStep.announce(text)]));
      case RoutineStepKind.thinqCommand:
        return;
    }
  }

  Future<void> _editAnnounce(int index) async {
    final text = await _askText('안내할 문장', _draft.steps[index].text ?? '');
    if (text == null || text.isEmpty || !mounted) return;
    final steps = [..._draft.steps];
    steps[index] = steps[index].copyWith(text: text);
    _update(_draft.copyWith(steps: steps));
  }

  Future<ApplianceMap?> _pickAppliance(List<ApplianceMap> options) async {
    if (options.isEmpty) {
      _snack('먼저 가전을 추가해 주세요.');
      return null;
    }
    if (options.length == 1) return options.first;
    return showModalBottomSheet<ApplianceMap>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final a in options)
              ListTile(
                leading: Icon(a.icon),
                title: Text(a.displayName),
                onTap: () => Navigator.pop(sheet, a),
              ),
          ],
        ),
      ),
    );
  }

  Future<String?> _askText(String title, String initial) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, controller.text.trim()),
              child: const Text('확인')),
        ],
      ),
    );
  }

  Future<void> _editTrigger(List<ApplianceMap> appliances) async {
    final next = await showModalBottomSheet<RoutineTrigger>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TriggerSheet(initial: _draft.trigger, appliances: appliances),
    );
    if (next != null && mounted) {
      _whenChosen = true;
      _update(_draft.copyWith(trigger: next));
    }
  }

  // ── 서버 ──────────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_whenChosen) {
      setState(() => _error = '언제 실행할지 먼저 골라 주세요.');
      return;
    }
    final api = ref.read(rpiApiServiceProvider);
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '루틴 이름을 적어 주세요.');
      return;
    }
    if (_draft.steps.isEmpty) {
      setState(() => _error = '할 일을 하나 이상 넣어 주세요.');
      return;
    }
    if (api == null) {
      setState(() => _error = '허브에 연결되면 저장할 수 있어요.');
      return;
    }
    setState(() => _busy = true);
    try {
      await api.saveRoutine(_draft.copyWith(name: name));
      ref.invalidate(routinesProvider);
      ref.invalidate(nextRoutineProvider);
      if (mounted) {
        setState(() => _dirty = false);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.of(context).pop(true);
      }
    } on RpiApiException catch (e) {
      // 서버 검증 문장(422)은 화면에 그대로 보여도 되는 한국어다.
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '저장하지 못했어요. 연결을 확인해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final id = _draft.id;
    final api = ref.read(rpiApiServiceProvider);
    if (id == null || api == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('이 루틴을 지울까요?'),
        content: const Text('지우면 떠 있던 카드도 내려가요.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('취소')),
          FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('지우기')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await api.deleteRoutine(id);
      ref.invalidate(routinesProvider);
      if (mounted) {
        setState(() => _dirty = false);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.of(context).pop(true);
      }
    } on RpiApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '지우지 못했어요. 연결을 확인해 주세요.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// '지금 실행' — 승인 루틴은 **카드를 만들 뿐**이다. 카드 확인 화면으로 가서
  /// 거기서 승인해야 가전이 움직인다.
  /// 루틴 목록·홈의 '실행하기'와 같은 경로(`widgets/routine_run.dart`).
  Future<void> _runNow() async {
    final id = _draft.id;
    if (id == null || ref.read(rpiApiServiceProvider) == null) return;
    setState(() => _busy = true);
    try {
      final error = await runRoutineNow(context, ref, id);
      if (mounted && error != null) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text)));
}

// ── 문장 조각 ─────────────────────────────────────────────────────────────

class _Line extends StatelessWidget {
  const _Line({required this.keyWord, required this.child, this.trailing});

  final String keyWord;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 56,
              child: Text(keyWord,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: context.appMuted)),
            ),
            Expanded(
              child: DefaultTextStyle.merge(
                style: const TextStyle(fontSize: 16),
                child: child,
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

class _Token extends StatelessWidget {
  const _Token({super.key, required this.text, this.icon, this.onTap});

  final String text;
  final IconData? icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.appPrimary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: onTap == null
            ? null
            : Border.all(color: context.appPrimary.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: context.appPrimary),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(text,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.appPrimary)),
          ),
        ],
      ),
    );
    if (onTap == null) return body;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Align(alignment: Alignment.centerLeft, widthFactor: 1, child: body),
      ),
    );
  }
}

// ── '언제' 고르기 ─────────────────────────────────────────────────────────

class _TriggerSheet extends StatefulWidget {
  const _TriggerSheet({required this.initial, required this.appliances});

  final RoutineTrigger initial;
  final List<ApplianceMap> appliances;

  @override
  State<_TriggerSheet> createState() => _TriggerSheetState();
}

class _TriggerSheetState extends State<_TriggerSheet> {
  late RoutineTriggerKind _kind = widget.initial.kind;
  late Set<int> _days = widget.initial.days.isEmpty
      ? {0, 1, 2, 3, 4}
      : widget.initial.days.toSet();
  late String _time = widget.initial.time ?? '07:30';
  late String _zone = widget.initial.zone ?? 'near';
  late String? _afterAppliance =
      widget.initial.applianceId ?? widget.appliances.firstOrNull?.id;

  RoutineTrigger? _build() => switch (_kind) {
        RoutineTriggerKind.time => _days.isEmpty
            ? null
            : RoutineTrigger(
                kind: RoutineTriggerKind.time,
                days: (_days.toList()..sort()),
                time: _time,
              ),
        RoutineTriggerKind.approach =>
          RoutineTrigger(kind: RoutineTriggerKind.approach, zone: _zone),
        RoutineTriggerKind.afterDone => _afterAppliance == null
            ? null
            : RoutineTrigger(
                kind: RoutineTriggerKind.afterDone,
                applianceId: _afterAppliance),
        // 가전 알림(ThinQ 이벤트)은 예시 루틴에서 온 것만 그대로 둔다.
        RoutineTriggerKind.event => widget.initial,
        RoutineTriggerKind.manual => const RoutineTrigger.manual(),
      };

  @override
  Widget build(BuildContext context) {
    final kinds = [
      (RoutineTriggerKind.time, '시각'),
      (RoutineTriggerKind.approach, '다가오면'),
      (RoutineTriggerKind.afterDone, '끝난 뒤'),
      if (widget.initial.kind == RoutineTriggerKind.event)
        (RoutineTriggerKind.event, '가전 알림'),
      (RoutineTriggerKind.manual, '직접 실행'),
    ];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('언제',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (k, label) in kinds)
                    ChoiceChip(
                      label: Text(label),
                      selected: _kind == k,
                      onSelected: (_) => setState(() => _kind = k),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              if (_kind == RoutineTriggerKind.time) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (var d = 0; d < 7; d++)
                      FilterChip(
                        label: Text(kWeekdayLabels[d]),
                        selected: _days.contains(d),
                        onSelected: (on) => setState(() {
                          _days = {..._days};
                          on ? _days.add(d) : _days.remove(d);
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  icon: const Icon(Icons.schedule),
                  label: Text(_time),
                  onPressed: () async {
                    final parts = _time.split(':');
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                        hour: int.tryParse(parts.first) ?? 7,
                        minute: int.tryParse(parts.last) ?? 30,
                      ),
                    );
                    if (picked != null) {
                      setState(() => _time =
                          '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}');
                    }
                  },
                ),
                if (_days.isEmpty)
                  Text('요일을 하나 이상 골라 주세요',
                      style: TextStyle(color: context.appWarning)),
              ],
              if (_kind == RoutineTriggerKind.approach)
                RadioGroup<String>(
                  groupValue: _zone,
                  onChanged: (v) => setState(() => _zone = v ?? 'near'),
                  child: const Column(
                    children: [
                      RadioListTile(value: 'arrival', title: Text('집에 도착할 때')),
                      RadioListTile(value: 'room', title: Text('방에 들어오면')),
                      RadioListTile(value: 'near', title: Text('가전 앞에 오면')),
                    ],
                  ),
                ),
              if (_kind == RoutineTriggerKind.afterDone)
                widget.appliances.isEmpty
                    ? const Text('먼저 가전을 추가해 주세요')
                    : DropdownButton<String>(
                        isExpanded: true,
                        value: _afterAppliance,
                        items: [
                          for (final a in widget.appliances)
                            DropdownMenuItem(
                                value: a.id, child: Text('${a.displayName} 동작이 끝나면')),
                        ],
                        onChanged: (v) => setState(() => _afterAppliance = v),
                      ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _build() == null
                      ? null
                      : () => Navigator.pop(context, _build()),
                  child: const Text('정하기'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
