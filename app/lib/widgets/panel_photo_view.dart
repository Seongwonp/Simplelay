import 'dart:io';

import 'package:flutter/material.dart';

import '../models/hub.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 골든·위젯 테스트가 실제 사진 렌더를 확인하기 위해 끼우는 이미지.
///
/// 파일 이미지는 위젯 테스트에서 디코딩되지 않아, 이 구멍이 없으면 사진
/// 패널의 비율·표시 위치가 아무 데서도 검증되지 않는다. **앱 실행 중에는 항상
/// null이다** -- 테스트 밖에서 값을 넣지 않는다.
ImageProvider? applianceImageOverride;

/// 사진 위 표시 하나의 종류.
enum PanelMarkKind {
  /// 등록한 버튼(강조색 원).
  button,

  /// 정지(취소) 버튼(빨간 원, 두꺼운 테두리). 색만이 아니라 '정지' 글자도 붙인다.
  stop,

  /// 쉬는 자리(점선 사각형).
  park,

  /// 방금 짚었고 이름을 기다리는 버튼(점선 원).
  pending,

  /// 프레임 모서리(번호).
  corner,

  /// 녹화 순서 핀(번호가 적힌 채운 원).
  pin,
}

class PanelMark {
  const PanelMark({
    required this.id,
    required this.kind,
    required this.point,
    this.label,
    this.number,
  });

  final String id;
  final PanelMarkKind kind;

  /// 사진 px.
  final PhotoPoint point;

  /// 읽어 줄 이름(버튼 이름). 화면 읽기와 테스트가 쓴다.
  final String? label;

  /// 핀·모서리 번호.
  final int? number;
}

/// 조작부 사진 위에 버튼 자리를 얹는 패널 — 가전 상세·루틴 녹화·가전 추가가
/// 같이 쓴다.
///
/// 좌표는 **사진 px**로 받고 화면 크기에 맞춰 옮긴다. 패널은 사진 비율을
/// 그대로 지키므로(늘이거나 자르지 않는다) 짚은 자리와 그려진 자리가 어긋나지
/// 않는다. 사진 파일이 없거나 읽지 못하면 어두운 판만 그린다 -- 버튼 자리는
/// 서버가 기억하는 값이라 그대로 보인다.
class PanelPhotoView extends StatelessWidget {
  const PanelPhotoView({
    super.key,
    required this.photoWidth,
    required this.photoHeight,
    this.photoPath,
    this.image,
    this.marks = const [],
    this.onTapPhoto,
    this.onTapMark,
    required this.semanticsLabel,
    this.markSemanticSuffix,
  });

  final double photoWidth;
  final double photoHeight;

  /// 이 폰에 저장한 사진 경로.
  final String? photoPath;

  /// 테스트·골든이 끼우는 이미지. 있으면 [photoPath]보다 먼저다.
  final ImageProvider? image;
  final List<PanelMark> marks;

  /// 빈 자리를 짚었을 때(사진 px). null이면 빈 자리는 반응하지 않는다.
  final void Function(PhotoPoint point)? onTapPhoto;

  /// 표시를 눌렀을 때. null이면 표시는 읽기 전용이다.
  final void Function(PanelMark mark)? onTapMark;
  final String semanticsLabel;

  /// 누를 수 있는 자리의 낭독 뒤에 붙일 말(예: '지금은 쓸 수 없어요'). null이면 붙이지 않는다.
  final String? markSemanticSuffix;

  ImageProvider? get _provider {
    if (image != null) return image;
    final path = photoPath;
    if (path == null || path.isEmpty) return null;
    return FileImage(File(path));
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    return Semantics(
      label: semanticsLabel,
      container: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: AspectRatio(
          aspectRatio: photoWidth / photoHeight,
          child: LayoutBuilder(builder: (context, box) {
            final sx = box.maxWidth / photoWidth;
            final sy = box.maxHeight / photoHeight;
            Offset toView(PhotoPoint p) => Offset(p.x * sx, p.y * sy);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: const Color(0xFF2A2D32),
                    child: provider == null
                        ? null
                        : Image(
                            image: provider,
                            fit: BoxFit.fill,
                            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                          ),
                  ),
                ),
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: onTapPhoto == null
                        ? null
                        : (d) => onTapPhoto!(PhotoPoint(
                              (d.localPosition.dx / sx)
                                  .clamp(0, photoWidth)
                                  .toDouble(),
                              (d.localPosition.dy / sy)
                                  .clamp(0, photoHeight)
                                  .toDouble(),
                            )),
                  ),
                ),
                for (final m in marks) _positioned(context, m, toView(m.point)),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _positioned(BuildContext context, PanelMark m, Offset at) {
    // 터치 대상은 48dp 이상(접근성 최소, 첫 사용 검토 10/19 — 버튼 44·기다리는 자리 40이었다). 그림은 그 안에
    // 종전 크기로 그린다.
    const touch = 48.0;
    final child = _MarkGlyph(mark: m);
    final tappable = onTapMark != null &&
        m.kind != PanelMarkKind.corner &&
        m.kind != PanelMarkKind.pin;
    const size = touch;
    // 핀·모서리는 읽기용이라 터치를 막지 않는다 -- 녹화 중에 핀이 버튼을
    // 덮어도 같은 버튼을 한 번 더 짚을 수 있어야 한다.
    final small = m.kind == PanelMarkKind.pin ? 26.0 : size;
    final shift = m.kind == PanelMarkKind.pin ? const Offset(16, -16) : Offset.zero;
    return Positioned(
      left: at.dx + shift.dx - small / 2,
      top: at.dy + shift.dy - small / 2,
      width: small,
      height: small,
      child: Semantics(
        button: tappable,
        label: tappable && markSemanticSuffix != null ? '${_semantic(m)}, $markSemanticSuffix' : _semantic(m),
        excludeSemantics: true,
        child: tappable
            ? GestureDetector(
                key: Key('mark-${m.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onTapMark!(m),
                child: child,
              )
            : IgnorePointer(key: Key('mark-${m.id}'), child: child),
      ),
    );
  }

  static String _semantic(PanelMark m) => switch (m.kind) {
        PanelMarkKind.stop => '정지 버튼 ${m.label ?? ''}'.trim(),
        PanelMarkKind.park => '기다리는 자리',
        // 가전 추가 화면과 같은 말 — '모서리'는 사진 모서리로 읽혔다(실화면 10/19, 첫 사용 검토 10/19 #4).
        PanelMarkKind.corner => '${m.number ?? ''}번 귀퉁이',
        PanelMarkKind.pin => '${m.number}번째 ${m.label ?? ''}'.trim(),
        _ => m.label ?? '버튼',
      };
}

class _MarkGlyph extends StatelessWidget {
  const _MarkGlyph({required this.mark});
  final PanelMark mark;

  @override
  Widget build(BuildContext context) {
    // 사진 위는 늘 어두운 판이라 다크 팔레트의 강조색을 쓴다(라이트 강조색은
    // 어두운 사진 위에서 대비가 무너진다).
    const accent = AppColors.primary;
    const danger = AppColors.danger;
    switch (mark.kind) {
      case PanelMarkKind.button:
        return Center(
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: accent, width: 2.5),
            ),
          ),
        );
      case PanelMarkKind.stop:
        return Center(
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: danger, width: 3.5),
            ),
            // 색만으로 정지를 말하지 않는다.
            child: const Icon(Icons.stop, size: 16, color: danger),
          ),
        );
      case PanelMarkKind.park:
        return Center(
          child: SizedBox(
            width: 40,
            height: 40,
            child: CustomPaint(
              painter: _DashedRectPainter(color: const Color(0xFFC9CDD2)),
              child: const Center(
                child: Icon(Icons.local_parking, size: 16, color: Color(0xFFC9CDD2)),
              ),
            ),
          ),
        );
      case PanelMarkKind.pending:
        return Center(
          child: CustomPaint(
            size: const Size(36, 36),
            painter: _DashedCirclePainter(color: accent),
          ),
        );
      case PanelMarkKind.corner:
      case PanelMarkKind.pin:
        return Center(
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: mark.kind == PanelMarkKind.pin
                  ? BoxShape.circle
                  : BoxShape.rectangle,
              borderRadius: mark.kind == PanelMarkKind.corner
                  ? BorderRadius.circular(4)
                  : null,
              color: accent,
            ),
            child: Text(
              '${mark.number ?? ''}',
              style: const TextStyle(
                color: AppColors.onAccent,
                fontSize: AppFont.caption,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
    }
  }
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const dash = 4.0;
    const gap = 3.0;
    void line(Offset a, Offset b) {
      final total = (b - a).distance;
      final dir = (b - a) / total;
      var d = 0.0;
      while (d < total) {
        final end = (d + dash).clamp(0, total).toDouble();
        canvas.drawLine(a + dir * d, a + dir * end, paint);
        d += dash + gap;
      }
    }

    final r = Offset.zero & size;
    line(r.topLeft, r.topRight);
    line(r.topRight, r.bottomRight);
    line(r.bottomRight, r.bottomLeft);
    line(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(_DashedRectPainter old) => old.color != color;
}

class _DashedCirclePainter extends CustomPainter {
  _DashedCirclePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final rect = Offset.zero & size;
    const segments = 12;
    const sweep = 3.14159 * 2 / segments;
    for (var i = 0; i < segments; i++) {
      canvas.drawArc(rect.deflate(1.5), i * sweep, sweep * 0.6, false, paint);
    }
    canvas.drawCircle(
      rect.center,
      size.width / 2 - 2,
      Paint()..color = color.withValues(alpha: 0.25),
    );
  }

  @override
  bool shouldRepaint(_DashedCirclePainter old) => old.color != color;
}
