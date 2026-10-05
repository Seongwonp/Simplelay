import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/estop.dart';
import '../providers/estop_provider.dart';
import '../theme/app_colors.dart';

/// 비상정지 걸림 배너(2026-10-05) — 탭바 위, 실행 중 정지 줄 바로 위에 붙는다.
///
/// 걸려 있는 동안은 어느 탭에서든 사라지지 않는다. "확인하고 해제"는 확인 대화를
/// 거쳐서만 `POST /stop/ack`를 보낸다 — 앱이 스스로 해제하는 경로는 없다.
/// 해제가 실패하면 배너를 남기고 이유를 그 안에 적는다.
class EstopBanner extends ConsumerWidget {
  const EstopBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final estop = ref.watch(estopProvider);
    if (!estop.latched) return const SizedBox.shrink();

    // 짙은 빨강 면에 흰 글자(7.3:1) — 긴급 정지 버튼과 같은 색으로 읽히게 한다.
    const onStop = Colors.white;
    final detail = estop.detail;
    final message = estop.message;
    return Material(
      key: const Key('estop-banner'),
      color: AppColors.stop,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.report, color: onStop, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            kEstopTitle,
                            style: TextStyle(
                                color: onStop,
                                fontSize: 16,
                                fontWeight: FontWeight.w700),
                          ),
                          if (detail != null && detail.isNotEmpty)
                            Text(
                              detail,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: onStop, fontSize: 14),
                            ),
                          if (message != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                message,
                                key: const Key('estop-message'),
                                style: const TextStyle(
                                    color: onStop,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('estop-ack'),
                  onPressed: estop.acking ? null : () => _confirmAndAck(context, ref),
                  style: FilledButton.styleFrom(
                    backgroundColor: onStop,
                    foregroundColor: AppColors.stop,
                    disabledBackgroundColor: Colors.white70,
                    disabledForegroundColor: AppColors.stop,
                    minimumSize: const Size(120, 48),
                  ),
                  child: Text(estop.acking ? '해제하는 중…' : kEstopAckLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmAndAck(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('비상정지 해제'),
        content: const Text(kEstopConfirmQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('estop-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(minimumSize: const Size(64, 48)),
            child: const Text('해제'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final result = await ref.read(estopProvider.notifier).acknowledge();
    if (result == null || !result.cleared || !context.mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(result.message)));
  }
}
