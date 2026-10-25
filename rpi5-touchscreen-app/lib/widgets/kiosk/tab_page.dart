import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'idle_top.dart';
import 'kiosk_scroll_area.dart';
import 'kiosk_text.dart';

/// 아래 탭의 읽기 전용 화면 틀(시안 B 10/24 — '자동 실행'·'기록') — 위 제목 줄, 아래 목록(넘치면 스크롤 막대).
/// 불러오는 중·못 불러옴·비어 있음은 한 문장(+ 다시 불러오기)으로 말한다 — 빈 목록을 '없음'으로 꾸미지 않는다.
class KioskTabPage extends StatelessWidget {
  const KioskTabPage({
    super.key,
    required this.title,
    required this.rows,
    this.note,
    this.loading = false,
    this.failed = false,
    this.emptyText = '',
    this.failedText = '',
    this.onReload,
    this.onMenu,
  });

  final String title;

  /// 위 오른쪽 '메뉴'(처음 화면과 같은 단추·같은 창, QA 10/25 — 탭 화면에서 방해 금지·설정에 가려면 홈으로 가야 했다).
  /// null이면 두지 않는다.
  final VoidCallback? onMenu;

  /// 제목 아래 작은 안내 한 줄(예: '자동 실행 끄기는 휴대폰 앱에서 할 수 있어요'). 없으면 null.
  final String? note;
  final List<Widget> rows;
  final bool loading;
  final bool failed;
  final String emptyText;
  final String failedText;
  final VoidCallback? onReload;

  static const double side = KioskSpace.lg;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (rows.isNotEmpty) {
      body = KioskScrollArea(
        padding: const EdgeInsets.only(bottom: KioskSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, row) in rows.indexed)
              Container(
                padding: const EdgeInsets.symmetric(vertical: KioskSpace.xs),
                decoration: i == rows.length - 1
                    ? null
                    : BoxDecoration(border: Border(bottom: BorderSide(color: KioskColors.border))),
                child: row,
              ),
          ],
        ),
      );
    } else {
      final text = loading
          ? '불러오는 중이에요'
          : failed
              ? failedText
              : emptyText;
      body = Align(
        alignment: Alignment.topLeft,
        child: Column(
          key: const ValueKey('tab-page-message'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: KioskSpace.md),
            KioskText(text, style: TextStyle(fontSize: KioskType.body, height: 1.3, color: KioskColors.muted)),
            if (failed && !loading && onReload != null) ...[
              const SizedBox(height: KioskSpace.sm),
              OutlinedButton(
                key: const ValueKey('tab-page-reload'),
                onPressed: onReload,
                style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.border),
                child: const Text('새로 보기', style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      );
    }
    return ColoredBox(
      color: KioskColors.bg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(side, KioskSpace.sm, side, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 제목·안내 줄 오른쪽에 메뉴 — 제목 줄 높이 안에 두어 목록을 밀어내지 않는다.
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Semantics(
                    header: true,
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: KioskType.status, height: 1.2, fontWeight: FontWeight.w800, color: KioskColors.ink)),
                  ),
                  if (note case final n?) ...[
                    const SizedBox(height: 2),
                    KioskText(n,
                        textKey: const ValueKey('tab-page-note'),
                        style: TextStyle(fontSize: KioskType.caption, height: 1.25, color: KioskColors.muted)),
                  ],
                ]),
              ),
              if (onMenu case final open?) ...[
                const SizedBox(width: KioskSpace.xs),
                KioskIdleMenuButton(onTap: open),
              ],
            ]),
            const SizedBox(height: KioskSpace.xs),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// 목록 줄 오른쪽 결과·종류 표(작은 알약) — 아이콘 + 말(색만으로 말하지 않는다).
class KioskTabBadge extends StatelessWidget {
  const KioskTabBadge({super.key, required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon case final i?) ...[Icon(i, size: 20, color: color), const SizedBox(width: 4)],
          Text(label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: KioskType.caption, fontWeight: FontWeight.w700, color: KioskColors.ink)),
        ]),
      );
}
