import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';

/// 자리 비움 절전 화면(2026-10-25) — 방에 한동안 사람이 안 보이면 처음 화면 위를 검게 덮는다.
/// 어디를 눌러도 바로 켜진다(누른 손은 화면 아래 단추에 닿지 않는다). 사진은 본체가 남기지 않는다는 말을 작게 둔다.
class KioskRoomSleep extends StatelessWidget {
  const KioskRoomSleep({super.key, required this.onWake});

  final VoidCallback onWake;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: '화면이 쉬고 있어요. 눌러서 켜기',
        excludeSemantics: true,
        child: GestureDetector(
          key: const ValueKey('room-sleep'),
          behavior: HitTestBehavior.opaque,
          onTap: onWake,
          child: const ColoredBox(
            color: Colors.black,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(bottom: KioskSpace.lg),
                child: Text('사람이 보이면 다시 켜져요 · 눌러도 켜져요',
                    style: TextStyle(fontSize: KioskType.caption, color: Color(0xFF5A5F66))),
              ),
            ),
          ),
        ),
      );
}

/// 돌아왔을 때 잠깐 뜨는 인사(2026-10-25). 눌러 닫을 필요 없이 몇 초 뒤 사라진다.
class KioskWelcomeBack extends StatelessWidget {
  const KioskWelcomeBack({super.key, this.text = '어서 오세요'});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        label: text,
        excludeSemantics: true,
        child: Material(
          key: const ValueKey('room-welcome'),
          color: KioskColors.surface,
          elevation: 3,
          shadowColor: KioskColors.ink.withValues(alpha: 0.25),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
            side: BorderSide(color: KioskColors.primary, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: KioskSpace.lg, vertical: KioskSpace.sm),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.waving_hand_outlined, size: 26, color: KioskColors.primary),
              const SizedBox(width: KioskSpace.xs),
              Text(text,
                  style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w800, color: KioskColors.ink)),
            ]),
          ),
        ),
      );
}
