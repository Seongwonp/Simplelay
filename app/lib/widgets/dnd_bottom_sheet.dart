import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/rpi_api_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// DND 기간 선택 바텀시트. `showDndSheet(context)` 로 호출.
void showDndSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _DndSheet(),
  );
}

class _DndSheet extends ConsumerWidget {
  const _DndSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dndUntil = ref.watch(dndProvider);
    final isActive = dndUntil != null && dndUntil.isAfter(DateTime.now());

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 핸들
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.appOutline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),

            // 헤더
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(Icons.do_not_disturb_on_outlined,
                      color: context.appWarning, size: 22),
                  const SizedBox(width: 10),
                  Text('방해 금지 모드', style: AppText.title),
                  const Spacer(),
                  if (isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: context.appWarning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: context.appWarning.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        '활성',
                        style: TextStyle(
                            color: context.appWarning,
                            fontSize: 12,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),

            // 현재 DND 남은 시간
            if (isActive) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  _remaining(dndUntil),
                  style: TextStyle(
                      color: context.appWarning, fontSize: 13),
                ),
              ),
            ],

            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // 기간 선택 버튼들
            ..._kOptions.map(
              (opt) => _OptionTile(
                label: opt.label,
                subtitle: opt.subtitle,
                onTap: () async {
                  Navigator.of(context).pop();
                  await ref.read(dndProvider.notifier).set(opt.minutes);
                },
              ),
            ),

            const Divider(height: 1),

            // 해제
            _OptionTile(
              label: '방해 금지 해제',
              subtitle: isActive ? '사용 습관 제안을 다시 받습니다' : '현재 비활성 상태',
              iconColor: isActive ? context.appDanger : context.appMuted,
              enabled: isActive,
              onTap: isActive
                  ? () async {
                      Navigator.of(context).pop();
                      await ref.read(dndProvider.notifier).clear();
                    }
                  : null,
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _remaining(DateTime until) {
    final diff = until.difference(DateTime.now());
    if (diff.isNegative) return '곧 해제됩니다';
    if (diff.inMinutes >= 60) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m > 0 ? '$h시간 $m분 후 해제' : '$h시간 후 해제';
    }
    return '${diff.inMinutes + 1}분 후 해제';
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.iconColor,
    this.enabled = true,
  });

  final String label;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? iconColor;
  final bool enabled;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w500,
            color: enabled ? null : context.appMuted,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
              color: context.appMuted, fontSize: 12),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: enabled ? iconColor ?? context.appMuted : context.appBorderFaint,
          size: 20,
        ),
        enabled: enabled,
        onTap: onTap,
      );
}

class _DndOption {
  const _DndOption(this.label, this.subtitle, this.minutes);
  final String label;
  final String subtitle;
  final int minutes;
}

const _kOptions = [
  _DndOption('30분', '사용 습관 제안을 30분간 숨깁니다', 30),
  _DndOption('1시간', '사용 습관 제안을 1시간 동안 숨깁니다', 60),
  _DndOption('2시간', '사용 습관 제안을 2시간 동안 숨깁니다', 120),
];
