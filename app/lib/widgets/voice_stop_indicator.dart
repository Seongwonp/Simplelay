import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/voice_stop_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_tokens.dart';

/// 실행 중 음성 '멈춰'를 듣고 있을 때만 보이는 한 줄 — "듣는 중".
///
/// 마이크가 켜져 있다는 사실을 숨기지 않는다. 듣지 않을 때(대기·권한 거부·
/// 오류)는 아무것도 그리지 않는다 — 정지 버튼은 이 줄과 상관없이 그대로다.
///
/// 폰이 추적하지 않는 실행을 '멈춰'로 멈췄으면 그 결과 한 줄([voiceStopNoticeProvider])도 [noticeDuration] 동안
/// 여기 보이고 지운다(검토 10/19).
class VoiceStopIndicator extends ConsumerStatefulWidget {
  const VoiceStopIndicator({super.key});

  /// 음성 정지 결과 한 줄을 보여 두는 시간.
  static const noticeDuration = Duration(seconds: 8);

  @override
  ConsumerState<VoiceStopIndicator> createState() => _VoiceStopIndicatorState();
}

class _VoiceStopIndicatorState extends ConsumerState<VoiceStopIndicator> {
  Timer? _clear;

  @override
  void initState() {
    super.initState();
    final shown = ref.read(voiceStopNoticeProvider);
    if (shown != null) _clearLater(shown);
  }

  void _clearLater(String shown) {
    _clear?.cancel();
    _clear = Timer(VoiceStopIndicator.noticeDuration, () {
      _clear = null;
      if (mounted && ref.read(voiceStopNoticeProvider) == shown) {
        ref.read(voiceStopNoticeProvider.notifier).state = null;
      }
    });
  }

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(voiceStopNoticeProvider, (_, next) {
      if (next != null) _clearLater(next);
    });
    final listening = ref.watch(voiceStopProvider.select((s) => s.listening));
    final notice = ref.watch(voiceStopNoticeProvider);
    if (!listening && notice == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (notice != null)
          Semantics(
            liveRegion: true,
            label: notice,
            child: ExcludeSemantics(
              child: Container(
                key: const Key('voice-stop-notice'),
                width: double.infinity,
                color: context.appPrimary.withValues(alpha: 0.10),
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm),
                child: Row(
                  children: [
                    Icon(Icons.stop_circle_outlined, size: 18, color: context.appPrimary),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(child: Text(notice, style: const TextStyle(fontSize: AppFont.caption))),
                  ],
                ),
              ),
            ),
          ),
        if (listening)
          Semantics(
            liveRegion: true,
            label: "듣는 중. '멈춰'라고 말하면 정지를 요청해요",
            child: ExcludeSemantics(
              child: Container(
                width: double.infinity,
                color: context.appPrimary.withValues(alpha: 0.10),
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm),
                child: Row(
                  children: [
                    Icon(Icons.mic, size: 18, color: context.appPrimary),
                    const SizedBox(width: AppSpace.sm),
                    const Text('듣는 중',
                        style: TextStyle(fontSize: AppFont.caption, fontWeight: FontWeight.w700)),
                    const SizedBox(width: AppSpace.sm),
                    const Expanded(
                      child: Text(
                        "'멈춰'라고 말하면 정지를 보내요",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: AppFont.caption),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
