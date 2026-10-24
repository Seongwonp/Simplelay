import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'tab_page.dart';

/// '자동 실행' 탭(시안 B 10/24) — 앞으로 정해진 시각에 할 일(`GET /routines/next`)을 읽기만 한다.
///
/// 줄마다 언제·이름·종류(처음 화면 다음 루틴 머리말과 같은 말 — 자동 루틴·물어볼 루틴·알림 루틴)와 처음 화면과 **같은**
/// '오늘은 건너뛰기'·'되돌리기'(같은 콜백 — kiosk_screen의 건너뛰기 한 곳). 아주 끄는 스위치는 키오스크에 두지 않는다 — 폰에서.
class KioskAutoRunView extends StatelessWidget {
  const KioskAutoRunView({
    super.key,
    required this.runs,
    this.loading = false,
    this.busy = false,
    this.notice,
    this.onToggleSkip,
    this.onReload,
  });

  /// 가까운 순서의 회차. null이면 못 불러왔다(불러오는 중이면 [loading]).
  final List<KioskNextRun>? runs;
  final bool loading;

  /// 건너뛰기·되돌리기를 보내는 중 — 단추를 막는다(같은 요청 두 번 금지, 처음 화면과 같은 값).
  final bool busy;

  /// 건너뛰기 실패 안내(처음 화면과 같은 값). 없으면 null.
  final String? notice;
  final ValueChanged<KioskNextRun>? onToggleSkip;
  final VoidCallback? onReload;

  static const kOffOnPhone = '자동 실행 끄기는 휴대폰 앱에서 할 수 있어요';

  @override
  Widget build(BuildContext context) {
    final list = runs ?? const <KioskNextRun>[];
    final n = notice;
    return KioskTabPage(
      key: const ValueKey('auto-run-view'),
      title: '자동 실행',
      note: kOffOnPhone,
      loading: loading && runs == null,
      failed: runs == null,
      failedText: '자동 실행 목록을 불러오지 못했어요',
      emptyText: '정해진 시각에 할 일이 없어요',
      onReload: onReload,
      rows: [
        if (n != null && n.isNotEmpty && list.isNotEmpty)
          Text(n,
              key: const ValueKey('auto-run-notice'),
              style: TextStyle(fontSize: KioskType.caption, height: 1.25, color: KioskColors.warning)),
        for (final (i, run) in list.indexed) _RunRow(key: ValueKey('auto-run-$i'), run: run, busy: busy, onToggle: onToggleSkip),
      ],
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({super.key, required this.run, required this.busy, this.onToggle});

  final KioskNextRun run;
  final bool busy;
  final ValueChanged<KioskNextRun>? onToggle;

  @override
  Widget build(BuildContext context) {
    final skipped = run.skipped && !run.quietSkip;
    final label = onToggle == null || !run.canSkip ? null : (run.skipped ? '되돌리기' : run.skipActionLabel);
    final word = run.skippedHead ?? (run.statusWord.isEmpty ? null : run.statusWord);
    final spoken = [run.kindLabel, if (run.skippedHead case final h?) h, run.whenShort, run.name, if (run.statusWord.isNotEmpty) run.statusWord]
        .join(', ');
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        child: Semantics(
          container: true,
          label: spoken,
          excludeSemantics: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: KioskSpace.xs, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              KioskTabBadge(
                  label: run.kindLabel,
                  icon: Icons.schedule,
                  color: run.kindLabel == '자동 루틴' ? KioskColors.primary : KioskColors.muted),
              if (word != null)
                Text(word,
                    key: const ValueKey('auto-run-word'),
                    style: TextStyle(
                        fontSize: KioskType.caption,
                        fontWeight: skipped ? FontWeight.w700 : FontWeight.w500,
                        color: skipped ? KioskColors.ink : KioskColors.muted)),
            ]),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(children: [
                TextSpan(text: run.whenShort, style: const TextStyle(fontWeight: FontWeight.w700)),
                const TextSpan(text: '  '),
                TextSpan(text: run.name),
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: KioskType.body, height: 1.25, color: skipped ? KioskColors.muted : KioskColors.ink),
            ),
          ]),
        ),
      ),
      if (label != null) ...[
        const SizedBox(width: KioskSpace.sm),
        Semantics(
          button: true,
          enabled: !busy,
          label: label,
          excludeSemantics: true,
          child: OutlinedButton(
            key: ValueKey(run.skipped ? 'auto-run-unskip' : 'auto-run-skip'),
            onPressed: busy ? null : () => onToggle!(run),
            style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.border).copyWith(
              minimumSize: const WidgetStatePropertyAll(Size(0, 52)),
              padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: KioskSpace.md)),
            ),
            child: Text(label,
                maxLines: 1, softWrap: false, style: const TextStyle(fontSize: KioskType.caption, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    ]);
  }
}
