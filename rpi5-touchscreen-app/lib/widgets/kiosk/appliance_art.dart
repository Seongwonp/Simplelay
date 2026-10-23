import 'package:appliance_artwork/appliance_artwork.dart';
import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

/// 가전 그림 — 폰 홈과 **같은 선 그림**(`packages/appliance_artwork`, 시안 B 10/24). 장식이라 화면 읽기에서 뺀다.
///
/// 그림이 없는 종류(`other` 등)는 [fallbackIcon]을 같은 크기로 그린다. [color]는 선 색, [paper]는 그림 안 채움.
class KioskApplianceArt extends StatelessWidget {
  const KioskApplianceArt({
    super.key,
    required this.category,
    required this.fallbackIcon,
    this.size = 64,
    this.color,
    this.paper,
  });

  final String category;
  final IconData fallbackIcon;
  final double size;
  final Color? color;
  final Color? paper;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? KioskColors.art;
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: hasApplianceArtwork(category)
            ? CustomPaint(painter: AppliancePainter(category, ink, paper ?? KioskColors.surface))
            : Icon(fallbackIcon, size: size * .65, color: ink),
      ),
    );
  }
}

/// 그림 칸(시안 B `.tile`) — 옅은 면 위 둥근 칸에 가전 그림.
class KioskArtTile extends StatelessWidget {
  const KioskArtTile({super.key, required this.category, required this.fallbackIcon, this.size = 84, this.color});

  final String category;
  final IconData fallbackIcon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: KioskColors.well, borderRadius: BorderRadius.circular(size * 0.19)),
        child: KioskApplianceArt(
            category: category, fallbackIcon: fallbackIcon, size: size * 0.74, color: color, paper: KioskColors.well),
      );
}

/// 어두운 표시창(시안 B `.lcd`) — 실제 가전 패널의 표시창처럼 어두운 면. 밝은 화면에서도 어둡다.
/// 안의 글자는 [KioskColors.glassText]·[KioskColors.glassMuted]를 쓴다.
class KioskGlassPanel extends StatelessWidget {
  const KioskGlassPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        // 위아래 여백은 얇게 — 실행 화면 왼쪽 칸 높이가 빠듯하다(정지 단추 옆 글이 스크롤 아래로 밀리지 않게).
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        decoration: BoxDecoration(
          color: KioskColors.glass,
          borderRadius: BorderRadius.circular(14),
          // 고대비는 바탕도 검정이라 칸 경계가 안 보인다 — 흰 테두리.
          border: KioskColors.highContrast ? Border.all(color: KioskColors.border, width: 2) : null,
        ),
        child: child,
      );
}

/// 어느 가전인지(시안 B `.who`) — 결과 화면(버튼판 그림이 없는 결과) 왼쪽 위의 가전 그림 칸. 실행 계열 화면은 왼쪽 칸 높이가
/// 빠듯해 두지 않는다(위 띠가 가전을 말하고 오른쪽 버튼판 그림이 그 가전이다). 이름은 위 상태 띠가 이미 말하므로 그림만 둔다
/// (평가 17차 10/18 — 본문에 가전 이름 줄을 또 두지 않는다). 장식이라 화면 읽기에서 뺀다.
class KioskWhoRow extends StatelessWidget {
  const KioskWhoRow({super.key, required this.category, required this.fallbackIcon, this.size = 56});

  final String category;
  final IconData fallbackIcon;
  final double size;

  @override
  Widget build(BuildContext context) => KioskArtTile(
      key: const ValueKey('who-row'), category: category, fallbackIcon: fallbackIcon, size: size);
}
