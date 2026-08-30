import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';

class KioskIdleView extends StatefulWidget {
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
    this.onSettingsGesture,
  });

  final DateTime now;
  final bool connected;
  final bool actuatorReady;
  final DateTime? dndUntil;
  final double? temperature;
  final double? humidity;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 우하단 설정 버튼을 2초간 길게 누르면 설정 오버레이를 연다.
  final VoidCallback? onSettingsGesture;

  @override
  State<KioskIdleView> createState() => _KioskIdleViewState();
}

class _KioskIdleViewState extends State<KioskIdleView> {
  static const _timeStyle = TextStyle(
    fontSize: 108,
    fontWeight: FontWeight.w300,
    color: Color(0xFFFAF7F2),
    height: 1.0,
    letterSpacing: -3,
  );

  String get _hour => widget.now.hour.toString().padLeft(2, '0');
  String get _minute => widget.now.minute.toString().padLeft(2, '0');

  String get _dateStr {
    const wd = ['월', '화', '수', '목', '금', '토', '일'];
    final n = widget.now;
    return '${n.month}월 ${n.day}일 ${wd[n.weekday - 1]}요일';
  }

  String? get _sensorStr {
    final t = widget.temperature;
    if (t == null) return null;
    final temp = '${t.toStringAsFixed(1)}°C';
    final hum = widget.humidity != null
        ? ' · ${widget.humidity!.toStringAsFixed(0)}%'
        : '';
    return '$temp$hum';
  }

  String _dndRemaining(DateTime until) {
    final diff = until.difference(widget.now);
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
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ColoredBox(
        color: KioskColors.bg,
        child: Stack(
          children: [
            // ── 날짜 + 온습도 + 시계 ────────────────────────────────────────
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
                        opacity: widget.now.second.isEven ? 0.9 : 0.35,
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

                  // 화면 전체가 눌리면 수동 조작으로 들어가는데, 시계만 보여서는
                  // 그걸 알 방법이 없었다 -- 여백이 문제가 아니라 **발견 가능성**이
                  // 문제였다. 통계로 화면을 채우는 대신 한 줄만 둔다.
                  const SizedBox(height: 26),
                  if (widget.connected)
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.touch_app_outlined,
                            size: 20, color: KioskColors.muted),
                        SizedBox(width: 8),
                        Text(
                          '화면을 눌러 가전 조작',
                          style: TextStyle(
                            fontSize: 18,
                            color: KioskColors.muted,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    )
                  else
                    // 점 두 개로만 알리던 상태 -- 눈으로는 무슨 뜻인지 알 수 없었다
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off_rounded,
                            size: 20, color: KioskColors.warning),
                        SizedBox(width: 8),
                        Text(
                          '기기 연결이 필요해요',
                          style: TextStyle(
                            fontSize: 18,
                            color: KioskColors.warning,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),

            // ── DND 활성 표시 (좌하단) ────────────────────────────────────
            if (widget.dndUntil != null)
              Positioned(
                left: 18,
                bottom: 18,
                child: Text(
                  '방해 금지 · ${_dndRemaining(widget.dndUntil!)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: KioskColors.warning,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 0.3,
                  ),
                ),
              ),

            // ── 우하단: 상태 dot + 설정 버튼 ─────────────────────────────
            // 설정이 5px 점 3연타로만 열리던 시절엔 사실상 기능 은폐였다 —
            // 고령 사용자는 설정이 있다는 사실조차 알 수 없었다. 이제 존재는
            // 드러내되(48px 톱니바퀴, 낮은 대비), 여는 데는 2초 길게 누르기를
            // 요구해 지나가다 잘못 눌리는 것은 막는다.
            Positioned(
              right: 12,
              bottom: 12,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: widget.actuatorReady && widget.connected
                        ? '기기와 서버 모두 정상'
                        : widget.connected
                            ? '서버 정상, 기기 준비 중'
                            : '서버 연결 끊김',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _StatusDot(active: widget.actuatorReady),
                          const SizedBox(width: 5),
                          _StatusDot(active: widget.connected),
                        ],
                      ),
                    ),
                  ),
                  _SettingsButton(onOpen: widget.onSettingsGesture),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 설정 진입 — 존재는 보이되 2초 길게 눌러야 열린다.
class _SettingsButton extends StatefulWidget {
  const _SettingsButton({required this.onOpen});
  final VoidCallback? onOpen;

  @override
  State<_SettingsButton> createState() => _SettingsButtonState();
}

class _SettingsButtonState extends State<_SettingsButton> {
  static const _holdDuration = Duration(seconds: 2);
  Timer? _holdTimer;
  bool _holding = false;

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _startHold() {
    setState(() => _holding = true);
    _holdTimer?.cancel();
    _holdTimer = Timer(_holdDuration, () {
      if (!mounted) return;
      setState(() => _holding = false);
      widget.onOpen?.call();
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    if (mounted && _holding) setState(() => _holding = false);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '설정 열기. 2초간 길게 누르세요.',
      // 타이밍은 Listener(원시 포인터)로 잡는다 — GestureDetector의 탭으로
      // 하면 대기 화면 전체의 길게 누르기(방해 금지)가 0.5초에 제스처 경합에서
      // 이겨 버려 onTapCancel이 날아오고, 설정은 영영 열리지 않는다.
      // 안쪽 GestureDetector의 빈 onTap/onLongPress는 그 바깥 제스처가
      // 대신 발동하는 것을 막는 역할만 한다.
      child: Listener(
        onPointerDown: (_) => _startHold(),
        onPointerUp: (_) => _cancelHold(),
        onPointerCancel: (_) => _cancelHold(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          onLongPress: () {},
          child: SizedBox(
            // 접근성 최소 타깃 — 눌러야 할 대상이 보이는 아이콘보다 커야 한다
            width: 48,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (_holding)
                  SizedBox(
                    width: 34,
                    height: 34,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.0, end: 1.0),
                      duration: _holdDuration,
                      builder: (context, value, _) => CircularProgressIndicator(
                        value: value,
                        strokeWidth: 2,
                        color: KioskColors.primary,
                        backgroundColor: KioskColors.border,
                      ),
                    ),
                  ),
                Icon(
                  Icons.settings_outlined,
                  size: 20,
                  color: _holding
                      ? KioskColors.primary
                      : KioskColors.muted.withValues(alpha: 0.55),
                ),
              ],
            ),
          ),
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
