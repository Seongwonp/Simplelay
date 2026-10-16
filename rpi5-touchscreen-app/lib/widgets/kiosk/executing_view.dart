import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'hold_view.dart' show kPanelCaption;
import 'kiosk_scroll_area.dart';
import 'kiosk_target_line.dart';
import 'kiosk_text.dart';
import 'run_frame.dart';
import 'status_band.dart';

/// 실행 화면 — 센서 대시보드가 아니라 **지금 무슨 버튼을 어떻게 하고 있는가**.
///
/// 읽는 순서: 위 상태 띠(실행 중·연습 중) → 왼쪽 위 상태(누르는 중 / 제대로 눌렸는지 확인하는 중 /
/// 자리를 맞춰 다시 누르는 중) → 어느 가전·무엇을 → 지금 누르는 버튼(크게) → 누를 버튼 N개 중 K번째.
/// 전류·소리·센서 % 같은 숫자는 화면에 싣지 않는다(서버 기록에는 남는다, 2026-10-15 §3-1).
/// 연습(mock)은 위 청록 띠로 말하고, 실물 동사(누르는·눌렸는지) 대신 '짚는'으로 쓴다(§3-2).
/// 정지는 정지 대기·정지 미확인 화면과 **같은 자리·같은 크기·같은 모양**이다(2026-10-16 디자인 규격 §1-1).
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
  /// 상태 영역의 아이콘도 함께 정한다(2026-10-16 §1-2) — 색만으로 말하지 않는다.
  (String, IconData, Color) _phrase() {
    if (currentButton == null) {
      return ('준비 중', Icons.hourglass_empty, KioskColors.muted);
    }
    if (_retrying) {
      return (
        _mock ? '다시 짚는 중' : '자리를 맞춰 다시 누르는 중',
        Icons.autorenew,
        KioskColors.warning
      );
    }
    if (_mock) return ('짚는 중', Icons.touch_app_outlined, Colors.white);
    return _hasVerification
        ? ('제대로 눌렸는지 확인하는 중', Icons.manage_search, Colors.white)
        : ('누르는 중', Icons.touch_app_outlined, Colors.white);
  }

  /// 무엇을 보고 있는지 숫자 없이 한 줄(2026-10-15 — 'mA·dB·센서 %'는 뜻을 몰랐다). 몇 번째 시도인지는 남긴다.
  /// 큰 글씨에서는 확인 문장을 뺀다 — 위 상태('제대로 눌렸는지 확인하는 중')가 같은 말을 하고, 남기면 마지막 줄이
  /// 스크롤 아래에서 잘렸다(UI 평가 3차 10/17).
  String? _evidence({bool large = false}) {
    final parts = <String>[
      if (_hasVerification && !_mock && !large) '버튼을 누른 뒤 가전 반응을 보고 있어요',
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
    final (phrase, icon, color) = _phrase();
    final large = KioskLayout.isLarge(context);

    final body = KioskScrollArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (target != null) ...[
            KioskTargetLine(appliance: target),
            const SizedBox(height: 4),
          ],
          // 목적(무엇을 하려고)은 보조로. 버튼 하나를 누르는 실행이면
          // 제목과 버튼이 같으니 되풀이하지 않는다.
          // 이어받은 실행은 제목이 가전 이름일 수 있다 — 위 대상 줄과 같은 말이면 쓰지 않는다.
          if (title.isNotEmpty &&
              title != currentButton &&
              title != target?.name)
            KioskText(
              title,
              style: const TextStyle(
                fontSize: KioskType.body,
                fontWeight: FontWeight.w600,
                color: KioskColors.muted,
              ),
              // 2줄까지 보이고 그래도 넘치면 줄인다(2026-10-15 — 1줄 말줄임에서 무엇을 하는지 잘렸다).
              // 큰 글씨는 1줄 — 지금 누르는 버튼이 스크롤 아래로 밀리지 않게(UI 평가 3차 10/17).
              maxLines: large ? 1 : 2,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 10),
          if (!isDone)
            _NowBlock(view: this)
          else
            for (final b in lastButtons!)
              _StepRow(
                label: b.button,
                state: b.success ? _StepState.done : _StepState.failed,
              ),
        ],
      ),
    );

    return KioskRunFrame(
      // 연습은 위 청록 띠(§3-2·2026-10-16 §4) — 작은 '연습 모드' 칩은 처음 보는 사람이 놓쳤다.
      band: _mock
          ? const KioskStatusBand.practice()
          : const KioskStatusBand(
              tone: KioskBandTone.running,
              icon: Icons.play_circle_outline,
              label: '실행 중',
            ),
      // 다 누른 뒤 결과 화면으로 넘어가기 전 잠깐(0.9초)은 상태를 새로 지어내지 않고 목록 제목만 둔다.
      header: isDone
          ? const KioskStatusHeader(
              icon: Icons.checklist,
              title: '누른 버튼',
              iconColor: KioskColors.muted)
          : Semantics(
              liveRegion: true,
              label: [
                if (currentButton != null) '$currentButton 버튼',
                phrase,
                if (_evidence() case final e?) e,
                if (totalSteps case final t? when t > 0)
                  progressLine(t, completedSteps ?? 0),
              ].join('. '),
              child: ExcludeSemantics(
                child: KioskStatusHeader(
                    icon: icon, title: phrase, iconColor: color),
              ),
            ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!isDone && totalSteps != null && totalSteps! > 0) ...[
          ExcludeSemantics(
              child: Text(progressLine(totalSteps!, completedSteps ?? 0),
                  key: const ValueKey('execution-step'),
                  style: const TextStyle(
                      fontSize: KioskType.body,
                      color: Colors.white,
                      fontWeight: FontWeight.w700))),
          const SizedBox(height: 8),
        ],
        Expanded(child: body),
      ]),
      // 버튼판은 누를 수 없는 설명 그림이다 — 지금 누르는 자리만 채운다(§1-6).
      picture: target != null && onPanel != null
          ? KioskPanelPicture(
              appliance: target,
              current: onPanel,
              caution: _retrying,
              caption: _mock ? '연습으로 짚는 자리예요 · 화면은 누르지 않아도 돼요' : kPanelCaption,
              captionKey: const ValueKey('exec-panel-caption'),
            )
          : null,
      stop: KioskStopButton(label: '정지', onPressed: onStop),
    );
  }
}

// ── 지금 누르는 버튼 · 단계 ─────────────────────────────────────────────────

class _NowBlock extends StatelessWidget {
  const _NowBlock({required this.view});

  final KioskExecutingView view;

  @override
  Widget build(BuildContext context) {
    final evidence = view._evidence(large: KioskLayout.isLarge(context));
    final total = view.totalSteps;
    final done = view.completedSteps ?? 0;

    // 스크린리더는 위 상태 영역이 한 번에 읽는다.
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 큰 버튼 이름이 무엇인지 이름표(외부 평가 10/16 2차 k05). 
          if (view.currentButton != null)
            Text(
              // 누르는 중·확인 중 어느 때나 맞는 말(외부 평가 10/16 3차 — '지금 누르는'은 확인 단계와 시제가 어긋났다).
              '이번 버튼',
              style: const TextStyle(fontSize: KioskType.caption, color: KioskColors.muted),
            ),
          if (view.currentButton != null)
            Text(
              "'${view.currentButton}'",
              style: const TextStyle(
                fontSize: KioskType.key,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.15,
              ),
            ),
          if (view._retrying) ...[
            const SizedBox(height: 4),
            // '재시도'는 실패로 읽힌다. 사실만 말한다 — 한 번 더 누른다(안전하다고 말하지 않는다, 열린 문제 R1).
            Text(
              view._mock ? '연습이라 실제로 누르지는 않아요' : '눌렸는지 확인되지 않아 한 번 더 눌러요',
              style: const TextStyle(
                  fontSize: KioskType.body, color: KioskColors.warning),
            ),
          ],
          if (evidence != null) ...[
            const SizedBox(height: 6),
            Text(
              evidence,
              style: const TextStyle(
                  fontSize: KioskType.caption, color: KioskColors.muted),
            ),
          ],
          if (total == null && view.completedSteps != null)
            Text(view._mock ? '버튼 $done개를 짚었어요' : '버튼 $done개를 눌렀어요',
                style: const TextStyle(
                    fontSize: KioskType.body, color: KioskColors.muted)),
        ],
      ),
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
              style: const TextStyle(
                  fontSize: KioskType.body, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
