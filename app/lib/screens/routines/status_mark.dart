part of '../routines_screen.dart';

class _LineMark extends StatelessWidget {
  const _LineMark(
      {super.key,
      required this.label,
      this.semanticLabel,
      this.accent = false,
      this.muted = false,
      this.filled = false,
      this.icon,
      this.onTap});

  final String label;
  final String? semanticLabel;
  final bool accent;
  final bool muted;

  /// 옅은 면을 깐다 — 켜진 자동('묻지 않고 해요')만(UI 정리 10/19: 켜진 자동과 '오늘은 건너뛰어요'가 같은 테두리 글자라
  /// 색으로만 갈렸다). 모양(면·아이콘)으로도 가른다.
  final bool filled;

  /// 글자 앞 작은 아이콘 — 켜진 자동은 번개, 건너뛰는 회차는 빈 달력. 뜻은 글자가 말한다(아이콘은 읽지 않는다).
  final IconData? icon;

  /// 있으면 누를 수 있는 표지(루틴 줄 '자동' → 그 규칙 스위치). 보이는 크기는 작게 두고, 손가락이 닿는 칸은
  /// 줄 높이를 늘리지 않는 투명 확장 영역([TapSlop])으로 48dp를 준다(평가 17차: 48dp 칸을 설명 줄 높이로 주니
  /// 이름과 설명 사이가 벌어져 설명이 다음 줄에 붙어 보였다).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = muted ? context.appMuted : accent ? context.appPrimary : context.appInk;
    final text = Text(keepWordsTogether(label),
        semanticsLabel: semanticLabel ?? label,
        style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700, color: color, height: 1.25));
    final glyph = icon;
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
      decoration: BoxDecoration(
        color: filled ? color.withValues(alpha: 0.16) : null,
        border: Border.all(color: color.withValues(alpha: filled ? 0.9 : 0.6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: glyph == null
          ? text
          : Row(mainAxisSize: MainAxisSize.min, children: [
              // 글자 배율을 따라 커진다 — 큰 글씨에서 아이콘만 작게 남지 않게.
              ExcludeSemantics(
                  child: Icon(glyph, size: MediaQuery.textScalerOf(context).scale(AppFont.caption), color: color)),
              const SizedBox(width: AppSpace.xs),
              Flexible(child: text),
            ]),
    );
    final tap = onTap;
    if (tap == null) return tag;
    return Semantics(
      button: true,
      child: InkWell(borderRadius: BorderRadius.circular(6), onTap: tap, child: tag),
    );
  }
}

/// 안쪽 [target]의 보이는 칸이 [minSize]보다 작으면, 그 둘레(가운데 맞춘 [minSize] 칸)를 눌러도 [target]이 눌린 것으로
/// 받는다 — 줄 높이·간격은 그대로(평가 17차 10/18, 루틴 줄 '자동' 표지). 이 위젯의 칸 밖은 받지 못하므로 줄 전체를 감싼다.
class TapSlop extends SingleChildRenderObjectWidget {
  const TapSlop({super.key, required this.target, this.minSize = kMinTouch, super.child});

  final GlobalKey target;
  final double minSize;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderTapSlop(target, minSize);

  @override
  void updateRenderObject(BuildContext context, RenderTapSlop renderObject) {
    renderObject
      ..target = target
      ..minSize = minSize;
  }
}

class RenderTapSlop extends RenderProxyBox {
  RenderTapSlop(this.target, this.minSize);

  GlobalKey target;
  double minSize;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final box = target.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize && child != null) {
      final topLeft = box.localToGlobal(Offset.zero, ancestor: this);
      final rect = topLeft & box.size;
      final slop = Rect.fromCenter(
          center: rect.center,
          width: rect.width < minSize ? minSize : rect.width,
          height: rect.height < minSize ? minSize : rect.height);
      if (!rect.contains(position) && slop.contains(position)) {
        final inside = Offset(position.dx.clamp(rect.left + 0.5, rect.right - 0.5).toDouble(),
            position.dy.clamp(rect.top + 0.5, rect.bottom - 0.5).toDouble());
        return child!.hitTest(result, position: inside);
      }
    }
    return super.hitTestChildren(result, position: position);
  }
}
