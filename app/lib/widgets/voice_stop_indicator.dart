import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/voice_stop_provider.dart';
import '../theme/app_colors.dart';

/// 실행 중 음성 '멈춰'를 듣고 있을 때만 보이는 한 줄 — "듣는 중".
///
/// 마이크가 켜져 있다는 사실을 숨기지 않는다. 듣지 않을 때(대기·권한 거부·
/// 오류)는 아무것도 그리지 않는다 — 정지 버튼은 이 줄과 상관없이 그대로다.
class VoiceStopIndicator extends ConsumerWidget {
  const VoiceStopIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listening = ref.watch(voiceStopProvider.select((s) => s.listening));
    if (!listening) return const SizedBox.shrink();
    return Semantics(
      liveRegion: true,
      label: "듣는 중. '멈춰'라고 말하면 정지를 요청해요",
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          color: context.appPrimary.withValues(alpha: 0.10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.mic, size: 18, color: context.appPrimary),
              const SizedBox(width: 8),
              const Text('듣는 중',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  "'멈춰'라고 말하면 멈춰요",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
