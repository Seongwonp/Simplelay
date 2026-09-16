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
/// 2. 무채색 평면 일러스트 — 사진이 없을 때
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
          category: appliance.category,
        ),
      ),
    );
  }
}

/// 사진이 없을 때의 가전 그림.
///
/// **평면 일러스트**로 그린다. 선 몇 개만 옅게 그리면 "그림이 들어갈 자리"로
/// 읽혀 화면이 미완성처럼 보였다(9/16 화면 평가). 반대로 사진처럼 그럴듯한
/// 제품 그림은 사진이 이미 있다고 오해하게 한다. 그래서 그 중간:
///
/// - 몸체는 카드와 같은 면색, 윤곽은 글자와 같은 무채색 -- 강조색을 쓰지
///   않는다. 화면의 보라는 주 행동 몫이다.
/// - 유리(문 창·화구)는 옅은 채움, 표시창은 짙은 채움 -- 재질 두 가지로만.
/// - 모든 종류에 **누를 버튼이 보인다.** 이 앱이 다루는 공통점이다.
class _Silhouette extends StatelessWidget {
  const _Silhouette({required this.size, required this.category});

  final double size;
  final ApplianceCategory category;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _SilhouettePainter(
          ink: context.appInk,
          body: context.appSurfaceLow,
          category: category,
        ),
      );
}

class _SilhouettePainter extends CustomPainter {
  const _SilhouettePainter({
    required this.ink,
    required this.body,
    required this.category,
  });

  final Color ink;
  final Color body;
  final ApplianceCategory category;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final stroke = (s * 0.02).clamp(1.5, 4.0);
    final p = _Pens(
      body: Paint()..color = body,
      line: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = ink.withValues(alpha: 0.78),
      detail: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke * 0.7
        ..strokeCap = StrokeCap.round
        ..color = ink.withValues(alpha: 0.45),
      glass: Paint()..color = ink.withValues(alpha: 0.10),
      solid: Paint()..color = ink.withValues(alpha: 0.78),
      soft: Paint()..color = ink.withValues(alpha: 0.30),
    );

    switch (category) {
      case ApplianceCategory.microwave:
        _microwave(canvas, s, p);
      case ApplianceCategory.airConditioner:
        _airConditioner(canvas, s, p);
      case ApplianceCategory.washingMachine:
        _washingMachine(canvas, s, p);
      case ApplianceCategory.induction:
        _induction(canvas, s, p);
      case ApplianceCategory.riceCooker:
        _riceCooker(canvas, s, p);
      case ApplianceCategory.other:
        _generic(canvas, s, p);
    }
  }

  RRect _r(double s, double l, double t, double w, double h, double radius) =>
      RRect.fromRectAndRadius(
        Rect.fromLTWH(s * l, s * t, s * w, s * h),
        Radius.circular(s * radius),
      );

  /// 면을 칠하고 윤곽을 두른다.
  void _shape(Canvas c, RRect r, Paint fill, Paint line) {
    c.drawRRect(r, fill);
    c.drawRRect(r, line);
  }

  void _microwave(Canvas c, double s, _Pens p) {
    // 다리.
    c.drawRRect(_r(s, 0.19, 0.735, 0.07, 0.035, 0.012), p.solid);
    c.drawRRect(_r(s, 0.74, 0.735, 0.07, 0.035, 0.012), p.solid);
    _shape(c, _r(s, 0.12, 0.25, 0.76, 0.49, 0.06), p.body, p.line);
    // 문과 창.
    c.drawRRect(_r(s, 0.17, 0.30, 0.47, 0.39, 0.03), p.detail);
    c.drawRRect(_r(s, 0.21, 0.34, 0.33, 0.31, 0.025), p.glass);
    // 손잡이.
    c.drawLine(Offset(s * 0.59, s * 0.37), Offset(s * 0.59, s * 0.62), p.line);
    // 조작부: 표시창 + 버튼 2열 3행.
    c.drawLine(Offset(s * 0.69, s * 0.25), Offset(s * 0.69, s * 0.74), p.detail);
    c.drawRRect(_r(s, 0.725, 0.31, 0.12, 0.06, 0.012), p.solid);
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 2; col++) {
        c.drawRRect(
          _r(s, 0.725 + col * 0.07, 0.42 + row * 0.085, 0.05, 0.045, 0.01),
          p.soft,
        );
      }
    }
  }

  void _airConditioner(Canvas c, double s, _Pens p) {
    // 벽걸이형 -- 가로로 넓고 납작하다. 전자레인지와 한눈에 달라야 한다.
    _shape(c, _r(s, 0.08, 0.28, 0.84, 0.30, 0.08), p.body, p.line);
    // 앞판 이음선과 토출구.
    c.drawLine(Offset(s * 0.12, s * 0.46), Offset(s * 0.88, s * 0.46), p.detail);
    c.drawRRect(_r(s, 0.16, 0.495, 0.68, 0.045, 0.02), p.glass);
    // 온도 표시창과 전원 표시등.
    c.drawRRect(_r(s, 0.66, 0.35, 0.13, 0.055, 0.012), p.solid);
    c.drawCircle(Offset(s * 0.83, s * 0.3775), s * 0.016, p.soft);
    // 아래로 살짝 열린 바람 날개.
    final flap = Path()
      ..moveTo(s * 0.20, s * 0.585)
      ..quadraticBezierTo(s * 0.50, s * 0.66, s * 0.80, s * 0.585);
    c.drawPath(flap, p.line);
  }

  void _washingMachine(Canvas c, double s, _Pens p) {
    _shape(c, _r(s, 0.22, 0.13, 0.56, 0.72, 0.05), p.body, p.line);
    // 조작부: 다이얼 + 표시창 + 버튼.
    c.drawLine(Offset(s * 0.22, s * 0.28), Offset(s * 0.78, s * 0.28), p.detail);
    c.drawCircle(Offset(s * 0.32, s * 0.205), s * 0.038, p.line);
    c.drawRRect(_r(s, 0.43, 0.18, 0.16, 0.05, 0.012), p.solid);
    c.drawRRect(_r(s, 0.64, 0.185, 0.04, 0.04, 0.01), p.soft);
    c.drawRRect(_r(s, 0.70, 0.185, 0.04, 0.04, 0.01), p.soft);
    // 문: 바깥 테와 유리.
    final door = Offset(s * 0.50, s * 0.56);
    c.drawCircle(door, s * 0.19, p.line);
    c.drawCircle(door, s * 0.135, p.glass);
    c.drawCircle(door, s * 0.135, p.detail);
  }

  void _induction(Canvas c, double s, _Pens p) {
    // 위에서 본 상판 -- 화구 두 개와 아래쪽 터치 조작 띠.
    _shape(c, _r(s, 0.10, 0.27, 0.80, 0.46, 0.05), p.body, p.line);
    for (final (x, r) in [(0.34, 0.12), (0.67, 0.09)]) {
      final center = Offset(s * x, s * 0.45);
      c.drawCircle(center, s * r, p.glass);
      c.drawCircle(center, s * r, p.detail);
      c.drawCircle(center, s * r * 0.55, p.detail);
    }
    c.drawLine(Offset(s * 0.10, s * 0.62), Offset(s * 0.90, s * 0.62), p.detail);
    c.drawRRect(_r(s, 0.17, 0.645, 0.12, 0.05, 0.012), p.solid);
    for (var i = 0; i < 5; i++) {
      c.drawCircle(Offset(s * (0.40 + i * 0.095), s * 0.67), s * 0.02, p.soft);
    }
  }

  void _riceCooker(Canvas c, double s, _Pens p) {
    // 손잡이 → 몸통 → 뚜껑 순으로 겹친다.
    _shape(c, _r(s, 0.38, 0.20, 0.24, 0.07, 0.035), p.body, p.line);
    _shape(c, _r(s, 0.18, 0.34, 0.64, 0.44, 0.17), p.body, p.line);
    _shape(c, _r(s, 0.21, 0.26, 0.58, 0.14, 0.07), p.body, p.line);
    // 앞판: 표시창 + 버튼 두 개.
    c.drawRRect(_r(s, 0.33, 0.50, 0.34, 0.17, 0.03), p.glass);
    c.drawRRect(_r(s, 0.33, 0.50, 0.34, 0.17, 0.03), p.detail);
    c.drawRRect(_r(s, 0.40, 0.53, 0.20, 0.045, 0.01), p.solid);
    c.drawCircle(Offset(s * 0.44, s * 0.625), s * 0.02, p.soft);
    c.drawCircle(Offset(s * 0.56, s * 0.625), s * 0.02, p.soft);
  }

  void _generic(Canvas c, double s, _Pens p) {
    // 종류를 모른다. 특정 제품을 흉내내지 않고, 표시창과 버튼판만 남긴다 --
    // 이 앱이 다루는 공통점은 "누를 버튼이 있다"는 것뿐이다.
    _shape(c, _r(s, 0.22, 0.18, 0.56, 0.64, 0.07), p.body, p.line);
    c.drawRRect(_r(s, 0.30, 0.26, 0.40, 0.10, 0.02), p.solid);
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        c.drawRRect(
          _r(s, 0.30 + col * 0.145, 0.44 + row * 0.11, 0.11, 0.075, 0.02),
          p.soft,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SilhouettePainter old) =>
      old.ink != ink || old.body != body || old.category != category;
}

class _Pens {
  const _Pens({
    required this.body,
    required this.line,
    required this.detail,
    required this.glass,
    required this.solid,
    required this.soft,
  });

  /// 몸체 면(카드와 같은 색).
  final Paint body;

  /// 바깥 윤곽.
  final Paint line;

  /// 문·이음선 같은 안쪽 선.
  final Paint detail;

  /// 유리·화구 같은 옅은 면.
  final Paint glass;

  /// 표시창·다리 같은 짙은 면.
  final Paint solid;

  /// 버튼.
  final Paint soft;
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
