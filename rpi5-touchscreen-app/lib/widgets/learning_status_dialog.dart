import 'package:flutter/material.dart';

import '../theme/kiosk_tokens.dart';
import '../models/learning_status.dart';
import 'kiosk/kiosk_text.dart';

/// 본체가 알아 둔 습관을 확인하고 숨기거나 다시 보이게 하는 창.
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
  final _scroll = ScrollController();
  String? _busy;
  String? _actionError;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

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
        _actionError = '바꾸지 못했어요. 잠시 뒤 다시 눌러 주세요.';
      });
    }
  }

  static const _body = TextStyle(fontSize: KioskType.body);

  Widget _summary(BuildContext context, LifestyleSummary summary) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(summary.text,
                style: TextStyle(
                    fontSize: KioskType.body,
                    color: scheme.onSecondaryContainer)),
            if (summary.byModel) ...[
              const SizedBox(height: 6),
              Text('본체 안 AI가 정리했어요',
                  style: TextStyle(
                      fontSize: KioskType.caption,
                      color: scheme.onSecondaryContainer)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _habit(LearningStatus status, LearningRoutine routine) {
    final state = routine.effectiveState;
    final hidden = routine.muted;
    final canChange = hidden ? widget.onUnhide != null : widget.onHide != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(routine.purpose,
            style: const TextStyle(
                fontSize: KioskType.body, fontWeight: FontWeight.w700)),
        Text(
            '${widget.applianceNames[routine.applianceId] ?? '어느 가전인지 확인하지 못했어요'} · ${routine.whenText ?? routine.timeBand}',
            style: _body),
        Text('최근 ${status.windowDays}일 중 ${routine.distinctDays}일, 모두 ${routine.occurrences}번',
            style: _body),
        if (usedDaysLine(routine.recentDays) case final line?)
          Text(line, style: _body),
        Text(habitStateLabel(routine),
            style: const TextStyle(
                fontSize: KioskType.body, fontWeight: FontWeight.w600)),
        if (state == 'auto' && routine.routineName != null)
          Text('루틴: ${routine.routineName}', style: _body),
        if (state == 'auto' && hidden)
          const Text('제안은 숨겼어요. 저장한 루틴은 그대로 실행돼요.', style: _body),
        if (canChange)
          Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: true,
              label: '${routine.purpose} ${hidden ? '다시 보이기' : '숨기기'}',
              excludeSemantics: true,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size(96, 56)),
                onPressed: _busy == null ? () => _change(routine, !hidden) : null,
                child: Text(hidden ? '다시 보이기' : '숨기기', style: _body),
              ),
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('알게 된 것'),
        // 제목·단추는 고정, 본문만 스크롤(10/24 시각 QA — 큰 글씨 1.6배에서 본문이 단추 밑에서 잘려 끝인지 알 수 없었다).
        // 스크롤 막대를 늘 보여 더 있다는 것을 알린다.
        content: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.only(right: 14),
          child: SizedBox(
          width: 440,
          child: widget.load == null
              ? const Text('연결하면 생활 습관을 확인할 수 있어요.')
              : FutureBuilder<LearningStatus>(
                  future: _request,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError || !snapshot.hasData) {
                      return const Text(
                          '불러오지 못했어요. 본체 연결을 봐 주세요.');
                    }
                    final status = snapshot.requireData;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (status.summary case final summary?) ...[
                          _summary(context, summary),
                          const SizedBox(height: 16),
                        ],
                        if (_actionError case final error?)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(error,
                                style: TextStyle(
                                    fontSize: KioskType.body,
                                    color: Theme.of(context).colorScheme.error)),
                          ),
                        Text('최근 ${status.windowDays}일 사용 기록'),
                        const Divider(height: 28),
                        if (status.routines.isEmpty)
                          const Text('아직 습관으로 기억할 사용 기록이 없어요. 평소처럼 사용해 주세요.'),
                        for (final routine in status.routines)
                          _habit(status, routine),
                        if (status.paused)
                          const KioskText('방해 금지가 켜져 있어 새 제안을 묻지 않아요.',
                              style: TextStyle(fontSize: KioskType.body)),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('어떻게 기억하나요?'),
                          children: [
                            Text('같은 가전을 같은 시간대에 ${status.minimumDays}일 이상, '
                                '${status.minimumOccurrences}회 이상 직접 사용하면 습관으로 기억해요.'),
                            const SizedBox(height: 8),
                            const Text('연습과 제안으로 한 기록은 습관에 넣지 않아요.'),
                            const SizedBox(height: 8),
                            const Text(
                                '습관이 생겨도 먼저 물어보고 해요.'),
                            const SizedBox(height: 8),
                            const Text('숨긴 습관은 다시 묻지 않아요. 저장한 루틴은 루틴 화면에서 바꿔요.'),
                          ],
                        ),
                      ],
                    );
                  },
                ),
        ),
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
