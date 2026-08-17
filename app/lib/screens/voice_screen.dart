import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/appliance_provider.dart';
import '../providers/ble_provider.dart';
import '../providers/rpi_api_provider.dart';
import '../providers/voice_provider.dart';
import '../services/voice_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen> {
  // dispose()는 위젯이 이미 unmount되는 중이라 그 시점의 ref.read()는
  // "Cannot use ref after the widget was disposed"로 죽는다 — initState에서
  // (ref가 아직 유효할 때) 미리 읽어 필드에 캐시해두고 dispose에서는 이
  // 필드만 쓴다.
  late final VoiceService _voiceService;

  @override
  void initState() {
    super.initState();
    _voiceService = ref.read(voiceServiceProvider);
  }

  Future<void> _toggle() async {
    final voice = _voiceService;
    if (voice.isListening) {
      await voice.stop();
      ref.read(voiceListeningProvider.notifier).state = false;
      return;
    }
    final available = await voice.initialize();
    if (!available || !mounted) {
      _notice('음성 인식을 사용할 수 없습니다. 권한을 확인하세요.');
      return;
    }
    ref.read(voiceTextProvider.notifier).state = '';
    ref.read(voiceListeningProvider.notifier).state = true;
    await voice.listen(
      onText: (text) => ref.read(voiceTextProvider.notifier).state = text,
      onSilence: (text) async {
        ref.read(voiceListeningProvider.notifier).state = false;
        await _send(text);
      },
    );
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final rpiApi = ref.read(rpiApiServiceProvider);
    final appliance = ref.read(selectedApplianceProvider);

    try {
      if (appliance.isCustom) {
        // 사용자 정의 가전은 서버 고정 규칙이 없어서 LLM으로 해석해야 하고,
        // BLE 릴레이(ESP32)는 의도 해석을 못 하므로 RPi5 HTTP 직통만 지원한다
        // (버튼 직접 실행 — manual_control_screen과 같은 제약).
        if (rpiApi == null) {
          _notice('사용자 정의 가전의 음성 명령은 RPi5 서버 연결이 필요해요. 설정에서 URL을 확인하세요.');
          return;
        }
        await rpiApi.executeForAppliance(
          trimmed,
          appliance.buttons.map((b) => b.label).toList(),
        );
        if (mounted) _notice('RPi에 명령을 전송했습니다.');
      } else if (rpiApi != null) {
        // RPi HTTP 직통
        await rpiApi.execute(trimmed, source: 'voice');
        if (mounted) _notice('RPi에 명령을 전송했습니다.');
      } else {
        // BLE 폴백
        await ref.read(bleServiceProvider).sendCommand(trimmed, source: 'voice');
        if (mounted) _notice('명령을 전송했습니다.');
      }
    } catch (error) {
      if (mounted) _notice(error.toString());
    }
  }

  void _notice(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  void dispose() {
    _voiceService.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text      = ref.watch(voiceTextProvider);
    final listening = ref.watch(voiceListeningProvider);
    final appliance = ref.watch(selectedApplianceProvider);
    // 내장 가전(전자레인지)만 실제로 매칭되는 규칙이 있어서 그 예시를 쓰고,
    // 사용자 정의 가전은 등록된 실제 버튼 라벨로 예시를 만든다 — 안 그러면
    // "우유 데워줘" 힌트가 우유 버튼도 없는 가전에서도 그대로 보이게 된다.
    final hintExample = appliance.isCustom && appliance.buttons.isNotEmpty
        ? '예: ${appliance.buttons.first.label} 해줘'
        : '예: 우유 데워줘';

    return Scaffold(
      appBar: AppBar(title: const Text('음성 명령')),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          children: [
            const Spacer(),

            // ── 웨이브 비주얼라이저 ────────────────────────────────────────
            _WaveVisualizer(active: listening),
            const SizedBox(height: 32),

            // ── 마이크 버튼 ────────────────────────────────────────────────
            _MicButton(listening: listening, onTap: _toggle),
            const SizedBox(height: 28),

            // ── 상태 텍스트 ────────────────────────────────────────────────
            Text(
              listening ? '듣고 있어요…' : '마이크를 눌러 말해보세요',
              style: AppText.title,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),

            // ── 인식된 텍스트 라이브 표시 ──────────────────────────────────
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: text.isEmpty
                  ? Text(
                      hintExample,
                      key: const ValueKey('hint'),
                      style: const TextStyle(color: AppColors.onSurfaceMuted),
                      textAlign: TextAlign.center,
                    )
                  : Container(
                      key: const ValueKey('live'),
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        text,
                        style: AppText.title.copyWith(color: AppColors.primary),
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            const Text(
              '5초 동안 말이 없으면 자동으로 전송됩니다.',
              style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 12),
              textAlign: TextAlign.center,
            ),

            const Spacer(),

            // ── 지금 전송 버튼 ─────────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: text.trim().isEmpty ? null : () => _send(text),
                child: const Text('지금 전송'),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ── 마이크 버튼 ───────────────────────────────────────────────────────────

class _MicButton extends StatelessWidget {
  const _MicButton({required this.listening, required this.onTap});
  final bool listening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          width: listening ? 100 : 84,
          height: listening ? 100 : 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: listening
                ? AppColors.primary
                : AppColors.primary.withValues(alpha: 0.15),
            boxShadow: listening
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.35),
                      blurRadius: 32,
                      spreadRadius: 4,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            listening ? Icons.stop_rounded : Icons.mic_rounded,
            size: listening ? 44 : 38,
            color: listening ? Colors.black : AppColors.primary,
          ),
        ),
      );
}

// ── 웨이브 비주얼라이저 (5개 바) ─────────────────────────────────────────

class _WaveVisualizer extends StatelessWidget {
  const _WaveVisualizer({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 56,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(5, (i) => _WaveBar(
            index: i,
            active: active,
          )),
        ),
      );
}

class _WaveBar extends StatefulWidget {
  const _WaveBar({required this.index, required this.active});
  final int index;
  final bool active;

  @override
  State<_WaveBar> createState() => _WaveBarState();
}

class _WaveBarState extends State<_WaveBar> with SingleTickerProviderStateMixin {
  // 바마다 높이 범위가 달라야 자연스러운 파형처럼 보임
  static const _minHeights = [10.0, 18.0, 28.0, 18.0, 10.0];
  static const _maxHeights = [24.0, 38.0, 56.0, 38.0, 24.0];
  static const _delays = [0, 100, 50, 150, 80];

  late final AnimationController _ctrl;
  late final Animation<double> _height;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 400 + widget.index * 60),
    );
    _height = Tween(
      begin: _minHeights[widget.index],
      end: _maxHeights[widget.index],
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));

    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(_WaveBar old) {
    super.didUpdateWidget(old);
    if (widget.active && !_started) {
      _start();
    } else if (!widget.active && _started) {
      _stop();
    }
  }

  Future<void> _start() async {
    _started = true;
    await Future.delayed(Duration(milliseconds: _delays[widget.index]));
    if (mounted) _ctrl.repeat(reverse: true);
  }

  void _stop() {
    _started = false;
    _ctrl.animateTo(0, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Container(
            width: 7,
            height: _height.value,
            decoration: BoxDecoration(
              color: widget.active
                  ? AppColors.primary
                  : AppColors.primary.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      );
}
