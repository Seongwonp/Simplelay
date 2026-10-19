import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auto_rule.dart';
import '../models/quiet_hours.dart';
import '../providers/routine_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_icons.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

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
    final rules = ref.watch(autoRulesProvider).valueOrNull ?? const <AutoRule>[];
    final now = DateTime.now();

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md, AppSpace.md),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 핸들
            const SizedBox(height: AppSpace.md),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: context.appOutline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppSpace.xl),

            // 헤더
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
              child: Row(
                children: [
                  Icon(AppIcons.pause,
                      color: context.appWarning, size: 22),
                  const SizedBox(width: AppSpace.md),
                  Flexible(child: Text('잠시 쉬기', style: AppText.title)),
                  const Spacer(),
                  if (isActive)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.md, vertical: AppSpace.xs),
                      decoration: BoxDecoration(
                        color: context.appWarning.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: context.appWarning.withValues(alpha: 0.4)),
                      ),
                      child: Text(
                        '쉬는 중',
                        style: TextStyle(
                            color: context.appWarning,
                            fontSize: AppFont.caption,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
            ),

            // 2026-10-17 쉬운 말 사전: 폰·본체 화면 모두 '잠시 쉬기' — 이름 해명 문장은 뺐다.

            // 쉬는 동안에도 그대로인 것 — 조용한 시간과 같은 말(첫 사용자 검토 10/19). 선택지마다 붙이면 큰 글씨에서 창이 길어진다.
            const SizedBox(height: AppSpace.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '직접 하기와 정지는 그대로예요.',
                  style: TextStyle(color: context.appMuted, fontSize: AppFont.caption),
                ),
              ),
            ),

            // 현재 DND 남은 시간
            if (isActive) ...[
              const SizedBox(height: AppSpace.sm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
                child: Text(
                  _remaining(dndUntil),
                  style: TextStyle(
                      color: context.appWarning, fontSize: AppFont.caption),
                ),
              ),
            ],

            const SizedBox(height: AppSpace.xl),
            const Divider(height: 1),
            const SizedBox(height: AppSpace.sm),

            // 기간 선택 버튼들
            ..._kOptions.map(
              (opt) => _OptionTile(
                label: opt.label,
                // 그 시간 안에 드는 자동 실행을 이름으로(UI 평가 7차 10/17) — 쉬는 동안 소리 없이 건너뛰지 않게.
                subtitle: switch (pauseSkippedRules(now, opt.minutes, rules)) {
                  final skipped when skipped.isNotEmpty =>
                    '${opt.subtitle}. 이때 건너뛰는 일: ${skipped.join(', ')}',
                  _ => opt.subtitle,
                },
                onTap: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.of(context).pop();
                  _notSaved(messenger, await ref.read(dndProvider.notifier).set(opt.minutes));
                },
              ),
            ),

            const Divider(height: 1),

            // 해제
            _OptionTile(
              label: '그만 쉬기',
              subtitle: isActive ? '다시 물어보고 자동으로 해요' : '지금은 쉬고 있지 않아요',
              iconColor: isActive ? context.appDanger : context.appMuted,
              enabled: isActive,
              onTap: isActive
                  ? () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.of(context).pop();
                      _notSaved(messenger, await ref.read(dndProvider.notifier).clear());
                    }
                  : null,
            ),

            const SizedBox(height: AppSpace.sm),
          ],
        ),
      ),
    );
  }

  String _remaining(DateTime until) {
    final diff = until.difference(DateTime.now());
    if (diff.isNegative) return '곧 끝나요';
    if (diff.inMinutes >= 60) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m > 0 ? '$h시간 $m분 뒤 끝나요' : '$h시간 뒤 끝나요';
    }
    return '${diff.inMinutes + 1}분 뒤 끝나요';
  }
}

/// 저장 실패(서버 `persisted: false`)면 이번 세션만 적용됐다고 알린다(2026-10-14 HIGH 재확인 M-R1).
void _notSaved(ScaffoldMessengerState messenger, bool? persisted) {
  if (persisted == false) {
    messenger.showSnackBar(const SnackBar(content: Text(kSettingNotSavedNotice)));
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
              color: context.appMuted, fontSize: AppFont.caption),
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
  // 실제 범위만(2026-10-14 마감 2번) — 새로 켜는 잠시 쉬기는 새 제안과 아직 시작하지 않은 자동 실행을 쉰다.
  _DndOption('30분', '30분 동안 묻지도, 자동으로 하지도 않아요', 30),
  _DndOption('1시간', '1시간 동안 묻지도, 자동으로 하지도 않아요', 60),
  _DndOption('2시간', '2시간 동안 묻지도, 자동으로 하지도 않아요', 120),
];
