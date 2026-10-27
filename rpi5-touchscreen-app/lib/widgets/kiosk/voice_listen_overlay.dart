import 'package:flutter/material.dart';

import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'kiosk_modal.dart';
import 'kiosk_text.dart';

/// 본체에서 말하는 동안 뒤 화면을 막고 듣기·생각·실패 상태를 보이는 창.
class KioskVoiceListenOverlay extends StatelessWidget {
  const KioskVoiceListenOverlay({
    super.key,
    required this.remaining,
    required this.failed,
    required this.onCancel,
    required this.onRetry,
  });

  final int remaining;
  final bool failed;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final listening = !failed && remaining > 0;
    final title = failed
        ? '잘 못 들었어요'
        : listening
            ? '듣고 있어요'
            : '생각하고 있어요';
    return KioskModalSemantics(
      label: title,
      child: Stack(fit: StackFit.expand, children: [
        ColoredBox(color: KioskColors.scrim),
        Center(
          child: Material(
            key: const ValueKey('kiosk-voice-modal'),
            color: KioskColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(KioskSizes.buttonRadius),
              side: BorderSide(color: KioskColors.border),
            ),
            child: SizedBox(
              width: 430,
              child: Padding(
                padding: const EdgeInsets.all(KioskSpace.lg),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  if (!failed) ...[
                    _ListeningMark(listening: listening),
                    const SizedBox(height: KioskSpace.sm),
                  ],
                  KioskText(title,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: KioskType.key,
                          fontWeight: FontWeight.w700,
                          color: KioskColors.ink)),
                  const SizedBox(height: KioskSpace.sm),
                  if (listening)
                    KioskText('$remaining초',
                        key: const ValueKey('kiosk-voice-countdown'),
                        style: TextStyle(
                            fontSize: KioskType.status,
                            color: KioskColors.muted))
                  else if (!failed)
                    CircularProgressIndicator(color: KioskColors.primary)
                  else
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(
                          key: const ValueKey('kiosk-voice-close'),
                          onPressed: onCancel,
                          style: KioskButtons.secondary(
                              foreground: KioskColors.ink,
                              border: KioskColors.border),
                          child: const KioskText('닫기',
                              style: TextStyle(
                                  fontSize: KioskType.body,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(width: KioskSpace.sm),
                      Expanded(
                        child: ElevatedButton(
                          key: const ValueKey('kiosk-voice-retry'),
                          onPressed: onRetry,
                          style: KioskButtons.primary(
                              background: KioskColors.primary,
                              foreground: KioskColors.onAccent),
                          child: const KioskText('다시 말하기',
                              style: TextStyle(
                                  fontSize: KioskType.body,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ]),
                  if (!failed) ...[
                    const SizedBox(height: KioskSpace.md),
                    OutlinedButton(
                      key: const ValueKey('kiosk-voice-cancel'),
                      onPressed: onCancel,
                      style: KioskButtons.secondary(
                          foreground: KioskColors.ink,
                          border: KioskColors.border),
                      child: const KioskText('취소',
                          style: TextStyle(
                              fontSize: KioskType.body,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ListeningMark extends StatelessWidget {
  const _ListeningMark({required this.listening});

  final bool listening;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        key: const ValueKey('kiosk-voice-pulse'),
        tween: Tween(begin: 0.82, end: 1),
        duration: listening ? const Duration(milliseconds: 900) : Duration.zero,
        builder: (context, value, child) => Transform.scale(
          scale: value,
          child: Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: KioskColors.primary.withValues(alpha: 0.6), width: 4),
              color: KioskColors.mint,
            ),
            child: Icon(Icons.mic, size: 48, color: KioskColors.primary),
          ),
        ),
      );
}
