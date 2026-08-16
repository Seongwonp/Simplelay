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

  String get _clock =>
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 0.7,
          colors: [Color(0x16D9A356), KioskColors.bg],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 이중 링 아이콘
            Container(
              width: 136,
              height: 136,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: KioskColors.primary.withValues(alpha: 0.04),
                border: Border.all(
                  color: KioskColors.primary.withValues(alpha: 0.12),
                  width: 1,
                ),
              ),
              child: Center(
                child: Container(
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: KioskColors.primary.withValues(alpha: 0.10),
                    border: Border.all(
                      color: KioskColors.primary.withValues(alpha: 0.30),
                      width: 1.5,
                    ),
                  ),
                  child: Icon(appliance.icon, color: KioskColors.primary, size: 54),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              appliance.name,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'AI가 패턴을 학습하고 자동으로 제안합니다',
              style: TextStyle(fontSize: 14, color: KioskColors.muted),
            ),
            const SizedBox(height: 36),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: KioskColors.surface,
                border: Border.all(color: KioskColors.border),
                borderRadius: BorderRadius.circular(100),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: connected
                          ? KioskColors.success
                          : const Color(0xFF444444),
                      boxShadow: connected
                          ? [
                              BoxShadow(
                                color: KioskColors.success.withValues(alpha: 0.6),
                                blurRadius: 6,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    connected ? 'RPi 연결됨' : '연결 안 됨',
                    style: const TextStyle(fontSize: 13, color: KioskColors.muted),
                  ),
                  const SizedBox(width: 18),
                  Container(width: 1, height: 15, color: KioskColors.border),
                  const SizedBox(width: 18),
                  Text(
                    _clock,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
