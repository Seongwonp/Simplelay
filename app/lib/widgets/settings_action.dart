import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/care_events_provider.dart';
import '../models/care_attention.dart';
import '../theme/app_colors.dart';

/// 설정은 과업 탭이 아니다. push로 열어 들어온 화면·스크롤을 보존한다.
class SettingsAction extends ConsumerWidget {
  const SettingsAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final care = ref.watch(careEventsProvider);
    final unread = care.unreadCount;
    final showBadge = unread > 0 && careNeedsLook(care.unreadEvents);
    final label = unread > 0
        ? '설정, 안 본 알림 $unread건'
        : care.status == CareInboxStatus.failed
            ? '설정, 알림을 불러오지 못했어요'
            : '설정';
    return Semantics(
      label: label,
      button: true,
      excludeSemantics: true,
      child: IconButton(
        key: const Key('open-settings'),
        tooltip: '설정',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: () => context.push('/settings'),
        icon: Badge(
          key: showBadge ? const Key('settings-unread-badge') : null,
          isLabelVisible: showBadge,
          backgroundColor: AppColors.stop,
          label: Text(unread > 99 ? '99+' : '$unread'),
          child: const Icon(Icons.settings_outlined),
        ),
      ),
    );
  }
}
