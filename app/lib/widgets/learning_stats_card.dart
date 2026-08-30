import 'package:flutter/material.dart';

import '../models/suggestion.dart';
import '../theme/app_colors.dart';

/// 홈 화면 상단의 AI 학습 통계 카드
/// suggestions 목록에서 파생된 지표를 표시한다.
class LearningStatsCard extends StatelessWidget {
  const LearningStatsCard({super.key, required this.suggestions});

  final List<Suggestion> suggestions;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final surface = Theme.of(context).colorScheme.surfaceContainerLow;
    final count = suggestions.length;
    final totalSteps = suggestions.fold(0, (s, e) => s + e.steps.length);
    final avgSteps = count == 0 ? 0.0 : totalSteps / count;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: primary.withValues(alpha: count > 0 ? 0.25 : 0.12),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                count > 0 ? Icons.auto_awesome : Icons.hourglass_top_rounded,
                color: primary,
                size: 16,
              ),
              const SizedBox(width: 7),
              Text(
                count > 0 ? 'AI가 $count개 패턴을 발견했습니다' : 'AI가 패턴을 학습하고 있습니다',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _StatPill(
                label: '제안',
                value: '$count',
                unit: '개',
                color: primary,
              ),
              const SizedBox(width: 10),
              _StatPill(
                label: '평균 단계',
                value: count == 0 ? '--' : avgSteps.toStringAsFixed(1),
                unit: count == 0 ? '' : '단계',
                color: primary,
              ),
              const SizedBox(width: 10),
              _StatPill(
                label: '총 동작',
                value: '$totalSteps',
                unit: '회',
                color: count > 0 ? primary : context.appMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 0.06,
                color: context.appMuted,
              ),
            ),
            const SizedBox(height: 3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    value,
                    key: ValueKey(value),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: color,
                      height: 1.0,
                    ),
                  ),
                ),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 3),
                  Text(
                    unit,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.appMuted,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
