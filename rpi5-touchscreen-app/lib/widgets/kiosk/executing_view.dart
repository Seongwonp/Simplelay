import 'package:flutter/material.dart';

import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';

class KioskExecutingView extends StatelessWidget {
  const KioskExecutingView({
    super.key,
    required this.title,
    required this.lastButtons,
    required this.currentButton,
    required this.currentAttempt,
    required this.completedSteps,
    required this.verificationConfidence,
    required this.verificationDetail,
    required this.onStop,
  });

  final String title;
  final List<KioskButtonResult>? lastButtons;
  final String? currentButton;
  final int? currentAttempt;
  final int? completedSteps;
  final double? verificationConfidence;
  final String? verificationDetail;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final isDone = lastButtons != null;

    return Row(
      children: [
        // ── 왼쪽: 메인 콘텐츠 ──────────────────────────────────────
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 제목 행 + 단계 표시
                Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isDone ? KioskColors.success : KioskColors.primary,
                        backgroundColor: KioskColors.border,
                        value: isDone ? 1.0 : null,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (completedSteps != null || isDone) ...[
                      const SizedBox(width: 12),
                      Text(
                        '${isDone ? lastButtons!.length : completedSteps}단계 완료',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: isDone ? KioskColors.success : KioskColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 32),

                // 실행 중: 현재 버튼 hero / 완료: 결과 목록
                if (!isDone) ...[
                  _CurrentActionHero(
                    button: currentButton,
                    attempt: currentAttempt,
                  ),
                  const Spacer(),
                ] else
                  Expanded(
                    child: ListView(
                      children: lastButtons!
                          .map(
                            (b) => _StepRow(
                              label: b.button,
                              state: b.success
                                  ? _StepState.done
                                  : _StepState.failed,
                            ),
                          )
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // ── 오른쪽: 지표 + 긴급 정지 ─────────────────────────────
        Container(
          width: 210,
          padding: const EdgeInsets.fromLTRB(4, 28, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MetricBlock(
                label: '검증 신뢰도',
                value: verificationConfidence == null
                    ? '–'
                    : '${(verificationConfidence! * 100).toStringAsFixed(0)}%',
                warn: verificationConfidence != null && verificationConfidence! < 0.7,
                detail: verificationDetail,
              ),
              const SizedBox(height: 24),
              _MetricBlock(
                label: '시도 횟수',
                value: currentAttempt == null ? '–' : '$currentAttempt회',
                warn: currentAttempt != null && currentAttempt! > 1,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton(
                  onPressed: onStop,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: KioskColors.danger,
                    side: const BorderSide(color: KioskColors.danger, width: 1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    '긴급 정지',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── 현재 누르는 버튼 (심사석에서 보이는 크기) ──────────────────────────────

class _CurrentActionHero extends StatelessWidget {
  const _CurrentActionHero({required this.button, required this.attempt});

  final String? button;
  final int? attempt;

  @override
  Widget build(BuildContext context) {
    final isRetrying = attempt != null && attempt! > 1;
    final color = isRetrying ? KioskColors.warning : Colors.white;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          button ?? '준비 중…',
          style: TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.w700,
            color: color,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          isRetrying
              ? '$attempt번째 재시도 — 좌표 재보정 중'
              : button != null
                  ? '버튼 누르는 중 · 센서 검증 대기'
                  : '버튼 시퀀스 초기화 중…',
          style: TextStyle(
            fontSize: 14,
            color: isRetrying ? KioskColors.warning : KioskColors.muted,
          ),
        ),
      ],
    );
  }
}

// ── 실행 결과 단계 행 ─────────────────────────────────────────────────────

enum _StepState { done, current, failed, pending }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon) = switch (state) {
      _StepState.done => (KioskColors.success, Icons.check),
      _StepState.current => (KioskColors.primary, Icons.play_arrow),
      _StepState.failed => (KioskColors.danger, Icons.close),
      _StepState.pending => (Colors.white24, Icons.circle_outlined),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color:
                    state == _StepState.pending ? Colors.white30 : Colors.white,
                fontWeight: state == _StepState.current
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 우측 지표 (테두리 없는 라벨+숫자) ──────────────────────────────────────

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({
    required this.label,
    required this.value,
    required this.warn,
    this.detail,
  });

  final String label;
  final String value;
  final bool warn;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final color = warn ? KioskColors.warning : Colors.white;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: KioskColors.muted),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w600,
            color: color,
            height: 1.0,
          ),
        ),
        if (detail != null && detail!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            detail!,
            style: const TextStyle(fontSize: 11, color: KioskColors.muted),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}
