import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/suggestion.dart';
import '../providers/ble_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/suggestion_provider.dart';
import '../services/demo_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class SuggestionScreen extends ConsumerWidget {
  const SuggestionScreen({required this.sequenceId, super.key});

  final String sequenceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items      = ref.watch(suggestionProvider);
    final suggestion = items.where((s) => s.sequenceId == sequenceId).firstOrNull;

    if (suggestion == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('제안 확인')),
        body: const Center(child: Text('제안을 찾을 수 없습니다.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('제안 확인')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        children: [
          // ── 헤더 아이콘 ─────────────────────────────────────────────────
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.auto_awesome,
                color: AppColors.primary,
                size: 36,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── 제목 ────────────────────────────────────────────────────────
          Text(
            suggestion.label,
            textAlign: TextAlign.center,
            style: AppText.heading,
          ),
          const SizedBox(height: 6),
          const Text(
            '아래 순서대로 버튼을 누를까요?',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onSurfaceMuted),
          ),

          const SizedBox(height: 32),

          // ── 단계 타임라인 ────────────────────────────────────────────────
          ...List.generate(suggestion.steps.length, (i) {
            final code   = suggestion.steps[i];
            final isLast = i == suggestion.steps.length - 1;
            return _StepRow(
              index: i,
              code: code,
              isLast: isLast,
            );
          }),

          const SizedBox(height: 32),

          // ── 거부 / 승인 버튼 ─────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    await ref
                        .read(suggestionProvider.notifier)
                        .respond(suggestion, false);
                    if (context.mounted) context.pop();
                  },
                  child: const Text('거부'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () async {
                    await ref
                        .read(suggestionProvider.notifier)
                        .respond(suggestion, true);
                    ref
                        .read(executionStatusProvider.notifier)
                        .begin(suggestion);
                    if (kDebugMode) {
                      DemoService(ref.read(bleServiceProvider))
                          .runExecutionFlow();
                    }
                    if (context.mounted) context.go('/status');
                  },
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('승인하고 실행'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 단계 타임라인 행 ──────────────────────────────────────────────────────

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.code,
    required this.isLast,
  });
  final int index;
  final String code;
  final bool isLast;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 인덱스 + 연결선 ──────────────────────────────────────────────
          Column(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: AppColors.primary.withValues(alpha: 0.18),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              if (!isLast)
                Container(
                  width: 2,
                  height: 48,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  color: AppColors.borderSubtle,
                ),
            ],
          ),
          const SizedBox(width: 14),

          // ── 단계 카드 ─────────────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Icon(
                        _stepIcon(code),
                        color: AppColors.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(readableStep(code), style: AppText.body),
                            Text(code, style: AppText.caption),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );

  IconData _stepIcon(String code) {
    if (code.contains('시작'))  return Icons.play_circle_outline;
    if (code.contains('취소') || code.contains('정지')) return Icons.cancel_outlined;
    if (code.contains('해동'))  return Icons.ac_unit;
    if (code.contains('시간'))  return Icons.timer_outlined;
    if (code.contains('우유'))  return Icons.local_drink_outlined;
    return Icons.touch_app;
  }
}
