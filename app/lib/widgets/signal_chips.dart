import 'package:flutter/material.dart';

import '../models/suggestion.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_tokens.dart';

/// '왜 지금' 신호 칩(2026-10-26) — 본체가 준 신호를 앞에서 4개까지만. 화면에서 신호를 만들지 않는다.
/// 줄이 넘치면 다음 줄로 감싸고, 한 칩 글이 길면 말줄임. 맞지 않는 신호(ok=false)는 흐린 테두리.
class SuggestionSignalChips extends StatelessWidget {
  const SuggestionSignalChips({super.key, required this.signals});

  static const maxShown = 4;
  final List<SuggestionSignal> signals;

  @override
  Widget build(BuildContext context) {
    final shown = signals.take(maxShown).toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    return Semantics(
      label: '이렇게 보고 물어봐요: ${shown.map((s) => s.label).join(', ')}',
      excludeSemantics: true,
      child: Wrap(
        key: const Key('suggestion-signals'),
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        children: [
          for (var i = 0; i < shown.length; i++)
            Container(
              key: Key('suggestion-signal-chip-$i'),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.xs),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: shown[i].ok ? context.appPrimary : context.appBorderSubtle),
              ),
              child: Text(
                shown[i].label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: shown[i].ok ? AppText.caption : context.appCaption,
              ),
            ),
        ],
      ),
    );
  }
}
