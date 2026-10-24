import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';

/// 처음 화면 오른쪽 칸(시안 B 10/24) — 칸(카드) 없이 **줄로만**: 작은 회색 머리말 + 값, 줄 사이 가는 선.
/// 줄은 값이 있을 때만 세운다(지어내지 않는다) — 고르는 일은 처음 화면이 한다.
class KioskSideColumn extends StatelessWidget {
  const KioskSideColumn({super.key, required this.rows});

  final List<Widget> rows;

  /// 줄 위아래 여백.
  static const double rowPad = 8;

  @override
  Widget build(BuildContext context) => Column(
        key: const ValueKey('idle-side'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, row) in rows.indexed)
            Container(
              padding: EdgeInsets.only(top: i == 0 ? 0 : rowPad, bottom: rowPad),
              decoration: i == rows.length - 1
                  ? null
                  : BoxDecoration(border: Border(bottom: BorderSide(color: KioskColors.border))),
              child: row,
            ),
        ],
      );
}

/// 오른쪽 칸 한 줄 — 머리말([label], 작은 회색) 아래 [child]. 머리말이 없으면 [child]만(제 머리말을 가진 줄).
class KioskSideRow extends StatelessWidget {
  const KioskSideRow({super.key, this.label, required this.child, this.inline = false});

  final String? label;
  final Widget child;

  /// 머리말과 값을 한 줄에(값이 짧은 줄 — 공기질). 좁은 칸에서 줄 하나를 아낀다.
  final bool inline;

  static TextStyle get labelStyle =>
      TextStyle(fontSize: KioskType.caption, height: 1.2, color: KioskColors.muted);

  /// 값 글자(굵게)와 뒤 작은 글자.
  static TextStyle get valueStyle =>
      TextStyle(fontSize: KioskType.body, height: 1.25, fontWeight: FontWeight.w700, color: KioskColors.ink);
  static TextStyle get smallStyle =>
      TextStyle(fontSize: KioskType.caption, height: 1.25, fontWeight: FontWeight.w400, color: KioskColors.muted);

  @override
  Widget build(BuildContext context) {
    final head = label;
    if (head == null) return child;
    if (inline) {
      return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Text(head, maxLines: 1, style: labelStyle),
        const SizedBox(width: KioskSpace.sm),
        Expanded(child: child),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(head, maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}
