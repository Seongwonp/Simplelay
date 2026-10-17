import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 행의 ⋮ 메뉴 한 항목.
class RowMenuItem {
  const RowMenuItem({
    required this.key,
    required this.label,
    required this.icon,
    required this.onSelected,
    this.danger = false,
    this.enabled = true,
  });

  final Key key;
  final String label;
  final IconData icon;
  final VoidCallback onSelected;

  /// 지우기처럼 되돌릴 수 없는 일 — 글자를 빨강으로. 실제로 지우기 전 확인은 부르는 쪽이 받는다.
  final bool danger;
  final bool enabled;
}

/// 행마다 버튼을 늘어놓지 않고 편집·지우기를 모아 두는 ⋮ 메뉴(UI 개편안 §4 공통).
///
/// 행에는 주 행동 하나만 남긴다. 터치 영역은 48.
class RowMenu extends StatelessWidget {
  const RowMenu({
    required this.menuKey,
    required this.semanticLabel,
    required this.items,
    super.key,
  });

  final Key menuKey;

  /// 읽는 이름 — '○○ 더 보기'.
  final String semanticLabel;
  final List<RowMenuItem> items;

  @override
  Widget build(BuildContext context) => Semantics(
        label: semanticLabel,
        button: true,
        container: true,
        excludeSemantics: true,
        child: PopupMenuButton<int>(
          key: menuKey,
          tooltip: '더 보기',
          constraints: const BoxConstraints(minWidth: 160),
          icon: Icon(Icons.more_vert, color: context.appMuted),
          style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48))),
          onSelected: (i) => items[i].onSelected(),
          itemBuilder: (context) => [
            for (var i = 0; i < items.length; i++)
              PopupMenuItem<int>(
                key: items[i].key,
                value: i,
                enabled: items[i].enabled,
                height: 48,
                child: Row(
                  children: [
                    Icon(items[i].icon,
                        size: 20,
                        color: items[i].danger ? context.appDanger : context.appMuted),
                    const SizedBox(width: AppSpace.md),
                    Flexible(
                      child: Text(
                        items[i].label,
                        style: TextStyle(
                          fontSize: AppFont.body,
                          color: items[i].danger ? context.appDanger : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
}

/// 지우기 전 확인(되돌릴 수 없는 일은 한 번 더 묻는다). 지우면 true.
Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String body,
  String confirmLabel = '지우기',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog, false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const Key('confirm-delete'),
          // 라이트에서 흰 글자 대비가 무너지지 않게 글자색을 같이 준다.
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: AppColors.onAccent,
            minimumSize: const Size(88, 48),
          ),
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return ok == true;
}
