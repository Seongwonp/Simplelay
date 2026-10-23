import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/care_attention.dart';
import '../providers/care_events_provider.dart';
import '../theme/app_colors.dart';

/// 알림함의 단일 읽음 상태. 그리는 것만으로 읽음 처리하지 않는다.
class NotificationAction extends ConsumerWidget {
  const NotificationAction({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(careEventsProvider);
    final count = state.unreadCount;
    final failed = state.status == CareInboxStatus.failed;
    final label = [
      '알림',
      if (count > 0) '안 읽은 알림 $count개',
      if (failed)
        '새 알림을 불러오지 못했어요'
      else if (state.status == CareInboxStatus.loading)
        '확인 중'
      else if (state.status == CareInboxStatus.unconfigured)
        '본체 연결 필요'
      else if (count == 0)
        '안 읽은 알림 없음',
    ].join(', ');
    final alert = careNeedsLook(state.unreadEvents) || failed;
    return Semantics(
      label: label,
      button: true,
      excludeSemantics: true,
      child: IconButton(
        key: const Key('open-notifications'),
        tooltip: '알림',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: () => context.push('/care'),
        icon: Badge(
          key: count > 0 ? const Key('notifications-unread-badge') : null,
          isLabelVisible: count > 0 || failed,
          backgroundColor: alert ? AppColors.stop : context.appPrimary,
          textColor: alert ? Colors.white : context.appOnAccent,
          label: Text(count > 99
              ? '99+'
              : count > 0
                  ? '$count'
                  : '!'),
          child: const Icon(Icons.notifications_none_rounded),
        ),
      ),
    );
  }
}
