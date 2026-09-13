import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../theme/kiosk_colors.dart';

/// 대기 화면 — 가전 옆에 놓인 **전용 리모컨**의 첫 모습.
///
/// 예전에는 108px 시계가 화면의 주인공이라 보기 좋았지만, 이 기계가 무엇을
/// 하는지·지금 쓸 수 있는지는 말하지 않았다. 1.5~2m 떨어져서 읽혀야 하는 것은
/// 시각이 아니라 **어느 가전을 · 지금 조작할 수 있는지 · 어떻게 시작하는지**다.
/// 시각·날짜·온습도는 위쪽 보조 정보로 내린다.
class KioskIdleView extends StatefulWidget {
  const KioskIdleView({
    super.key,
    required this.now,
    required this.connected,
    required this.actuatorReady,
    this.appliance,
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

  /// 지금 조작 대상인 가전. **서버 목록에서 확인된 가전만** 들어온다 --
  /// 서버를 못 봤으면 null이고, 그때는 가전 이름을 지어내지 않는다.
  final ApplianceMap? appliance;
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

  /// 지금 조작할 수 있는지를 사람의 문장으로. 폰 홈과 같은 말을 쓴다.
  ///
  /// 모르는 것을 준비됐다고 말하지 않는다 -- 서버가 준비 상태를 알려준
  /// 경우에만 못 쓴다고 단정하고, 모양(아이콘)이 색과 같이 간다.
  (IconData, String, bool) _readiness() {
    if (!widget.connected) {
      return (Icons.cloud_off_rounded, '기기 연결이 필요해요', true);
    }
    final a = widget.appliance;
    if (a != null && a.readiness != 'unknown' && !a.canExecute) {
      if (a.readinessReasons.isNotEmpty) {
        return (Icons.build_outlined, a.readinessReasons.first, true);
      }
      return a.readiness == 'disconnected'
          ? (Icons.link_off, '아직 연결되지 않았어요', true)
          : (Icons.build_outlined, '아직 준비가 끝나지 않았어요', true);
    }
    if (!widget.actuatorReady) {
      return (Icons.hourglass_empty, '누르는 장치를 준비하고 있어요', false);
    }
    return (Icons.check_circle_outline, '조작 가능', false);
  }

  @override
  Widget build(BuildContext context) {
    final appliance = widget.appliance;
    final (readyIcon, readyText, warn) = _readiness();
    final readyColor = warn ? KioskColors.warning : Colors.white;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: ColoredBox(
        color: KioskColors.bg,
        child: Stack(
          children: [
            // ── 위: 보조 정보 (날짜·시각 / 온습도) ─────────────────────────
            Positioned(
              left: 32,
              right: 32,
              top: 24,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$_dateStr · $_hour:$_minute',
                      style: const TextStyle(
                        fontSize: 22,
                        color: KioskColors.muted,
                      ),
                    ),
                  ),
                  if (_sensorStr != null)
                    Text(
                      _sensorStr!,
                      style: const TextStyle(
                        fontSize: 22,
                        color: KioskColors.muted,
                      ),
                    ),
                ],
              ),
            ),

            // ── 가운데: 어느 가전 · 지금 되는가 · 어떻게 시작 ──────────────
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(48, 72, 48, 76),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (appliance != null) ...[
                      Row(
                        children: [
                          Icon(appliance.icon,
                              size: 52, color: KioskColors.muted),
                          const SizedBox(width: 18),
                          Flexible(
                            child: Text(
                              appliance.name,
                              style: const TextStyle(
                                fontSize: 48,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 1.15,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                    // 점 두 개로만 알리던 상태 -- 눈으로는 무슨 뜻인지 알 수
                    // 없었다. 모양과 문장으로 말한다.
                    Row(
                      children: [
                        Icon(readyIcon, size: 30, color: readyColor),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            readyText,
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w600,
                              color: readyColor,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // 화면 전체가 눌리면 조작으로 들어가는데, 그걸 알 방법이
                    // 없었다 -- 여백이 아니라 **발견 가능성**이 문제였다.
                    // 연결이 없으면 눌러도 들어가지 않으므로 권하지 않는다.
                    if (widget.connected) ...[
                      const SizedBox(height: 28),
                      Semantics(
                        button: true,
                        onTap: widget.onTap,
                        child: const Row(
                          children: [
                            Icon(Icons.touch_app_outlined,
                                size: 30, color: KioskColors.primary),
                            SizedBox(width: 12),
                            Flexible(
                              child: Text(
                                '화면을 눌러 시작하세요',
                                style: TextStyle(
                                  fontSize: 28,
                                  color: KioskColors.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
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
                    fontSize: 16,
                    color: KioskColors.warning,
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
