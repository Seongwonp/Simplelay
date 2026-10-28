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

class _DndSheet extends ConsumerStatefulWidget {
  const _DndSheet();

  @override
  ConsumerState<_DndSheet> createState() => _DndSheetState();
}

class _DndSheetState extends ConsumerState<_DndSheet> {
  // 보내는 동안은 다른 시간·그만 쉬기를 받지 않는다 — 겹친 요청 중 늦게 끝난 쪽이 남는다.
  bool _busy = false;
  String? _error;

  /// 본체가 받았다고 답한 뒤에만 창을 닫는다. 예전에는 먼저 닫고 기다려, 통신이 끊기면 아무 말 없이 끝나 쉬는 줄 알았다
  /// (검토 10/19). 못 보냈으면 창에 그대로 두고 그 사실을 말한다.
  Future<void> _send(Future<bool?> Function() request, String notSent) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final bool? persisted;
    try {
      persisted = await request();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = notSent;
        });
      }
      return;
    }
    if (mounted) navigator.pop();
    _notSaved(messenger, persisted);
  }

  @override
  Widget build(BuildContext context) {
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
        // 큰 글씨·건너뛰는 일이 여럿이면 창이 화면보다 길어진다 — 넘쳐 잘리지 않고 끝('그만 쉬기')까지 밀어 볼 수 있게
        // (첫 사용자 검토 10/19).
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
                child: Row(
                  children: [
                    Icon(AppIcons.pause,
                        color: context.appWarning, size: 22),
                    const SizedBox(width: AppSpace.md),
                    Flexible(child: Text('방해 금지', style: AppText.title)),
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
                          '켜져 있어요',
                          style: TextStyle(
                              color: context.appWarning,
                              fontSize: AppFont.caption,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),

              // 이름은 '방해 금지'(문구 기준 §4 10/19) — 범위 문장을 이름 바로 아래에 늘 둔다. 빼거나 자르지 않는다.
              // 그대로인 것도 함께(첫 사용자 검토 10/19). 선택지마다 붙이면 큰 글씨에서 창이 길어진다.
              const SizedBox(height: AppSpace.sm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${isActive && ref.watch(dndScopeProvider) == 'suggestions_only' ? kDndCarriedScopeText : kDndScopeText} $kDndKeepsText',
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

              if (_error case final error?) ...[
                const SizedBox(height: AppSpace.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
                  child: Text(
                    error,
                    key: const Key('dnd-not-sent'),
                    style: TextStyle(color: context.appDanger, fontSize: AppFont.caption),
                  ),
                ),
              ],

              const SizedBox(height: AppSpace.xl),
              const Divider(height: 1),
              const SizedBox(height: AppSpace.sm),

              ..._kOptions.map(
                (opt) => _OptionTile(
                  label: opt.label,
                  // 그 시간 안에 드는 자동 실행을 이름으로(UI 평가 7차 10/17) — 쉬는 동안 소리 없이 건너뛰지 않게.
                  subtitle: switch (pauseSkippedRules(now, opt.minutes, rules)) {
                    final skipped when skipped.isNotEmpty =>
                      '${opt.subtitle}. 이때 건너뛰는 일: ${skipped.join(', ')}',
                    _ => opt.subtitle,
                  },
                  enabled: !_busy,
                  onTap: _busy
                      ? null
                      : () => _send(() => ref.read(dndProvider.notifier).set(opt.minutes), kDndNotSentNotice),
                ),
              ),

              const Divider(height: 1),

              _OptionTile(
                label: '방해 금지 끄기',
                subtitle: isActive ? '다시 물어보고 자동으로 해요' : '지금은 방해 금지가 꺼져 있어요',
                iconColor: isActive ? context.appDanger : context.appMuted,
                enabled: isActive && !_busy,
                onTap: isActive && !_busy
                    ? () => _send(() => ref.read(dndProvider.notifier).clear(), kDndClearNotSentNotice)
                    : null,
              ),

              const SizedBox(height: AppSpace.sm),
            ],
          ),
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
