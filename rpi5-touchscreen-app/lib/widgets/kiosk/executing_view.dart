import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_target_line.dart';

/// 실행 화면 — 센서 대시보드가 아니라 **지금 무슨 버튼을 어떻게 하고 있는가**.
///
/// 읽는 순서: 어느 가전 → 지금 누르는 버튼(가장 크게) → 지금 상태(누르는 중 /
/// 눌림 확인 중 / 보정 후 다시 시도 중) → 총 N단계 중 K단계. 전류·소리 같은
/// 원시 근거는 작은 한 줄로 내린다. 긴급 정지는 오른쪽에 떨어뜨려 두고, 색을
/// 빼도 알아보게 정지 기호·글자·두꺼운 외곽선을 같이 준다.
///
/// 서버는 '이동 중'과 '누르는 중'을 나눠 주지 않는다. 그래서 화면도 나누지
/// 않는다 -- 축이 멈춰 있는데 '이동 중'이라고 쓰게 된다. 폰과 같은 규칙이다.
class KioskExecutingView extends StatelessWidget {
  const KioskExecutingView({
    super.key,
    required this.title,
    this.target,
    required this.lastButtons,
    required this.currentButton,
    required this.currentAttempt,
    required this.completedSteps,
    this.totalSteps,
    required this.verificationConfidence,
    required this.verificationDetail,
    required this.onStop,
  });

  final String title;

  /// 이 실행이 **대상으로 삼은** 가전(서버가 말해준 job의 대상). 모르면 null.
  final ApplianceMap? target;
  final List<KioskButtonResult>? lastButtons;
  final String? currentButton;
  final int? currentAttempt;
  final int? completedSteps;

  /// 서버가 준 전체 단계 수. 없으면 진행을 비율로 지어내지 않는다.
  final int? totalSteps;
  final double? verificationConfidence;
  final String? verificationDetail;
  final VoidCallback onStop;

  bool get _retrying => (currentAttempt ?? 1) > 1;

  bool get _hasVerification =>
      verificationConfidence != null ||
      (verificationDetail != null && verificationDetail!.isNotEmpty);

  /// 지금 상태 구절과 그 모양. 폰 실행 화면과 같은 단어를 쓴다.
  (String, IconData?, Color) _phrase() {
    if (currentButton == null) {
      return ('준비 중', null, KioskColors.muted);
    }
    if (_retrying) {
      return ('보정 후 다시 시도 중', Icons.autorenew, KioskColors.warning);
    }
    return _hasVerification
        ? ('눌림 확인 중', null, Colors.white)
        : ('누르는 중', null, Colors.white);
  }

  /// 눌림을 무엇으로 확인했는지. 수치를 지우지 않고 **근거로 내려둔다**.
  String? _evidence() {
    final parts = <String>[
      if (verificationDetail != null && verificationDetail!.isNotEmpty)
        verificationDetail!,
      if (verificationConfidence != null)
        '센서 ${(verificationConfidence! * 100).toStringAsFixed(0)}%',
      if (_retrying) '$currentAttempt번째 시도',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final isDone = lastButtons != null;
    final target = this.target;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 왼쪽: 지금 무엇을 ────────────────────────────────────────
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(36, 24, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (target != null) ...[
                  KioskTargetLine(appliance: target),
                  const SizedBox(height: 6),
                ],
                // 목적(무엇을 하려고)은 보조로. 버튼 하나를 누르는 실행이면
                // 제목과 버튼이 같으니 되풀이하지 않는다.
                if (title.isNotEmpty && title != currentButton)
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: KioskColors.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 14),
                if (!isDone)
                  Expanded(child: _NowBlock(view: this))
                else
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

        // ── 오른쪽: 긴급 정지만, 떨어뜨려서 ────────────────────────────
        // 다른 행동과 붙어 있으면 급한 순간에 옆 것을 누른다. 이 칸에는 정지
        // 하나만 둔다.
        SizedBox(
          width: 240,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 24, 24, 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 104,
                  child: ElevatedButton.icon(
                    onPressed: onStop,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KioskColors.danger,
                      foregroundColor: KioskColors.onAccent,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        // 색을 빼도 다른 버튼과 구분되게 -- 두꺼운 외곽선.
                        side: const BorderSide(color: Colors.white, width: 3),
                      ),
                    ),
                    icon: const Icon(Icons.stop, size: 36),
                    label: const Text(
                      '긴급 정지',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── 지금 누르는 버튼 · 상태 · 단계 ──────────────────────────────────────────

class _NowBlock extends StatelessWidget {
  const _NowBlock({required this.view});

  final KioskExecutingView view;

  @override
  Widget build(BuildContext context) {
    final (phrase, icon, color) = view._phrase();
    final evidence = view._evidence();
    final total = view.totalSteps;
    final done = view.completedSteps ?? 0;

    return Semantics(
      liveRegion: true,
      label: [
        if (view.currentButton != null) '${view.currentButton} 버튼',
        phrase,
        if (evidence != null) evidence,
        if (total != null && total > 0) '총 $total단계 중 $done단계',
      ].join('. '),
      child: ExcludeSemantics(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (view.currentButton != null)
                Text(
                  "'${view.currentButton}'",
                  style: const TextStyle(
                    fontSize: 52,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1.1,
                  ),
                ),
              const SizedBox(height: 4),
              // 상태를 색으로만 말하지 않는다 -- 재시도에는 모양이 같이 간다.
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 34, color: color),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(
                      phrase,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
              if (view._retrying) ...[
                const SizedBox(height: 4),
                // '재시도'는 실패로 읽힌다. 눌림이 확인되지 않아 자리를 다시
                // 맞추고 누르는 것은 이 제품이 하기로 한 일이다.
                const Text(
                  '눌림이 확인되지 않아 자리를 맞추고 다시 눌러요',
                  style: TextStyle(fontSize: 18, color: KioskColors.warning),
                ),
              ],
              if (evidence != null) ...[
                const SizedBox(height: 6),
                Text(
                  evidence,
                  style: const TextStyle(fontSize: 18, color: KioskColors.muted),
                ),
              ],
              const SizedBox(height: 18),
              if (total != null && total > 0)
                _SegmentedProgress(total: total, completed: done, active: true)
              else if (view.completedSteps != null)
                Text(
                  '$done단계 완료',
                  style: const TextStyle(fontSize: 22, color: KioskColors.muted),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// N칸 중 K칸. 퍼센트나 시간으로 채우는 바가 아니다 -- 남은 시간을 아는
/// 척하지 않는다. 채움/테두리/비움 세 모양이라 색을 빼도 지금 칸이 보인다.
class _SegmentedProgress extends StatelessWidget {
  const _SegmentedProgress({
    required this.total,
    required this.completed,
    required this.active,
  });

  final int total;
  final int completed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '총 $total단계 중 $completed단계',
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        // 단계가 너무 많으면 칸이 얇아진다 -- 12칸까지만 그리고, 그 이상은
        // 글자가 대신 말한다.
        if (total <= 12) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < total; i++) ...[
                Expanded(
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: i < completed
                          ? KioskColors.primary
                          : KioskColors.surface2,
                      borderRadius: BorderRadius.circular(3),
                      border: (i == completed && active)
                          ? Border.all(color: KioskColors.primary, width: 2)
                          : null,
                    ),
                  ),
                ),
                if (i < total - 1) const SizedBox(width: 5),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

// ── 실행 결과 단계 행 ─────────────────────────────────────────────────────

enum _StepState { done, failed }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});

  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon) = switch (state) {
      _StepState.done => (KioskColors.success, Icons.check),
      _StepState.failed => (KioskColors.danger, Icons.close),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 22, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
