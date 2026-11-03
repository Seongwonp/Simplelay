import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

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
    this.fadeOverflow = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final bool center;

  /// 아래로 더 읽을 글이 있으면 칸 아래 끝을 흐리게 한다 — 칸 경계에 걸린 줄이 반쯤 잘린 글자로 보이지 않고,
  /// 막대와 함께 '더 있다'로 읽힌다. 끝까지 내리면 흐림이 없어진다.
  final bool fadeOverflow;

  @override
  State<KioskScrollArea> createState() => _KioskScrollAreaState();
}

class _KioskScrollAreaState extends State<KioskScrollArea> {
  final _controller = ScrollController();
  bool _moreBelow = false;

  /// 아래로 더 읽을 글이 있는가(흐림을 켜는 조건) — 시험용.
  @visibleForTesting
  bool get moreBelow => _moreBelow;

  /// 막대(6) + 간격 — 막대가 글자 오른쪽 끝을 가리지 않게 늘 비워 둔다(UI 평가 2026-10-17).
  static const _barGutter = 14.0;

  /// 흐리게 하는 아래 끝 높이 — 본문 한 줄(21 × 줄 간격)보다 조금 크게, 걸린 줄 전체가 흐려지게.
  static const fadeExtent = 36.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _onMetrics(ScrollMetrics metrics) {
    final more = metrics.extentAfter > 0.5;
    if (more != _moreBelow && mounted) setState(() => _moreBelow = more);
    return false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        // 어두운 바탕에서도 보이게 막대 색을 직접 준다(기본 막대는 거의 보이지 않았다).
        builder: (context, box) {
          Widget scroll = SingleChildScrollView(
            controller: _controller,
            padding: widget.padding.add(const EdgeInsets.only(right: _barGutter)),
            child: widget.center && box.maxHeight.isFinite
                ? ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (box.maxHeight - widget.padding.vertical)
                          .clamp(0, double.infinity),
                    ),
                    child: Center(child: widget.child),
                  )
                : widget.child,
          );
          if (widget.fadeOverflow) {
            final height = box.maxHeight;
            final fade = _moreBelow && height.isFinite && height > fadeExtent * 2;
            scroll = NotificationListener<ScrollMetricsNotification>(
              onNotification: (n) => _onMetrics(n.metrics),
              child: NotificationListener<ScrollUpdateNotification>(
                onNotification: (n) => _onMetrics(n.metrics),
                // 글 위에 바탕색 그러데이션을 덮는다 — 글을 레이어로 감싸지 않아 넘치지 않을 때는 그림이 그대로이고,
                // 흐림을 켜고 끌 때 스크롤 쪽 나무 모양이 바뀌지 않는다(스크롤 위치가 처음으로 돌아가지 않게).
                // 오른쪽 막대 자리는 덮지 않는다.
                child: Stack(
                  fit: StackFit.passthrough,
                  children: [
                    scroll,
                    if (fade)
                      Positioned(
                        key: const ValueKey('kiosk-scroll-fade'),
                        left: 0,
                        right: _barGutter,
                        bottom: 0,
                        height: fadeExtent,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [KioskColors.bg.withValues(alpha: 0), KioskColors.bg],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          }
          return RawScrollbar(
            controller: _controller,
            thumbVisibility: true,
            thumbColor: KioskColors.ink.withValues(alpha: 0.55),
            thickness: 6,
            radius: const Radius.circular(3),
            child: scroll,
          );
        },
      );
}
