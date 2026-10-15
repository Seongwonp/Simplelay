import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import 'hold_view.dart' show kPanelCaption;
import 'kiosk_scroll_area.dart';
import 'kiosk_target_line.dart';
import 'practice_band.dart';

/// 실행 화면 — 센서 대시보드가 아니라 **지금 무슨 버튼을 어떻게 하고 있는가**.
///
/// 읽는 순서: 어느 가전 → 지금 누르는 버튼(가장 크게) → 지금 상태(누르는 중 /
/// 제대로 눌렸는지 확인하는 중 / 자리를 맞춰 다시 누르는 중) → 누를 버튼 N개 중 K번째.
/// 전류·소리·센서 % 같은 숫자는 화면에 싣지 않는다(서버 기록에는 남는다, 2026-10-15 §3-1).
/// 연습(mock)은 맨 위 고정 띠로 말하고, 실물 동사(누르는·눌렸는지) 대신 '짚는'으로 쓴다(§3-2). 긴급 정지는 오른쪽에 떨어뜨려 두고, 색을
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

  bool get _mock => executionMode == 'mock';

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

  /// 지금 상태 구절과 그 모양(2026-10-15 §3-1). '보정'은 처음 보는 사람이 몰랐다 — 자리를 맞춰 다시 누른다고 쓴다.
  (String, IconData?, Color) _phrase() {
    if (currentButton == null) {
      return ('준비 중', null, KioskColors.muted);
    }
    if (_retrying) {
      return (
        _mock ? '다시 짚는 중' : '자리를 맞춰 다시 누르는 중',
        Icons.autorenew,
        KioskColors.warning
      );
    }
    if (_mock) return ('짚는 중', null, Colors.white);
    return _hasVerification
        ? ('제대로 눌렸는지 확인하는 중', null, Colors.white)
        : ('누르는 중', null, Colors.white);
  }

  /// 무엇을 보고 있는지 숫자 없이 한 줄(2026-10-15 — 'mA·dB·센서 %'는 뜻을 몰랐다). 몇 번째 시도인지는 남긴다.
  String? _evidence() {
    final parts = <String>[
      if (_hasVerification && !_mock) '버튼을 누른 뒤 가전 반응을 보고 있어요',
      if (_retrying) '$currentAttempt번째 시도',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 진행 한 줄(2026-10-15 B1) — 서버의 completed_steps는 **끝낸** 수다. 지금 누르는 번호는 끝낸 수 + 1이고,
  /// 다 끝났으면 '모두'라고 쓴다(예전에는 첫 버튼에서 '총 2단계 중 0단계'가 보였다).
  String progressLine(int total, int completed) {
    if (completed >= total) {
      return _mock ? '$total개 모두 짚었어요' : '$total개 모두 눌렀어요';
    }
    final now = (completed + 1).clamp(1, total);
    return _mock ? '짚을 버튼 $total개 중 $now번째' : '누를 버튼 $total개 중 $now번째';
  }

  @override
  Widget build(BuildContext context) {
    final isDone = lastButtons != null;
    final target = this.target;
    final onPanel = currentOnPanel;

    final row = Row(
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
                    // 2줄까지 보이고 그래도 넘치면 줄인다(2026-10-15 — 1줄 말줄임에서 무엇을 하는지 잘렸다).
                    maxLines: 2,
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
                      mock: _mock,
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
    // 연습은 맨 위 고정 띠(§3-2) — 작은 '연습 모드' 칩은 처음 보는 사람이 놓쳤다.
    if (!_mock) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [const KioskPracticeBand(), Expanded(child: row)],
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
    this.mock = false,
  });

  final ApplianceMap appliance;
  final ApplianceButton current;

  /// 연습이면 작은 팔이 실제로 누르지 않는다 — 그림 위 안내도 연습으로.
  final bool mock;

  /// 보정 후 다시 누르는 중이면 주의색.
  final bool caution;

  @override
  Widget build(BuildContext context) {
    final accent = caution ? KioskColors.warning : KioskColors.primary;
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 칸이 실제 버튼처럼 보여 눌러도 될 것 같다는 지적(2026-10-15 §3-1) — 누르는 자리라고 말한다.
          Text(
            mock ? '연습으로 짚는 자리예요 · 화면은 누르지 않아도 돼요' : kPanelCaption,
            key: const ValueKey('exec-panel-caption'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, color: KioskColors.muted),
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
        if (total != null && total > 0) view.progressLine(total, done),
      ].join('. '),
      child: ExcludeSemantics(
        // 큰 글씨에서 아래(진행 막대)가 넘치면 스크롤 막대가 보인다(2026-10-15).
        child: KioskScrollArea(
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
                // '재시도'는 실패로 읽힌다. 사실만 말한다 — 한 번 더 누른다(안전하다고 말하지 않는다, 열린 문제 R1).
                Text(
                  view._mock
                      ? '연습이라 실제로 누르지는 않아요'
                      : '눌렸는지 확인되지 않아 한 번 더 눌러요',
                  style: const TextStyle(fontSize: 20, color: KioskColors.warning),
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
                  label: view.progressLine(total, done),
                  total: total,
                  completed: done,
                  active: true,
                  caution: view._retrying,
                )
              else if (view.completedSteps != null)
                Text(
                  view._mock ? '버튼 $done개를 짚었어요' : '버튼 $done개를 눌렀어요',
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
    required this.label,
    required this.total,
    required this.completed,
    required this.active,
    this.caution = false,
  });

  final String label;
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
          label,
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
