import 'package:flutter/material.dart';

/// 넘치면 스크롤 막대가 **늘 보이는** 스크롤 영역(2026-10-15 문구 개선 B4·B7·B9).
///
/// 큰 글씨에서 안내가 아래로 넘쳐도 막대가 없으면 사람은 글이 더 있는 줄 모른다.
/// 내용이 영역보다 짧으면 [center]일 때 가운데에 둔다(막대도 그리지 않는다).
class KioskScrollArea extends StatefulWidget {
  const KioskScrollArea({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.center = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool center;

  @override
  State<KioskScrollArea> createState() => _KioskScrollAreaState();
}

class _KioskScrollAreaState extends State<KioskScrollArea> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        // 어두운 바탕에서도 보이게 막대 색을 직접 준다(기본 막대는 거의 보이지 않았다).
        builder: (context, box) => RawScrollbar(
          controller: _controller,
          thumbVisibility: true,
          thumbColor: Colors.white.withValues(alpha: 0.55),
          thickness: 6,
          radius: const Radius.circular(3),
          child: SingleChildScrollView(
            controller: _controller,
            padding: widget.padding,
            child: widget.center && box.maxHeight.isFinite
                ? ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (box.maxHeight - widget.padding.vertical)
                          .clamp(0, double.infinity),
                    ),
                    child: Center(child: widget.child),
                  )
                : widget.child,
          ),
        ),
      );
}
