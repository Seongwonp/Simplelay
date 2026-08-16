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

  String get _hour   => now.hour.toString().padLeft(2, '0');
  String get _minute => now.minute.toString().padLeft(2, '0');
  String get _second => now.second.toString().padLeft(2, '0');

  String get _dateStr {
    const wd = ['월', '화', '수', '목', '금', '토', '일'];
    return '${now.month}월 ${now.day}일 ${wd[now.weekday - 1]}요일';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.1),
          radius: 1.1,
          colors: [Color(0x22D9A356), KioskColors.bg, KioskColors.bg],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        children: [
          // ── 중앙: 날짜 + 시계 + 배지 ──────────────────────────────────────
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 날짜
                Text(
                  _dateStr,
                  style: const TextStyle(
                    fontSize: 15,
                    color: KioskColors.muted,
                    letterSpacing: 2.5,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 18),

                // ── 시:분 + 장식선 ─────────────────────────────────────────
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 왼쪽 장식선
                    Container(
                      width: 72,
                      height: 1,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Colors.transparent, Color(0x66D9A356)],
                        ),
                      ),
                    ),
                    const SizedBox(width: 20),

                    // 시
                    _TimeSegment(_hour),

                    // 콜론 (짝수 초: 선명, 홀수 초: 희미)
                    AnimatedOpacity(
                      opacity: now.second.isEven ? 1.0 : 0.25,
                      duration: const Duration(milliseconds: 300),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          ':',
                          style: TextStyle(
                            fontSize: 96,
                            fontWeight: FontWeight.w200,
                            color: KioskColors.primary,
                            height: 1.0,
                          ),
                        ),
                      ),
                    ),

                    // 분
                    _TimeSegment(_minute),

                    const SizedBox(width: 20),
                    // 오른쪽 장식선
                    Container(
                      width: 72,
                      height: 1,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [Color(0x66D9A356), Colors.transparent],
                        ),
                      ),
                    ),
                  ],
                ),

                // 초
                const SizedBox(height: 4),
                Text(
                  _second,
                  style: TextStyle(
                    fontSize: 16,
                    color: KioskColors.primary.withValues(alpha: 0.45),
                    fontWeight: FontWeight.w300,
                    letterSpacing: 4,
                  ),
                ),

                const SizedBox(height: 28),

                // ── 가전 + AI 모니터링 배지 ───────────────────────────────
                _MonitoringBadge(appliance: appliance),
              ],
            ),
          ),

          // ── 하단: 연결 상태 ────────────────────────────────────────────────
          Positioned(
            left: 0,
            right: 0,
            bottom: 18,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? KioskColors.success
                        : const Color(0xFF3A3A3A),
                    boxShadow: connected
                        ? [
                            BoxShadow(
                              color: KioskColors.success.withValues(alpha: 0.7),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  connected ? 'RPi 연결됨' : '연결 안 됨',
                  style: const TextStyle(
                    fontSize: 12,
                    color: KioskColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 골드 그라디언트 시간 숫자 ─────────────────────────────────────────────────
class _TimeSegment extends StatelessWidget {
  const _TimeSegment(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFFFEBC0), KioskColors.primary],
        stops: [0.0, 1.0],
      ).createShader(bounds),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 108,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          height: 1.0,
          letterSpacing: -3,
        ),
      ),
    );
  }
}

// ── 가전 + AI 모니터링 배지 ───────────────────────────────────────────────────
class _MonitoringBadge extends StatelessWidget {
  const _MonitoringBadge({required this.appliance});
  final ApplianceMap appliance;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: KioskColors.border),
        boxShadow: [
          BoxShadow(
            color: KioskColors.primary.withValues(alpha: 0.08),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(appliance.icon, size: 14, color: KioskColors.primary),
          const SizedBox(width: 8),
          Text(
            appliance.name,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 14),
          Container(width: 1, height: 13, color: KioskColors.border),
          const SizedBox(width: 14),
          const Text(
            'AI 모니터링 중',
            style: TextStyle(fontSize: 13, color: KioskColors.muted),
          ),
          const SizedBox(width: 10),
          // 펄스 닷
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: KioskColors.primary,
              boxShadow: [
                BoxShadow(
                  color: KioskColors.primary.withValues(alpha: 0.7),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
