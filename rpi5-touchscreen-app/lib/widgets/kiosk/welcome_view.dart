import 'package:flutter/material.dart';

import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'pairing_view.dart';

const kWelcomeTitle = 'SimpleLay에 오신 것을 환영합니다';
const kWelcomeGuide = '휴대폰으로 QR을 찍어 연결해 주세요';
const kWelcomeConnected = '휴대폰이 연결되었습니다';

// 화면에 쓸 때의 줄바꿈 — 그냥 두면 한글이 낱말 가운데서 끊긴다('연/결해').
const kWelcomeTitleLines = 'SimpleLay에\n오신 것을 환영합니다';
const kWelcomeGuideLines = '휴대폰으로 QR을 찍어\n연결해 주세요';

/// 음성용 — 한국어 음성 합성이 영문 제품 이름을 철자로 읽지 않게 한글로 쓴다.
const kWelcomeSpeech = '심플레이에 오신 것을 환영합니다. $kWelcomeGuide.';
const kWelcomeConnectedSpeech = '$kWelcomeConnected.';

/// 처음 켠 본체의 전체 화면 환영. 언제 뜨고 닫힐지는 [KioskWelcomeGate]와 띄운 쪽이 정하고, 이 화면은 그리기만 한다.
/// 등장 애니메이션은 한 번 돌고 멈춘다. 흐림·셰이더는 쓰지 않는다(보드 성능).
class KioskWelcomeView extends StatefulWidget {
  const KioskWelcomeView({
    super.key,
    required this.api,
    required this.connected,
    required this.onConnected,
    required this.onSkip,
  });

  final KioskApiService api;
  final bool connected;
  final VoidCallback onConnected;
  final VoidCallback onSkip;

  @override
  State<KioskWelcomeView> createState() => _KioskWelcomeViewState();
}

class _KioskWelcomeViewState extends State<KioskWelcomeView> with SingleTickerProviderStateMixin {
  late final AnimationController _entrance =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _entrance.value = 1;
    } else {
      _entrance.forward();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  Widget _rise(double begin, double end, Widget child, {Curve curve = Curves.easeOutCubic}) {
    final t = CurvedAnimation(parent: _entrance, curve: Interval(begin, end, curve: curve));
    return FadeTransition(
      opacity: t,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(t),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(key: const ValueKey('welcome-view'), fit: StackFit.expand, children: [
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [KioskColors.bg, KioskColors.mint],
          ),
        ),
      ),
      _circle(top: -110, left: -80, size: 300, alpha: 0.10),
      _circle(bottom: -150, right: -90, size: 380, alpha: 0.08),
      Padding(
        padding: const EdgeInsets.fromLTRB(KioskSpace.xl, KioskSpace.md, KioskSpace.xl, KioskSpace.md),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          child: widget.connected ? const _ConnectedBody(key: ValueKey('welcome-connected')) : _pairingBody(),
        ),
      ),
    ]);
  }

  Widget _circle({double? top, double? left, double? bottom, double? right, required double size, required double alpha}) =>
      Positioned(
        top: top,
        left: left,
        bottom: bottom,
        right: right,
        child: FadeTransition(
          opacity: _entrance,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: KioskColors.primary.withValues(alpha: alpha)),
          ),
        ),
      );

  Widget _pairingBody() => Row(key: const ValueKey('welcome-pairing'), children: [
        Expanded(flex: 11, child: _intro()),
        const SizedBox(width: KioskSpace.lg),
        Expanded(
          flex: 10,
          child: ScaleTransition(
            scale: Tween(begin: 0.85, end: 1.0).animate(
                CurvedAnimation(parent: _entrance, curve: const Interval(0.45, 1, curve: Curves.easeOutBack))),
            child: FadeTransition(
              opacity: CurvedAnimation(parent: _entrance, curve: const Interval(0.45, 0.8)),
              child: Container(
                padding: const EdgeInsets.all(KioskSpace.md),
                decoration: BoxDecoration(
                  color: KioskColors.surface,
                  borderRadius: BorderRadius.circular(KioskSizes.buttonRadius),
                  border: Border.all(color: KioskColors.border, width: 2),
                ),
                child: KioskPairingView(
                  api: widget.api,
                  embedded: true,
                  onClose: widget.onSkip,
                  onConnected: widget.onConnected,
                ),
              ),
            ),
          ),
        ),
      ]);

  Widget _intro() => LayoutBuilder(
        builder: (context, box) => Align(
          alignment: Alignment.centerLeft,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                _rise(
                    0,
                    0.4,
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(color: KioskColors.primary, shape: BoxShape.circle),
                      child: Icon(Icons.home_rounded, size: 44, color: KioskColors.onAccent),
                    ),
                    curve: Curves.easeOutBack),
                const SizedBox(height: KioskSpace.md),
                _rise(
                    0.15,
                    0.55,
                    Text(kWelcomeTitleLines,
                        semanticsLabel: kWelcomeTitle,
                        style: TextStyle(
                            fontSize: KioskType.key, height: 1.25, fontWeight: FontWeight.w800, color: KioskColors.ink))),
                const SizedBox(height: KioskSpace.sm),
                _rise(
                    0.3,
                    0.7,
                    Text(kWelcomeGuideLines,
                        semanticsLabel: kWelcomeGuide,
                        style: TextStyle(
                            fontSize: KioskType.status, height: 1.3, fontWeight: FontWeight.w500, color: KioskColors.ink))),
                const SizedBox(height: KioskSpace.md),
                _rise(
                    0.5,
                    0.85,
                    OutlinedButton(
                      key: const ValueKey('welcome-skip'),
                      onPressed: widget.onSkip,
                      style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.border),
                      child: const Text('건너뛰기', style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700)),
                    )),
              ]),
            ),
          ),
        ),
      );
}

class _ConnectedBody extends StatelessWidget {
  const _ConnectedBody({super.key});

  @override
  Widget build(BuildContext context) {
    final color = KioskColors.primary;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 900),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) => CustomPaint(size: const Size.square(150), painter: _CheckPainter(t, color)),
        ),
        const SizedBox(height: KioskSpace.lg),
        Semantics(
          liveRegion: true,
          child: Text(kWelcomeConnected,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: KioskType.key, fontWeight: FontWeight.w800, color: KioskColors.ink)),
        ),
      ]),
    );
  }
}

/// 원을 먼저 그리고 그 안에 체크를 긋는다.
class _CheckPainter extends CustomPainter {
  const _CheckPainter(this.t, this.color);

  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    final ring = (t / 0.6).clamp(0.0, 1.0);
    canvas.drawArc((Offset.zero & size).deflate(6), -1.57, 6.283 * ring, false, paint);
    final tick = ((t - 0.5) / 0.5).clamp(0.0, 1.0);
    if (tick == 0) return;
    final path = Path()
      ..moveTo(size.width * 0.28, size.height * 0.52)
      ..lineTo(size.width * 0.44, size.height * 0.68)
      ..lineTo(size.width * 0.73, size.height * 0.36);
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * tick), paint);
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.t != t || old.color != color;
}
