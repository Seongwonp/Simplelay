import 'package:flutter/widgets.dart';

/// 가전 종류 그림(선 그림) — 폰 앱과 키오스크가 **같은 그림**을 쓰도록 한 곳에 둔다(2026-10-24, 가전 그림 통일).
///
/// 종류는 서버·저장 값과 같은 문자열 키다: `microwave`·`air_conditioner`·`washing_machine`·`induction`·
/// `rice_cooker`·`intercom`·`air_purifier`. 그 밖의 값(`other` 포함)은 그림이 없다 — [hasApplianceArtwork]가
/// false이면 부르는 쪽이 자기 아이콘을 그린다. 장식용 그림이며 실제 기기 사진·전원 판정이 아니다.
const kApplianceArtworkCategories = <String>{
  'microwave',
  'air_conditioner',
  'washing_machine',
  'induction',
  'rice_cooker',
  'intercom',
  'air_purifier',
};

/// 이 종류에 선 그림이 있는가.
bool hasApplianceArtwork(String category) => kApplianceArtworkCategories.contains(category);

/// 100×100 좌표계에 그린 뒤 크기에 맞춰 늘린다. [ink]는 선, [paper]는 칸 안 채움.
class AppliancePainter extends CustomPainter {
  AppliancePainter(this.category, this.ink, this.paper);
  final String category;
  final Color ink;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final pen = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = paper;
    void line(double x, double y, double xx, double yy) => canvas.drawLine(Offset(x, y), Offset(xx, yy), pen);
    void box(double x, double y, double w, double h, [double radius = 6]) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(radius));
      canvas.drawRRect(r, fill);
      canvas.drawRRect(r, pen);
    }

    void circle(double x, double y, double r) => canvas.drawCircle(Offset(x, y), r, pen);
    void wave(double x, double y) => canvas.drawPath(
        Path()
          ..moveTo(x, y)
          ..cubicTo(x - 5, y + 7, x + 5, y + 10, x, y + 18),
        pen);
    switch (category) {
      case 'microwave':
        box(9, 25, 82, 53);
        box(16, 32, 49, 39, 3);
        line(70, 33, 70, 69);
        box(76, 33, 9, 8, 1);
        for (final y in [49.0, 58.0, 67.0]) {
          circle(80, y, 1.2);
        }
        for (final x in [28.0, 40.0, 52.0]) {
          wave(x, 41);
        }
        line(17, 82, 27, 82);
        line(73, 82, 83, 82);
      case 'air_purifier':
        box(28, 15, 44, 72, 17);
        canvas.drawOval(const Rect.fromLTWH(28, 9, 44, 17), fill);
        canvas.drawOval(const Rect.fromLTWH(28, 9, 44, 17), pen);
        canvas.drawOval(const Rect.fromLTWH(40, 14, 20, 6), pen);
        line(31, 37, 69, 37);
        for (var row = 0; row < 5; row++) {
          for (var col = 0; col < 5; col++) {
            canvas.drawCircle(Offset(36.0 + col * 7, 48.0 + row * 7), 1.1, Paint()..color = ink);
          }
        }
      case 'washing_machine':
        box(20, 10, 60, 80);
        line(20, 29, 80, 29);
        box(27, 17, 19, 5, 1);
        circle(68, 20, 3);
        circle(50, 59, 22);
        circle(50, 59, 15);
        canvas.drawPath(
            Path()
              ..moveTo(37, 61)
              ..quadraticBezierTo(44, 55, 51, 61)
              ..quadraticBezierTo(58, 67, 64, 61),
            pen);
      case 'air_conditioner':
        box(8, 23, 84, 44, 9);
        line(17, 54, 83, 54);
        line(18, 60, 82, 60);
        box(70, 32, 12, 5, 1);
        for (final x in [32.0, 50.0, 68.0]) {
          wave(x, 74);
        }
      case 'induction':
        box(10, 20, 80, 62, 7);
        circle(34, 47, 15);
        circle(34, 47, 10);
        circle(67, 47, 13);
        circle(67, 47, 8);
        line(39, 74, 61, 74);
      case 'rice_cooker':
        box(22, 31, 56, 49, 15);
        canvas.drawOval(const Rect.fromLTWH(22, 25, 56, 19), fill);
        canvas.drawOval(const Rect.fromLTWH(22, 25, 56, 19), pen);
        canvas.drawPath(
            Path()
              ..moveTo(37, 27)
              ..lineTo(37, 18)
              ..quadraticBezierTo(50, 11, 63, 18)
              ..lineTo(63, 27),
            pen);
        box(39, 51, 23, 16, 4);
        line(29, 85, 38, 85);
        line(62, 85, 71, 85);
      case 'intercom':
        box(27, 9, 46, 82);
        box(33, 16, 34, 30, 3);
        for (final x in [37.0, 50.0, 63.0]) {
          circle(x, 60, 3);
        }
        line(37, 75, 63, 75);
        line(37, 81, 63, 81);
      default:
        break;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AppliancePainter old) =>
      category != old.category || ink != old.ink || paper != old.paper;
}
