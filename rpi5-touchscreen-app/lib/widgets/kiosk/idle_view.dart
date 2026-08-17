import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';

class KioskIdleView extends StatelessWidget {
  const KioskIdleView({
    super.key,
    required this.appliance,
    required this.connected,
    required this.now,
  });

  final ApplianceMap appliance;
  final bool connected;
  final DateTime now;

  static const _timeStyle = TextStyle(
    fontSize: 108,
    fontWeight: FontWeight.w300,
    color: Color(0xFFFAF7F2),
    height: 1.0,
    letterSpacing: -3,
  );

  String get _hour   => now.hour.toString().padLeft(2, '0');
  String get _minute => now.minute.toString().padLeft(2, '0');

  String get _dateStr {
    const wd = ['월', '화', '수', '목', '금', '토', '일'];
    return '${now.month}월 ${now.day}일 ${wd[now.weekday - 1]}요일';
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: KioskColors.bg,
      child: Stack(
        children: [
          // ── 날짜 + 시계 ────────────────────────────────────────────────────
          Align(
            alignment: const Alignment(0, -0.08),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _dateStr,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: KioskColors.muted,
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(_hour,   style: _timeStyle),
                    // 콜론: 초에 맞춰 살짝 희미해졌다 돌아옴
                    AnimatedOpacity(
                      opacity: now.second.isEven ? 0.9 : 0.35,
                      duration: const Duration(milliseconds: 400),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          ':',
                          style: TextStyle(
                            fontSize: 88,
                            fontWeight: FontWeight.w200,
                            color: Color(0xFFFAF7F2),
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),
                    Text(_minute, style: _timeStyle),
                  ],
                ),
              ],
            ),
          ),

          // ── 우하단 연결 상태 dot ────────────────────────────────────────────
          Positioned(
            right: 18,
            bottom: 18,
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: connected
                    ? KioskColors.success.withValues(alpha: 0.65)
                    : const Color(0xFF2E3038),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
