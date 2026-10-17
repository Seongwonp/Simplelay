import 'package:flutter/material.dart';

import '../theme/kiosk_tokens.dart';
import '../models/learning_status.dart';

/// Opened on demand; failures never masquerade as an empty learning history.
class LearningStatusDialog extends StatefulWidget {
  const LearningStatusDialog(
      {super.key,
      required this.load,
      this.applianceNames = const {},
      this.onClose});
  final Future<LearningStatus> Function()? load;
  final Map<String, String> applianceNames;
  final VoidCallback? onClose;

  @override
  State<LearningStatusDialog> createState() => _LearningStatusDialogState();
}

class _LearningStatusDialogState extends State<LearningStatusDialog> {
  Future<LearningStatus>? _request;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final load = widget.load;
    _request = load == null ? null : Future.sync(load);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('생활 습관'),
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
                        Text('최근 ${status.windowDays}일의 사용 기록'),
                        const Divider(height: 28),
                        if (status.routines.isEmpty)
                          const Text('아직 학습할 실제 사용 기록이 없어요. 평소처럼 사용해 주세요.'),
                        // 기간을 같이 말하고, 숨김은 상태라고 분명히(2026-10-15 §4). 글자를 키웠다.
                        for (final routine in status.routines) ...[
                          Text(routine.purpose,
                              style: const TextStyle(
                                  fontSize: KioskType.body, fontWeight: FontWeight.w700)),
                          Text(
                              '${widget.applianceNames[routine.applianceId] ?? '가전 모름'} · ${routine.timeBand}',
                              style: const TextStyle(fontSize: KioskType.body)),
                          Text(
                              '최근 ${status.windowDays}일 중 ${routine.distinctDays}일, 모두 ${routine.occurrences}번',
                              style: const TextStyle(fontSize: KioskType.body)),
                          Text(
                              routine.muted
                                  ? '이 제안은 보이지 않게 해 뒀어요'
                                  : routine.established
                                      ? '습관 확인'
                                      : '습관을 알아가는 중',
                              style: const TextStyle(fontSize: KioskType.body)),
                          const SizedBox(height: 16),
                        ],
                        if (status.paused)
                          const Text('잠시 쉬는 중이에요. 새 제안을 쉬고 있어요.',
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
                onPressed: () => setState(_reload), child: const Text('새로고침')),
          TextButton(
              onPressed: widget.onClose ?? () => Navigator.of(context).pop(),
              child: const Text('닫기')),
        ],
      );
}
