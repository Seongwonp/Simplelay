import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 설정은 관리 화면이다.알림 개수는 옆의 종 한 곳에서만 표시한다.
class SettingsAction extends StatelessWidget {
  const SettingsAction({super.key});
  @override
  Widget build(BuildContext context) => IconButton(
        key: const Key('open-settings'),
        tooltip: '설정',
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: () => context.push('/settings'),
        icon: const Icon(Icons.settings_outlined),
      );
}
