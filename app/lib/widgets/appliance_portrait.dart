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
        child: _Silhouette(size: size, color: context.appMuted),
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
        errorBuilder: (context, _, __) =>
            _Silhouette(size: size, color: context.appMuted),
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
  const _Silhouette({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _SilhouettePainter(color),
      );
}

class _SilhouettePainter extends CustomPainter {
  const _SilhouettePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final stroke = (s * 0.018).clamp(1.2, 3.0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.55);

    // 본체 — 가로로 조금 넓은 상자.
    final body = Rect.fromLTWH(s * 0.16, s * 0.26, s * 0.68, s * 0.48);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, Radius.circular(s * 0.05)),
      paint,
    );

    // 문 — 왼쪽 2/3.
    final door = Rect.fromLTWH(s * 0.21, s * 0.32, s * 0.40, s * 0.36);
    canvas.drawRRect(
      RRect.fromRectAndRadius(door, Radius.circular(s * 0.03)),
      paint..color = color.withValues(alpha: 0.35),
    );

    // 조작부 — 오른쪽 세로 띠에 버튼 세 개. 이 제품이 "누르는" 기계라는
    // 것을 실루엣만으로도 말한다.
    final dot = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.45);
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        Offset(s * 0.72, s * 0.38 + i * s * 0.11),
        s * 0.025,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(_SilhouettePainter old) => old.color != color;
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
