import 'package:flutter/material.dart';
import '../models/learning_status.dart';
import '../theme/app_tokens.dart';

/// '알게 된 것'(2026-10-26) — 본체가 알아 둔 습관을 그대로 보이고 고칠 수 있게(숨기기·다시 보이기).
/// Opened on demand; failures never masquerade as an empty learning history.
class LearningStatusDialog extends StatefulWidget {
  const LearningStatusDialog(
      {super.key,
      required this.load,
      this.applianceNames = const {},
      this.onClose,
      this.onHide,
      this.onUnhide});
  final Future<LearningStatus> Function()? load;
  final Map<String, String> applianceNames;
  final VoidCallback? onClose;

  /// 이 습관을 다시 묻지 않기(카드의 '다시 받지 않기'와 같은 저장소). 없으면 단추를 그리지 않는다.
  final Future<void> Function(String purpose)? onHide;
  final Future<void> Function(String purpose)? onUnhide;

  @override
  State<LearningStatusDialog> createState() => _LearningStatusDialogState();
}

class _LearningStatusDialogState extends State<LearningStatusDialog> {
  Future<LearningStatus>? _request;
  String? _busy;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final load = widget.load;
    _request = load == null ? null : Future.sync(load);
  }

  Future<void> _change(LearningRoutine routine, bool hide) async {
    final action = hide ? widget.onHide : widget.onUnhide;
    if (action == null || _busy != null) return;
    setState(() {
      _busy = routine.purpose;
      _actionError = null;
    });
    try {
      await action(routine.purpose);
      if (!mounted) return;
      setState(() {
        _busy = null;
        _reload();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = null;
        _actionError = '바꾸지 못했어요. 폰과 본체가 같은 와이파이인지 보고 다시 눌러 주세요.';
      });
    }
  }

  Widget _summary(BuildContext context, LifestyleSummary summary) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppSpace.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(summary.text,
                style: text.bodyLarge
                    ?.copyWith(color: scheme.onSecondaryContainer)),
            if (summary.byModel) ...[
              const SizedBox(height: AppSpace.xs),
              Text('본체 안 AI가 정리했어요',
                  style: text.bodySmall
                      ?.copyWith(color: scheme.onSecondaryContainer)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _habit(BuildContext context, LearningStatus status, LearningRoutine routine) {
    final state = routine.effectiveState;
    final hidden = routine.muted;
    final canChange = hidden ? widget.onUnhide != null : widget.onHide != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(routine.purpose, style: Theme.of(context).textTheme.titleMedium),
        Text(
            '${widget.applianceNames[routine.applianceId] ?? '어느 가전인지 확인하지 못했어요'}, ${routine.whenText ?? routine.timeBand}'),
        Text('최근 ${status.windowDays}일 중 ${routine.distinctDays}일, 모두 ${routine.occurrences}번'),
        if (usedDaysLine(routine.recentDays) case final line?) Text(line),
        Text(habitStateLabel(routine),
            style: const TextStyle(fontWeight: FontWeight.w600)),
        if (state == 'auto' && routine.routineName != null)
          Text('루틴: ${routine.routineName}'),
        if (state == 'auto' && hidden)
          const Text('제안은 숨겼어요. 저장한 루틴은 그대로 실행돼요.'),
        if (canChange)
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              label: '${routine.purpose} ${hidden ? '다시 보이기' : '숨기기'}',
              excludeSemantics: true,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(88, 48)),
                onPressed: _busy == null ? () => _change(routine, !hidden) : null,
                child: Text(hidden ? '다시 보이기' : '숨기기'),
              ),
            ),
          ),
        const SizedBox(height: AppSpace.lg),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('알게 된 것'),
        scrollable: true,
        content: SizedBox(
          width: 440,
          child: widget.load == null
              ? const Text('연결하면 생활 습관을 확인할 수 있어요.')
              : FutureBuilder<LearningStatus>(
                  future: _request,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(AppSpace.xxl),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return const Text(
                          '생활 습관을 불러오지 못했어요. 본체 연결을 봐 주세요.');
                    }
                    final status = snapshot.requireData;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (status.summary case final summary?) ...[
                          _summary(context, summary),
                          const SizedBox(height: AppSpace.lg),
                        ],
                        if (_actionError case final error?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: AppSpace.md),
                            child: Text(error,
                                style: TextStyle(
                                    color: Theme.of(context).colorScheme.error)),
                          ),
                        Text('최근 ${status.windowDays}일의 사용 기록'),
                        const Divider(height: 28),
                        if (status.routines.isEmpty)
                          const Text('아직 알아 둘 사용 기록이 없어요. 평소처럼 사용해 주세요.'),
                        for (final routine in status.routines)
                          _habit(context, status, routine),
                        if (status.paused) const Text('방해 금지가 켜져 있어 묻지 않아요.'),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('어떻게 기억하나요?'),
                          children: [
                            Text('같은 가전을 같은 시간대에 ${status.minimumDays}일 이상, '
                                '${status.minimumOccurrences}회 이상 직접 사용하면 습관으로 기억해요.'),
                            const SizedBox(height: AppSpace.sm),
                            const Text('연습과 알림으로 한 일은 습관 횟수에 넣지 않아요.'),
                            const SizedBox(height: AppSpace.sm),
                            const Text(
                                '습관이 생겨도 때가 맞을 때 묻고, 허락을 받은 뒤 해요.'),
                            const SizedBox(height: AppSpace.sm),
                            const Text('숨긴 습관은 다시 묻지 않아요. 저장한 루틴은 루틴 화면에서 바꿔요.'),
                          ],
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          if (widget.load != null)
            TextButton(
                onPressed: () => setState(_reload), child: const Text('새로 보기')),
          TextButton(
              onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
              child: const Text('닫기')),
        ],
      );
}
