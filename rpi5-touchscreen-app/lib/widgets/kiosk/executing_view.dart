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
    this.executionMode = 'unknown',
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

  final String executionMode;

  /// 연습(mock)일 때만 "연습 모드". 실제·모름은 머리 표시를 달지 않는다(2026-10-14 문구 정리).
  String? get modeLabel => executionMode == 'mock' ? '연습 모드' : null;

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

  /// 지금 누르는 버튼이 대상 가전 버튼판의 어디인가.
  ///
  /// 서버는 버튼 **이름**만 준다. 대상 가전에서 그 이름이 정확히 한 번 나올
  /// 때만 자리를 가리킨다 -- 없거나 둘 이상이면 틀린 자리를 가리킬 수 있어
  /// 그림을 그리지 않는다.
  ApplianceButton? get currentOnPanel {
    final target = this.target;
    final label = currentButton;
    if (target == null || label == null || lastButtons != null) return null;
    final hits = target.buttons.where((b) => b.label == label).toList();
    return hits.length == 1 ? hits.first : null;
  }

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
    final onPanel = currentOnPanel;

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
                if (modeLabel case final m?)
                  Text(m, style: const TextStyle(fontSize: 18, color: KioskColors.warning)),
                if (target != null) ...[
                  KioskTargetLine(appliance: target),
                  const SizedBox(height: 6),
                ],
                // 목적(무엇을 하려고)은 보조로. 버튼 하나를 누르는 실행이면
                // 제목과 버튼이 같으니 되풀이하지 않는다.
                // 이어받은 실행은 제목이 가전 이름일 수 있다 — 위 대상 줄과 같은 말이면 쓰지 않는다.
                if (title.isNotEmpty &&
                    title != currentButton &&
                    title != target?.name)
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

        // ── 오른쪽: 실제 버튼판(읽기 전용) + 긴급 정지 ─────────────────
        // 예전에는 정지 하나만 있어 칸 대부분이 비었다(9/16 화면 평가). 위에는
        // 가전의 버튼판을 그려 **지금 누르는 자리**를 보여준다 -- 이 제품이 하는
        // 일은 실제 버튼을 누르는 것이다. 버튼판은 누를 수 없는 그림이라 정지
        // 옆에 있어도 급한 순간에 잘못 누를 행동이 늘지 않는다.
        SizedBox(
          width: 300,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 24, 24, 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (target != null && onPanel != null) ...[
                  Expanded(
                    child: _PanelMap(
                      appliance: target,
                      current: onPanel,
                      caution: _retrying,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                SizedBox(
                  width: double.infinity,
                  height: 96,
                  child: ElevatedButton.icon(
                    onPressed: onStop,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KioskColors.stop,
                      foregroundColor: Colors.white,
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
                      '정지',
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

// ── 버튼판 ─────────────────────────────────────────────────────────────────

/// 대상 가전의 버튼판. 지금 누르는 버튼 하나만 채운 면·두꺼운 테두리로 칠하고,
/// 나머지는 자리만 보여준다. 색을 빼도 채움과 테두리로 구분된다.
///
/// 스크린리더에는 왼쪽의 실시간 안내가 같은 말을 이미 하므로 읽지 않는다.
class _PanelMap extends StatelessWidget {
  const _PanelMap({
    required this.appliance,
    required this.current,
    required this.caution,
  });

  final ApplianceMap appliance;
  final ApplianceButton current;

  /// 보정 후 다시 누르는 중이면 주의색.
  final bool caution;

  @override
  Widget build(BuildContext context) {
    final accent = caution ? KioskColors.warning : KioskColors.primary;
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '지금 누르는 버튼',
            style: TextStyle(fontSize: 16, color: KioskColors.muted),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Column(
              children: [
                for (var y = 0; y < appliance.rows; y++)
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var x = 0; x < appliance.cols; x++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: _cell(appliance.buttonAt(x, y), accent),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(ApplianceButton? button, Color accent) {
    if (button == null) return const SizedBox.shrink();
    final on = button.id == current.id;
    return DecoratedBox(
      key: on ? const ValueKey('panel-current') : null,
      // 지금 칸만 면을 채운다. 나머지는 면 없이 옅은 윤곽만 -- 수동 조작 칸과
      // 같은 면색·테두리면 누를 수 있는 버튼으로 보였다(로그 ac 리뷰 지적).
      decoration: BoxDecoration(
        color: on ? accent : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: on ? Colors.white : Colors.white.withValues(alpha: 0.12),
          width: on ? 3 : 1,
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          // 칸이 작다. 긴 이름은 잘리지 않게 줄여서 한 줄에 넣는다.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              button.label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: on ? FontWeight.w800 : FontWeight.w500,
                color: on ? KioskColors.onAccent : KioskColors.muted,
              ),
            ),
          ),
        ),
      ),
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
                _SegmentedProgress(
                  total: total,
                  completed: done,
                  active: true,
                  caution: view._retrying,
                )
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
    this.caution = false,
  });

  final int total;
  final int completed;
  final bool active;

  /// 보정 후 다시 누르는 중. 지금 칸 테두리를 주의색으로 -- 위의 상태 구절·
  /// 버튼판과 같은 색이어야 한다(폰 실행 화면과 같은 규칙).
  final bool caution;

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
                    key: i == completed && active
                        ? const ValueKey('segment-current')
                        : null,
                    height: 12,
                    decoration: BoxDecoration(
                      // 끝난 칸은 무채색, 지금 칸의 테두리만 강조색.
                      color: i < completed
                          ? KioskColors.success
                          : KioskColors.surface2,
                      borderRadius: BorderRadius.circular(3),
                      border: (i == completed && active)
                          ? Border.all(
                              color: caution
                                  ? KioskColors.warning
                                  : KioskColors.primary,
                              width: 2,
                            )
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
