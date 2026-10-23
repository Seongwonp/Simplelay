import 'package:flutter/material.dart';

/// 승인된 브랜드 시안의 한 번 누르기 심볼. 비상/실행 상태로 사용하지 않는다.
class TouchMark extends StatelessWidget {
  const TouchMark(
      {required this.ink, required this.button, this.size = 92, super.key});
  final Color ink;
  final Color button;
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
      child: SizedBox.square(
          dimension: size,
          child: CustomPaint(painter: _TouchPainter(ink, button))));
}

class _TouchPainter extends CustomPainter {
  _TouchPainter(this.ink, this.button);
  final Color ink;
  final Color button;
  @override
  void paint(Canvas c, Size size) {
    c.save();
    c.scale(size.width / 100, size.height / 100);
    c.drawCircle(const Offset(61, 51), 22, Paint()..color = button);
    c.drawLine(
        const Offset(8, 111),
        const Offset(56, 57),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 25
          ..strokeCap = StrokeCap.round);
    final rays = Paint()
      ..color = ink
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    c.drawLine(const Offset(67, 14), const Offset(69, 5), rays);
    c.drawLine(const Offset(83, 24), const Offset(90, 17), rays);
    c.drawLine(const Offset(90, 41), const Offset(99, 40), rays);
    c.restore();
  }

  @override
  bool shouldRepaint(covariant _TouchPainter old) =>
      ink != old.ink || button != old.button;
}
