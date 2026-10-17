import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/appliance_sync_provider.dart';
import '../theme/app_colors.dart';

/// 아직 키오스크에 못 보낸 변경이 있을 때만 뜨는 한 줄.
///
/// **평상시에는 아무것도 그리지 않는다.** 늘 떠 있는 상태 표시는 읽히지
/// 않고, 정작 문제가 생겼을 때도 눈에 안 들어온다. 카드·배지·통계 타일을
/// 늘리지 않고 한 줄로 끝낸다.
///
/// 문구에 내부 용어(upsert·tombstone·revision·409)를 쓰지 않는다 — 사용자가
/// 알아야 하는 것은 "몇 건이 남았고 다시 시도할 수 있다"뿐이다.
class SyncStatusLine extends ConsumerWidget {
  const SyncStatusLine({super.key, this.onRetry});

  /// null이면 '다시 시도'를 내걸지 않는다(재시도 수단이 다른 곳에 있을 때).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(applianceSyncProvider);
    if (!sync.hasPending) return const SizedBox.shrink();

    final failed = sync.lastFailed;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          Icon(
            failed ? Icons.sync_problem : Icons.sync,
            size: 18,
            color: failed ? context.appWarning : context.appMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              failed
                  ? '바꾼 것 ${sync.pendingCount}건을 보내지 못했어요'
                  : '본체에 보낼 것 ${sync.pendingCount}건',
              style: TextStyle(
                fontSize: 13,
                color: failed ? context.appWarning : context.appMuted,
              ),
            ),
          ),
          if (failed && onRetry != null)
            TextButton(
              onPressed: onRetry,
              // 고령 사용자 기준 최소 터치 대상.
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('다시 하기'),
            ),
        ],
      ),
    );
  }
}
