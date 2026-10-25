import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/kiosk_time.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';

/// 자리 비움 화면(2026-10-25) — 방에 한동안 사람이 안 보이면 처음 화면 위를 짙은 회색으로 덮고 **시계는 계속 보인다**
/// (10/26 사용자: 까만 화면은 꺼진 것처럼 보인다 — 회색에 시계). 바깥 가장자리도 같은 색([sleepColor], 캔버스가 칠한다).
/// 어디를 눌러도 바로 켜진다(누른 손은 화면 아래 단추에 닿지 않는다).
class KioskRoomSleep extends StatefulWidget {
  const KioskRoomSleep({super.key, required this.onWake, this.now});

  final VoidCallback onWake;

  /// 시험용 시각(없으면 지금).
  final DateTime Function()? now;

  /// 쉬는 화면 바탕 — 짙은 회색(어두운 화면 팔레트의 칸 색, 패널 가장자리까지 같은 색).
  static Color get sleepColor => KioskColors.dark.surface2;

  @override
  State<KioskRoomSleep> createState() => _KioskRoomSleepState();
}

class _KioskRoomSleepState extends State<KioskRoomSleep> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 10), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = (widget.now ?? DateTime.now)();
    const wd = ['월', '화', '수', '목', '금', '토', '일'];
    final date = '${now.month}월 ${now.day}일 ${wd[now.weekday - 1]}요일';
    final soft = KioskColors.dark.muted;
    return Semantics(
      button: true,
      label: '화면이 쉬고 있어요. ${clockTime(now.hour, now.minute)}. 눌러서 켜기',
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('room-sleep'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onWake,
        // Material — 화면 틀(Scaffold) 밖에 놓여도 글자에 노란 밑줄(기본 글자 모양 없음 표시)이 생기지 않게(10/26 실패널).
        child: Material(
          color: KioskRoomSleep.sleepColor,
          // 안내 글은 두지 않는다(10/26 사용자 — 보여 주기식 문구, 실제 제품 시계처럼).
          child: Stack(children: [
            Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic, children: [
                  Text(ampmOf(now.hour),
                      style: TextStyle(fontSize: KioskType.key, fontWeight: FontWeight.w600, color: soft)),
                  const SizedBox(width: 12),
                  Text(clockDigits(now.hour, now.minute),
                      key: const ValueKey('room-sleep-clock'),
                      style: TextStyle(
                          fontSize: KioskType.key * 3, fontWeight: FontWeight.w700, color: soft, height: 1.0,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ]),
                const SizedBox(height: KioskSpace.sm),
                Text(date, style: TextStyle(fontSize: KioskType.status, color: soft)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
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
            padding: const EdgeInsets.symmetric(horizontal: KioskSpace.md, vertical: KioskSpace.xs),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.waving_hand_outlined, size: 20, color: KioskColors.primary),
              const SizedBox(width: KioskSpace.xs),
              Text(text,
                  style: TextStyle(fontSize: KioskType.caption, fontWeight: FontWeight.w800, color: KioskColors.ink)),
            ]),
          ),
        ),
      );
}
