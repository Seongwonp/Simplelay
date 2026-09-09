import 'dart:io';

import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../theme/app_colors.dart';

/// 화면에서 가전을 대표하는 그림.
///
/// 이 앱의 주인공은 앱이 아니라 **그 집의 실제 가전**이다. 그래서 표시
/// 우선순위가 이렇다.
///
/// 1. 사용자가 등록한 사진(`photoPath`)
/// 2. 중립적인 실루엣 — 사진이 없을 때
/// 3. 이름 중심의 타이포그래피 — 실루엣도 어울리지 않는 작은 자리
///
/// **사진 등록을 사용 조건으로 만들지 않는다.** 사진이 없어도 화면이 완성된
/// 것처럼 보여야 하고, 등록 유도는 주 행동과 경쟁하지 않는 작은 자리에 둔다.
///
/// 작은 글리프를 그냥 크게 확대하지 않는다 — 아이콘은 목록의 표식이지
/// 화면의 주인공이 아니라서, 키우면 오히려 시안처럼 보인다.
class AppliancePortrait extends StatelessWidget {
  const AppliancePortrait({
    required this.appliance,
    required this.size,
    this.borderRadius = 16,
    this.imageOverride,
    super.key,
  });

  final ApplianceMap appliance;

  /// 한 변의 길이. 정사각으로 그린다.
  final double size;
  final double borderRadius;

  /// 파일 대신 쓸 이미지. **골든 테스트가 실제 렌더를 확인하기 위한 자리**다
  /// -- 위젯 테스트는 파일 이미지를 디코딩하지 못해서, 이 구멍이 없으면
  /// 크롭·BoxFit·모서리 처리가 아무 데서도 검증되지 않는다.
  final ImageProvider? imageOverride;

  /// 사진이 실제로 열리는가. 경로만 있고 파일이 지워진 경우가 있어서
  /// (다른 폰에서 등록한 가전을 내려받으면 경로만 따라온다) 존재를 확인한다.
  File? get _photo {
    final path = appliance.photoPath;
    if (path == null || path.isEmpty) return null;
    final file = File(path);
    return file.existsSync() ? file : null;
  }

  @override
  Widget build(BuildContext context) {
    final photo = _photo;
    final provider = imageOverride ?? (photo == null ? null : FileImage(photo));

    // 사진이 없을 때는 **배경판을 두지 않는다.** 큰 둥근 회색 사각형 안에
    // 그림 하나를 넣으면 그게 곧 "자리만 차지하는 플레이스홀더 카드"라,
    // 걷어내려던 시안 문법이 화면에서 가장 큰 요소로 돌아온다. 실루엣은
    // 화면 바탕에 그대로 앉힌다.
    if (provider == null) {
      return SizedBox(
        width: size,
        height: size,
        child: _Silhouette(
          size: size,
          color: context.appMuted,
          category: appliance.category,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image(
        image: provider,
        width: size,
        height: size,
        // 사진 비율이 제각각이라 채우고 잘라낸다 -- 여백을 남기면 정사각
        // 프레임 안에 사진이 떠 있는 모양이 된다.
        fit: BoxFit.cover,
        // 파일이 중간에 사라지거나 깨진 이미지일 수 있다. 그때 회색 네모가
        // 남는 것보다 실루엣이 낫다.
        errorBuilder: (context, _, __) => _Silhouette(
          size: size,
          color: context.appMuted,
          category: appliance.category,
        ),
      ),
    );
  }
}

/// 사진이 없을 때의 중립 실루엣.
///
/// 일부러 **도면처럼** 그린다. 그럴듯한 제품 그림을 흉내내면 "사진이 있다"고
/// 오해하게 되고, 사진을 등록할 이유도 사라진다. 선으로만 그린 형태는
/// "여기 사진이 들어갈 자리"라고 스스로 말한다.
class _Silhouette extends StatelessWidget {
  const _Silhouette({
    required this.size,
    required this.color,
    required this.category,
  });

  final double size;
  final Color color;
  final ApplianceCategory category;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _SilhouettePainter(color, category),
      );
}

class _SilhouettePainter extends CustomPainter {
  const _SilhouettePainter(this.color, this.category);

  final Color color;
  final ApplianceCategory category;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (s * 0.018).clamp(1.2, 3.0)
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.55);
    final faint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (s * 0.018).clamp(1.2, 3.0)
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.35);
    final dot = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.45);

    switch (category) {
      case ApplianceCategory.microwave:
        _microwave(canvas, s, line, faint, dot);
      case ApplianceCategory.airConditioner:
        _airConditioner(canvas, s, line, faint, dot);
      case ApplianceCategory.washingMachine:
        _washingMachine(canvas, s, line, faint, dot);
      case ApplianceCategory.induction:
        _induction(canvas, s, line, faint, dot);
      case ApplianceCategory.riceCooker:
        _riceCooker(canvas, s, line, faint, dot);
      case ApplianceCategory.other:
        _generic(canvas, s, line, dot);
    }
  }

  void _box(Canvas c, Rect r, double radius, Paint p) =>
      c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(radius)), p);

  /// 세로로 늘어선 버튼 몇 개. "누르는 기계"라는 것을 실루엣만으로 말한다.
  void _buttonColumn(Canvas c, double s, double x, double top, Paint dot) {
    for (var i = 0; i < 3; i++) {
      c.drawCircle(Offset(x, top + i * s * 0.11), s * 0.025, dot);
    }
  }

  void _microwave(Canvas c, double s, Paint line, Paint faint, Paint dot) {
    _box(c, Rect.fromLTWH(s * 0.16, s * 0.26, s * 0.68, s * 0.48), s * 0.05,
        line);
    // 문 -- 왼쪽 2/3.
    _box(c, Rect.fromLTWH(s * 0.21, s * 0.32, s * 0.40, s * 0.36), s * 0.03,
        faint);
    _buttonColumn(c, s, s * 0.72, s * 0.38, dot);
  }

  void _airConditioner(Canvas c, double s, Paint line, Paint faint, Paint dot) {
    // 벽걸이형 -- 가로로 넓고 납작하다. 전자레인지와 한눈에 달라야 한다.
    _box(c, Rect.fromLTWH(s * 0.10, s * 0.34, s * 0.80, s * 0.28), s * 0.07,
        line);
    // 아래쪽 바람 날개.
    for (var i = 0; i < 2; i++) {
      final y = s * 0.52 + i * s * 0.05;
      c.drawLine(Offset(s * 0.16, y), Offset(s * 0.72, y), faint);
    }
    // 표시등.
    c.drawCircle(Offset(s * 0.80, s * 0.55), s * 0.022, dot);
  }

  void _washingMachine(Canvas c, double s, Paint line, Paint faint, Paint dot) {
    _box(c, Rect.fromLTWH(s * 0.22, s * 0.18, s * 0.56, s * 0.64), s * 0.06,
        line);
    // 조작부는 위, 문은 원형.
    c.drawLine(Offset(s * 0.22, s * 0.34), Offset(s * 0.78, s * 0.34), faint);
    c.drawCircle(Offset(s * 0.50, s * 0.58), s * 0.16, faint);
    for (var i = 0; i < 3; i++) {
      c.drawCircle(Offset(s * 0.32 + i * s * 0.09, s * 0.26), s * 0.022, dot);
    }
  }

  void _induction(Canvas c, double s, Paint line, Paint faint, Paint dot) {
    // 위에서 본 상판 -- 화구 두 개와 아래쪽 조작 띠.
    _box(c, Rect.fromLTWH(s * 0.14, s * 0.28, s * 0.72, s * 0.44), s * 0.05,
        line);
    c.drawCircle(Offset(s * 0.36, s * 0.44), s * 0.11, faint);
    c.drawCircle(Offset(s * 0.64, s * 0.44), s * 0.08, faint);
    for (var i = 0; i < 4; i++) {
      c.drawCircle(Offset(s * 0.30 + i * s * 0.13, s * 0.64), s * 0.022, dot);
    }
  }

  void _riceCooker(Canvas c, double s, Paint line, Paint faint, Paint dot) {
    // 둥근 몸통 + 뚜껑 선 + 손잡이.
    _box(c, Rect.fromLTWH(s * 0.20, s * 0.32, s * 0.60, s * 0.42), s * 0.14,
        line);
    c.drawLine(Offset(s * 0.22, s * 0.46), Offset(s * 0.78, s * 0.46), faint);
    c.drawArc(
      Rect.fromLTWH(s * 0.34, s * 0.16, s * 0.32, s * 0.28),
      3.14159,
      3.14159,
      false,
      faint,
    );
    for (var i = 0; i < 3; i++) {
      c.drawCircle(Offset(s * 0.38 + i * s * 0.12, s * 0.60), s * 0.022, dot);
    }
  }

  void _generic(Canvas c, double s, Paint line, Paint dot) {
    // 종류를 모른다. 특정 제품을 흉내내지 않고, 버튼판만 남긴다 --
    // 이 앱이 다루는 공통점은 "누를 버튼이 있다"는 것뿐이다.
    _box(c, Rect.fromLTWH(s * 0.20, s * 0.24, s * 0.60, s * 0.52), s * 0.06,
        line);
    for (var y = 0; y < 3; y++) {
      for (var x = 0; x < 3; x++) {
        c.drawCircle(
          Offset(s * 0.33 + x * s * 0.17, s * 0.36 + y * s * 0.14),
          s * 0.026,
          dot,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SilhouettePainter old) =>
      old.color != color || old.category != category;
}

/// 사진이 없을 때 한 번만 권하는 작은 행동.
///
/// 주 행동과 경쟁하지 않도록 텍스트 버튼으로 둔다. 거절해도 앱은 그대로
/// 쓸 수 있어야 한다.
class AddPhotoHint extends StatelessWidget {
  const AddPhotoHint({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton.icon(
        onPressed: onTap,
        style: TextButton.styleFrom(
          // 고령 사용자 기준 최소 터치 대상.
          minimumSize: const Size(0, 48),
          foregroundColor: context.appMuted,
        ),
        icon: const Icon(Icons.add_a_photo_outlined, size: 18),
        label: const Text('가전 사진 추가', style: TextStyle(fontSize: 14)),
      );
}
