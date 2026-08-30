import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../models/execution_status.dart';
import '../theme/app_colors.dart';

/// 실행 상태 화면 상단의 KPI 세 칸 (진행 단계 · 전류 · 음향)
/// 실행 중이거나 완료/실패 상태일 때만 표시된다.
class StatusKpiStrip extends StatelessWidget {
  const StatusKpiStrip({
    super.key,
    required this.status,
  });

  final ExecutionStatus status;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final hasSteps = status.steps.isNotEmpty;
    final mA = status.currentMa;
    final dB = status.soundDb;

    return Row(
      children: [
        if (hasSteps) ...[
          Expanded(
            child: _KpiCard(
              label: '진행',
              value: '${status.completedSteps}',
              suffix: '/ ${status.steps.length}',
              unit: '단계',
              color: primary,
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: _KpiCard(
            label: '전류',
            value: mA == null ? '--' : mA.toStringAsFixed(0),
            unit: 'mA',
            color: mA != null && mA >= 1500 ? AppColors.warning : primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _KpiCard(
            label: '음향',
            value: dB == null ? '--' : dB.toStringAsFixed(0),
            unit: 'dB',
            color: dB != null && dB >= 80 ? AppColors.warning : primary,
          ),
        ),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.label,
    required this.value,
    required this.unit,
    this.suffix,
    required this.color,
  });

  final String label;
  final String value;
  final String unit;
  final String? suffix;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.06,
              color: context.appMuted,
            ),
          ),
          const SizedBox(height: 4),
          // 값이 길어지면(예: "3 / 3 단계") 카드 폭을 넘어설 수 있어서, 잘리는
          // 대신 통째로 줄여서 한 줄에 들어가게 한다.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    height: 1.1,
                  ),
                ),
                if (suffix != null) ...[
                  const SizedBox(width: 5),
                  Text(
                    suffix!,
                    style: TextStyle(
                      fontSize: 14,
                      color: context.appMuted,
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                Text(
                  unit,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.appMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
