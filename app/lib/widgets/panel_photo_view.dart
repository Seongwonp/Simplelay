import 'dart:io';

import 'package:flutter/gestures.dart';
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

  /// 기다리는 자리(진한 노랑 실선 사각형, '대기' 글자).
  park,

  /// 방금 짚었고 이름을 기다리는 버튼(점선 원).
  pending,

  /// 프레임 모서리(번호).
  corner,

  /// 녹화 순서 핀(번호가 적힌 채운 원).
  pin,
}

/// 사진 위에 겹치는 누름 장치 칸(누름 장치가 닿는 범위, 2026-10-26).
///
/// [corners]는 사진 px, 늘 처음 그린 순서(왼쪽 위 → 오른쪽 위 → 오른쪽 아래 → 왼쪽 아래)다. 어느 귀퉁이가 원점이고 어느
/// 쪽이 +X·+Y인지는 [orientation]이 정한다. [onCornerMoved]가 있으면 귀퉁이 동그라미를 끌어 옮길 수 있다.
class PanelArea {
  const PanelArea({required this.corners, required this.orientation, this.onCornerMoved});

  final List<PhotoPoint> corners;
  final AreaOrientation orientation;
  final void Function(int index, PhotoPoint point)? onCornerMoved;
}

/// 원점 귀퉁이에 붙는 말 — 처음 쓰는 사람이 '원점'만으로는 무엇인지 몰라 풀어 쓴다.
const kAreaOriginLabel = '원점(누름 장치 출발점)';

/// +Y 화살표의 말. 누름 장치는 +Y 쪽 끝에 모터가 있다(HW 원본 — 원점 좌하단, 모터는 위쪽).
const kAreaYLabel = 'Y · 모터 쪽';

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
    this.area,
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

  /// 겹쳐 그릴 누름 장치 칸. null이면 그리지 않는다.
  final PanelArea? area;

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
                if (area case final a? when a.corners.length == 4)
                  ..._areaLayers(a, toView, box.biggest),
                for (final m in marks) _positioned(context, m, toView(m.point)),
                if (area case final a? when a.corners.length == 4 && a.onCornerMoved != null)
                  ..._areaHandles(a, toView, sx, sy),
              ],
            );
          }),
        ),
      ),
    );
  }

  /// 칸(반투명 채움·굵은 테두리·두 축 화살표)과 원점·축 이름표. 누르기는 막지 않는다.
  List<Widget> _areaLayers(PanelArea a, Offset Function(PhotoPoint) toView, Size size) {
    final view = [for (final c in a.corners) toView(c)];
    final order = a.orientation.cornerOrder;
    final origin = view[order[0]];
    final xEnd = view[order[1]];
    final far = view[order[2]];
    final yEnd = view[order[3]];
    Widget tag(Key key, String text, Offset at, {bool strong = false}) {
      // 이름표가 사진 가장자리 밖으로 잘리지 않게 안쪽으로 당긴다.
      final w = strong ? 168.0 : 96.0;
      final left = (at.dx - w / 2).clamp(0.0, (size.width - w).clamp(0.0, double.infinity)).toDouble();
      final top = (at.dy - 12).clamp(0.0, (size.height - 24).clamp(0.0, double.infinity)).toDouble();
      return Positioned(
        left: left,
        top: top,
        width: w,
        child: IgnorePointer(
          child: Center(
            child: Container(
              key: key,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
              decoration: BoxDecoration(
                color: strong ? AppColors.primary : const Color(0xCC1B1E22),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppFont.caption,
                    fontWeight: FontWeight.w700,
                    color: strong ? AppColors.onAccent : Colors.white,
                  )),
            ),
          ),
        ),
      );
    }

    // 원점 이름표는 칸 바깥쪽(맞은편 귀퉁이 반대쪽)으로 조금 띄운다 — 귀퉁이 동그라미를 가리지 않게.
    final away = origin - far;
    final awayUnit = away.distance == 0 ? Offset.zero : away / away.distance;
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            key: const Key('area-outline'),
            painter: _AreaPainter(corners: view, origin: origin, xEnd: xEnd, yEnd: yEnd),
          ),
        ),
      ),
      tag(const Key('area-origin-label'), kAreaOriginLabel, origin + awayUnit * 30, strong: true),
      tag(const Key('area-x-label'), 'X', origin + (xEnd - origin) * 0.55),
      tag(const Key('area-y-label'), kAreaYLabel, origin + (yEnd - origin) * 0.55),
    ];
  }

  /// 귀퉁이마다 끌 수 있는 동그라미(48dp). 목록 스크롤보다 먼저 잡는다 — 손가락을 대자마자 이 끌기다.
  List<Widget> _areaHandles(PanelArea a, Offset Function(PhotoPoint) toView, double sx, double sy) {
    const touch = 48.0;
    return [
      for (var i = 0; i < 4; i++)
        Positioned(
          left: toView(a.corners[i]).dx - touch / 2,
          top: toView(a.corners[i]).dy - touch / 2,
          width: touch,
          height: touch,
          child: Semantics(
            label: '누름 장치 칸 ${i + 1}번 귀퉁이, 끌어서 옮기기',
            excludeSemantics: true,
            child: RawGestureDetector(
              key: Key('area-corner-$i'),
              behavior: HitTestBehavior.opaque,
              gestures: {
                _EagerPanRecognizer: GestureRecognizerFactoryWithHandlers<_EagerPanRecognizer>(
                  _EagerPanRecognizer.new,
                  // 끌기 시작 자리 + 끈 거리 합으로 옮긴다 — 다시 그리기 전에 움직임이 여러 번 와도 잃지 않게.
                  (r) => r
                    ..onStart = (_) {
                      r.from = a.corners[i];
                      r.moved = Offset.zero;
                    }
                    ..onUpdate = (d) {
                      r.moved += d.delta;
                      final c = r.from ?? a.corners[i];
                      a.onCornerMoved!(
                          i,
                          PhotoPoint(
                            (c.x + r.moved.dx / sx).clamp(0, photoWidth).toDouble(),
                            (c.y + r.moved.dy / sy).clamp(0, photoHeight).toDouble(),
                          ));
                    },
                ),
              },
              child: Center(
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    border: Border.all(color: AppColors.primary, width: 4),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
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
        // 실사용(10/26): 흐린 점선 네모가 사진 위에서 안 보였다 — 굵은 실선·진한 노랑·'대기' 글자.
        return Center(
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0x66FFB300),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _parkColor, width: 3.5),
            ),
            child: const Text('대기',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppFont.caption,
                  fontWeight: FontWeight.w800,
                  shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                )),
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

/// 기다리는 자리 표시 색 — 어두운 사진·밝은 사진 모두에서 보이는 진한 노랑.
const _parkColor = Color(0xFFFFB300);

/// 손가락을 대자마자 끌기로 잡는다 — 목록 안에서도 세로로 끌면 스크롤이 아니라 귀퉁이가 움직이게.
class _EagerPanRecognizer extends PanGestureRecognizer {
  /// 끌기를 시작한 귀퉁이 자리(사진 px)와 그 뒤로 끈 거리(화면).
  PhotoPoint? from;
  Offset moved = Offset.zero;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// 누름 장치 칸 — 반투명 채움, 굵은 테두리, 원점에서 +X·+Y로 가는 화살표.
class _AreaPainter extends CustomPainter {
  _AreaPainter({required this.corners, required this.origin, required this.xEnd, required this.yEnd});
  final List<Offset> corners;
  final Offset origin;
  final Offset xEnd;
  final Offset yEnd;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addPolygon(corners, true);
    canvas.drawPath(path, Paint()..color = AppColors.primary.withValues(alpha: 0.18));
    canvas.drawPath(
        path,
        Paint()
          ..color = AppColors.primary
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke);
    final arrow = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    void drawArrow(Offset to) {
      final from = origin + (to - origin) * 0.08;
      final tip = origin + (to - origin) * 0.42;
      final d = tip - from;
      if (d.distance < 4) return;
      canvas.drawLine(from, tip, arrow);
      final u = d / d.distance;
      final n = Offset(-u.dy, u.dx);
      canvas.drawLine(tip, tip - u * 10 + n * 6, arrow);
      canvas.drawLine(tip, tip - u * 10 - n * 6, arrow);
    }

    drawArrow(xEnd);
    drawArrow(yEnd);
    canvas.drawCircle(origin, 7, Paint()..color = AppColors.primary);
  }

  @override
  bool shouldRepaint(_AreaPainter old) =>
      old.origin != origin || old.xEnd != xEnd || old.yEnd != yEnd || !_same(old.corners, corners);

  static bool _same(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
