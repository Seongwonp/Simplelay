import 'package:flutter/material.dart';

/// 날씨 그림·말 — 처음 화면 날씨 줄과 날씨 자세히 창이 함께 쓴다(2026-10-25, idle_view.dart에서 옮김).

/// 밤 시간(19~5시)인가. 모르면 낮으로 본다.
bool isNightHour(int? h) => h != null && (h >= 19 || h < 6);

/// 하늘 말 — 서버 아이콘 이름에서. 모르면 빈 말(지어내지 않는다).
String weatherWord(String icon) => switch (icon) {
      'clear' => '맑음',
      'partly' => '구름 조금',
      'cloudy' => '흐림',
      'rain' => '비',
      'snow' => '눈',
      _ => '',
    };

/// 예보 아이콘 — 가전 아이콘과 같은 채움 양식(평가 17차 10/18 — 날씨만 가는 선이었다). 밤의 맑음·구름 조금은 해가 아니라 달(외부 평가 10/16 4차, 실패널 0시·3시에 해가 찍혔다).
IconData _hourIcon(String icon, {bool night = false}) => switch (icon) {
      'clear' when night => Icons.nightlight,
      'partly' when night => Icons.nights_stay,
      'clear' => Icons.wb_sunny,
      'partly' => Icons.wb_cloudy,
      'cloudy' => Icons.cloud,
      // 비는 [KioskWeatherIcon]이 비 오는 구름으로 그린다 — 물방울은 습도로 읽혔다(평가 10차 10/18). 여기 값은 '아는 날씨' 표시.
      'rain' => Icons.cloud,
      'snow' => Icons.ac_unit,
      _ => Icons.remove,
    };

/// 기상 특보 아이콘(서버 `warnings[].icon`, 2026-10-25). 모르면 주의 표시.
IconData warningIcon(String icon) => switch (icon) {
      'wind' => Icons.air,
      'rain' => Icons.umbrella,
      'cold' => Icons.ac_unit,
      'dry' => Icons.local_fire_department_outlined,
      'storm' => Icons.thunderstorm_outlined,
      'snow' => Icons.ac_unit,
      'dust' => Icons.blur_on,
      'hot' => Icons.wb_sunny,
      _ => Icons.warning_amber_rounded,
    };

/// 날씨 아이콘 하나 — 예보 칸이 모두 같은 규칙(평가 10차 10/18). 비는 글꼴에 '비 오는 구름'이 없어 구름 + 빗줄기
/// 세 줄로 그린다(물방울은 습도, 우산은 '챙기세요' 안내로 읽혔다). 나머지는 [_hourIcon].
class KioskWeatherIcon extends StatelessWidget {
  const KioskWeatherIcon(this.icon, {super.key, this.night = false, required this.size, required this.color});
  final String icon;
  final bool night;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (icon != 'rain') return Icon(_hourIcon(icon, night: night), size: size, color: color);
    return SizedBox(
      key: const ValueKey('weather-rain-cloud'),
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(
          left: size * 0.05,
          top: -size * 0.1,
          child: Icon(Icons.cloud, size: size * 0.9, color: color),
        ),
        Positioned.fill(child: CustomPaint(painter: _RainPainter(color))),
      ]),
    );
  }
}

class _RainPainter extends CustomPainter {
  const _RainPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final paint = Paint()
      ..color = color
      ..strokeWidth = (w * 0.09).clamp(1.5, 4.0)
      ..strokeCap = StrokeCap.round;
    for (final x in const [0.32, 0.52, 0.72]) {
      canvas.drawLine(Offset(w * (x + 0.05), h * 0.7), Offset(w * (x - 0.04), h * 0.94), paint);
    }
  }

  @override
  bool shouldRepaint(_RainPainter old) => old.color != color;
}
