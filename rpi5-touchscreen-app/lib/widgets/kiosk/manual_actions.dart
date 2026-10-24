import 'package:flutter/material.dart';

import '../../models/ambient.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_text.dart';

/// 내 가전 화면의 **저장된 동작 먼저**(시안 B ② 10/24) — 이 가전을 다루는 루틴을 큰 칸으로, 마지막 칸은 '버튼 직접 고르기'.
///
/// 칸을 눌러도 바로 하지 않는다 — 예전 루틴 칸과 같은 길(서버가 확인 카드를 만들고 그 카드의 '시작'이 승인).
/// '버튼 직접 고르기'는 기존 버튼판을 연다(버튼 하나씩 묻고 하나씩 누른다 — 여러 버튼을 고르는 길은 없다).
class KioskManualActions extends StatelessWidget {
  const KioskManualActions({
    super.key,
    required this.routines,
    required this.names,
    required this.onRoutine,
    required this.onPickButtons,
  });

  final List<KioskRoutine> routines;
  final Map<String, String> names;
  final ValueChanged<KioskRoutine>? onRoutine;

  /// null이면 '버튼 직접 고르기' 칸이 없다(누를 버튼이 없는 가전).
  final VoidCallback? onPickButtons;

  static const double _gap = KioskSpace.sm;

  /// 아래 안내 한 줄 자리(칸 높이를 키울 때 남겨 둔다).
  static const double _hintRoom = 48;

  /// 납작한 칸의 최소 높이 — 이름 두 줄·작은 줄(큰 글씨)이 들어가고 누름 높이 48을 넘는다.
  static const double _compactMin = 116;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final large = KioskLayout.isLarge(context);
        // 큰 글씨도 넓은 화면이면 3열(QA 10/25 — 2열이면 루틴 2개 + '버튼 직접 고르기'가 두 줄이 돼 마지막 칸이 아래 탭
        // 밑으로 밀려 스크롤해야만 보였다).
        final cols = large ? (box.maxWidth >= 640 ? 3 : 2) : (box.maxWidth >= 640 ? 4 : 3);
        final w = (box.maxWidth - (cols - 1) * _gap) / cols;
        // 칸 높이 — 하한(이름 두 줄·작은 줄이 다 들어가는 높이)에서, 남는 높이가 있으면 200까지 키운다(아래가 비지 않게).
        // 줄이 늘어 하한으로는 다 안 들어가면 그림을 이름 옆에 두는 납작한 칸으로 줄여 스크롤 없이 다 보이게 한다
        // (누름 높이는 48 이상 — [_compactMin]).
        final count = routines.length + (onPickButtons == null ? 0 : 1);
        final rows = (count / cols).ceil().clamp(1, 99);
        final base = large ? 176.0 : 150.0;
        final room = box.maxHeight.isFinite ? (box.maxHeight - _hintRoom - (rows - 1) * _gap) / rows : base;
        final compact = room < base;
        final h = compact ? room.clamp(_compactMin, base).toDouble() : room.clamp(base, 200.0).toDouble();
        return SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(
            spacing: _gap,
            runSpacing: _gap,
            children: [
              for (final r in routines)
                SizedBox(
                  width: w,
                  height: h,
                  child: _ActionTile(
                    key: ValueKey('routine-${r.id}'),
                    title: r.name,
                    sub: r.sizeLabelWith(names),
                    compact: compact,
                    onTap: onRoutine == null ? null : () => onRoutine!(r),
                  ),
                ),
              if (onPickButtons != null)
                SizedBox(
                  width: w,
                  height: h,
                  child: _ActionTile(
                    key: const ValueKey('manual-pick-buttons'),
                    title: '버튼 직접 고르기',
                    sub: '하나씩 눌러요',
                    manual: true,
                    compact: compact,
                    onTap: onPickButtons,
                  ),
                ),
            ],
          ),
          const SizedBox(height: KioskSpace.sm),
          // 여러 버튼을 한 번 묻고 한 번에 맡기는 길은 저장된 동작(루틴)이다(첫 사용 검토 10/19 #6). 새 루틴은 폰에서 만든다.
          KioskText(
            '여러 버튼을 한 번에 맡기려면 휴대폰 앱에서 루틴을 만들어요',
            textKey: const ValueKey('manual-routine-hint'),
            style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
          ),
          ]),
        );
      });
}

class _ActionTile extends StatelessWidget {
  const _ActionTile(
      {super.key,
      required this.title,
      required this.sub,
      required this.onTap,
      this.manual = false,
      this.compact = false});

  final String title;
  final String sub;
  final VoidCallback? onTap;
  final bool manual;

  /// 납작한 칸 — 그림을 이름 왼쪽에 둔다(칸이 여러 줄이라 높이가 모자랄 때).
  final bool compact;

  Widget _icon() => Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: manual ? Colors.transparent : KioskColors.mint, shape: BoxShape.circle),
        child: Icon(manual ? Icons.grid_view : Icons.play_arrow, size: 26, color: KioskColors.primary),
      );

  Widget _texts() => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        KioskText(title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: manual ? KioskType.body : KioskType.body + 2,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: manual ? KioskColors.primary : KioskColors.ink)),
        if (sub.isNotEmpty)
          KioskText(sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: KioskType.caption, height: 1.2, color: KioskColors.muted)),
      ]);

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        label: [title, if (sub.isNotEmpty) sub].join(', '),
        excludeSemantics: true,
        child: Material(
          color: manual ? Colors.transparent : KioskColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: manual ? KioskColors.primary : KioskColors.border, width: manual ? 1.5 : 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(KioskSpace.sm + 2),
              child: compact
                  ? Row(children: [
                      _icon(),
                      const SizedBox(width: KioskSpace.sm),
                      // 이름이 길어 납작한 칸 높이를 넘으면 잘라 내지 않고 함께 조금 줄인다(폭은 그대로 줄바꿈).
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, c) => FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: SizedBox(width: c.maxWidth, child: _texts()),
                          ),
                        ),
                      ),
                    ])
                  : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    _icon(),
                    // 누르면 한다는 표시(평가 8차 10/18 — 폰 루틴 줄과 같은 말). 누르면 확인 카드가 먼저 뜬다.
                    if (!manual && onTap != null) ...[
                      const SizedBox(width: KioskSpace.xs),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('지금 하기 ›',
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                    fontSize: KioskType.caption,
                                    fontWeight: FontWeight.w700,
                                    color: KioskColors.primary)),
                          ),
                        ),
                      ),
                    ],
                  ]),
                  const Spacer(),
                  _texts(),
                ],
              ),
            ),
          ),
        ),
      );
}
