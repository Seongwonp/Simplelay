import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ble_provider.dart';
import '../providers/voice_provider.dart';

class VoiceScreen extends ConsumerStatefulWidget {
  const VoiceScreen({super.key});

  @override
  ConsumerState<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends ConsumerState<VoiceScreen> {
  Future<void> _toggle() async {
    final voice = ref.read(voiceServiceProvider);
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
    if (text.trim().isEmpty) return;
    try {
      await ref
          .read(bleServiceProvider)
          .sendCommand(text.trim(), source: 'voice');
      if (mounted) _notice('명령을 전송했습니다.');
    } catch (error) {
      if (mounted) _notice(error.toString());
    }
  }

  void _notice(String message) => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));

  @override
  void dispose() {
    ref.read(voiceServiceProvider).cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = ref.watch(voiceTextProvider);
    final listening = ref.watch(voiceListeningProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('음성 명령')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: listening ? 160 : 130,
              height: listening ? 160 : 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: listening
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white12,
                boxShadow: listening
                    ? [
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: .3),
                          blurRadius: 35,
                        ),
                      ]
                    : null,
              ),
              child: IconButton(
                onPressed: _toggle,
                icon: Icon(
                  listening ? Icons.stop_rounded : Icons.mic_rounded,
                  size: 56,
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              listening ? '듣고 있어요…' : '마이크를 눌러 말해보세요',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              text.isEmpty ? '예: 우유 데워줘' : text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              '5초 동안 말이 없으면 자동으로 전송됩니다.',
              style: TextStyle(color: Colors.white54),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: text.trim().isEmpty ? null : () => _send(text),
                child: const Text('지금 전송'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
