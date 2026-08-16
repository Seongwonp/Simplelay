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
            padding: const EdgeInsets.fromLTRB(32, 22, 12, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 제목 행 + 단계 배지
                Row(
                  children: [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: isDone ? KioskColors.success : KioskColors.primary,
                        backgroundColor: isDone
                            ? KioskColors.success.withValues(alpha: 0.18)
                            : KioskColors.primary.withValues(alpha: 0.18),
                        value: isDone ? 1.0 : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    _StepBadge(
                      completedSteps:
                          isDone ? lastButtons!.length : completedSteps,
                      isDone: isDone,
                    ),
                  ],
                ),
                const SizedBox(height: 20),

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
          width: 220,
          padding: const EdgeInsets.fromLTRB(4, 22, 24, 22),
          child: Column(
            children: [
              _BigConfidenceCard(
                confidence: verificationConfidence,
                detail: verificationDetail,
              ),
              const SizedBox(height: 10),
              _AttemptCard(attempt: currentAttempt),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 72,
                child: ElevatedButton.icon(
                  onPressed: onStop,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KioskColors.danger.withValues(alpha: 0.10),
                    foregroundColor: KioskColors.danger,
                    elevation: 0,
                    side: const BorderSide(color: KioskColors.danger, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.stop_circle_outlined, size: 22),
                  label: const Text(
                    '긴급 정지',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
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

// ── 단계 배지 ────────────────────────────────────────────────────────────

class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.completedSteps, required this.isDone});

  final int? completedSteps;
  final bool isDone;

  @override
  Widget build(BuildContext context) {
    if (completedSteps == null && !isDone) return const SizedBox.shrink();
    final color = isDone ? KioskColors.success : KioskColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.40)),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        '${completedSteps}단계 완료',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
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
    final color = isRetrying ? KioskColors.warning : KioskColors.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            button ?? '준비 중…',
            style: TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isRetrying
                ? '$attempt번째 재시도 — 폐루프 좌표 재보정 중'
                : button != null
                    ? '버튼 누르는 중 · 센서 검증 대기'
                    : '버튼 시퀀스 초기화 중…',
            style: TextStyle(
              fontSize: 13,
              color: isRetrying
                  ? KioskColors.warning.withValues(alpha: 0.75)
                  : KioskColors.muted,
            ),
          ),
        ],
      ),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
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

// ── 검증 신뢰도 카드 (52px 숫자) ─────────────────────────────────────────

class _BigConfidenceCard extends StatelessWidget {
  const _BigConfidenceCard({required this.confidence, required this.detail});

  final double? confidence;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final pct = (confidence ?? 0.0).clamp(0.0, 1.0);
    final low = confidence != null && confidence! < 0.7;
    final barColor = low ? KioskColors.warning : KioskColors.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        border: Border.all(
          color: confidence == null
              ? KioskColors.border
              : barColor.withValues(alpha: 0.40),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '검증 신뢰도',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.06,
                  color: KioskColors.muted,
                ),
              ),
              Icon(
                Icons.verified_outlined,
                size: 15,
                color: confidence == null ? KioskColors.muted : barColor,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                confidence == null ? '–' : (pct * 100).toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w300,
                  color: confidence == null ? Colors.white38 : Colors.white,
                  height: 1.0,
                ),
              ),
              if (confidence != null) ...[
                const SizedBox(width: 3),
                Text(
                  '%',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w300,
                    color: barColor.withValues(alpha: 0.80),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: KioskColors.border,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              style: const TextStyle(fontSize: 10, color: KioskColors.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// ── 재시도 횟수 카드 ─────────────────────────────────────────────────────

class _AttemptCard extends StatelessWidget {
  const _AttemptCard({required this.attempt});

  final int? attempt;

  @override
  Widget build(BuildContext context) {
    final warn = attempt != null && attempt! > 1;
    final color = warn ? KioskColors.warning : KioskColors.muted;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        border: Border.all(
          color: warn
              ? KioskColors.warning.withValues(alpha: 0.40)
              : KioskColors.border,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '시도 횟수',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.06,
                  color: KioskColors.muted,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                attempt == null ? '–' : '$attempt회',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: warn ? KioskColors.warning : Colors.white,
                  height: 1.0,
                ),
              ),
            ],
          ),
          Icon(Icons.replay_circle_filled_outlined, size: 26, color: color),
        ],
      ),
    );
  }
}
