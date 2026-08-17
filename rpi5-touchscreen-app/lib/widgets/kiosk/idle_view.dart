import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

class KioskIdleView extends StatelessWidget {
  const KioskIdleView({
    super.key,
    required this.now,
    required this.connected,
    required this.actuatorReady,
    this.dndUntil,
    this.temperature,
    this.humidity,
    required this.onTap,
    required this.onLongPress,
  });

  final DateTime now;
  final bool connected;
  final bool actuatorReady;
  final DateTime? dndUntil;
  final double? temperature;
  final double? humidity;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

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

  String? get _sensorStr {
    if (temperature == null) return null;
    final temp = '${temperature!.toStringAsFixed(1)}°C';
    final hum = humidity != null ? ' · ${humidity!.toStringAsFixed(0)}%' : '';
    return '$temp$hum';
  }

  String _dndRemaining(DateTime until) {
    final diff = until.difference(now);
    if (diff.isNegative) return '';
    if (diff.inMinutes >= 60) {
      final h = diff.inHours;
      final m = diff.inMinutes.remainder(60);
      return m > 0 ? '$h시간 $m분' : '$h시간';
    }
    return '${diff.inMinutes + 1}분';
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: ColoredBox(
        color: KioskColors.bg,
        child: Stack(
          children: [
            // ── 날짜 + 온습도 + 시계 ──────────────────────────────────────────
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
                  // 센서 유무와 무관하게 항상 같은 공간을 차지해야 값이 늦게
                  // 들어와도(DHT22 폴링 지연 등) 시계 위치가 들썩이지 않는다.
                  // 텍스트 실제 라인 높이는 fontSize보다 크므로(폰트 메트릭
                  // ascent+descent) 여유를 넉넉히 둔다 — 안 그러면 아래가 살짝 잘림.
                  SizedBox(
                    height: 28,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Opacity(
                        opacity: _sensorStr != null ? 1.0 : 0.0,
                        child: Text(
                          _sensorStr ?? '',
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFF8B93A0),
                            fontWeight: FontWeight.w400,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(_hour, style: _timeStyle),
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

            // ── DND 활성 표시 (좌하단) ────────────────────────────────────────
            if (dndUntil != null)
              Positioned(
                left: 18,
                bottom: 18,
                child: Text(
                  '방해 금지 · ${_dndRemaining(dndUntil!)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: KioskColors.warning,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 0.3,
                  ),
                ),
              ),

            // ── 우하단 상태 dot 2개 (actuator · backend) ─────────────────────
            Positioned(
              right: 18,
              bottom: 18,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StatusDot(active: actuatorReady),
                  const SizedBox(width: 5),
                  _StatusDot(active: connected),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active
            ? KioskColors.success.withValues(alpha: 0.65)
            : const Color(0xFF2E3038),
      ),
    );
  }
}
