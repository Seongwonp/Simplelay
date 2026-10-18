import 'package:flutter/material.dart';

import '../../models/action_name.dart';
import '../../models/appliance.dart';
import '../../models/thinq_run.dart';
import '../../services/kiosk_api_service.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import 'hold_view.dart' show kPanelCaption;
import 'kiosk_scroll_area.dart';
import 'kiosk_text.dart';
import 'run_frame.dart';
import 'status_band.dart';
import 'step_trail.dart';

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
    this.doneButtons = const [],
    this.totalSteps,
    required this.verificationConfidence,
    required this.verificationDetail,
    required this.onStop,
    this.thinqOnly = false,
  });

  /// LG 가전 명령 하나만 보내는 실행(사용자 요청 10/18) — 버튼판·누를 순서·작은 팔 문구 없이 가운데 기다림 표시와
  /// '공기청정기에 명령을 보내는 중이에요' 한 줄. 정지 단추는 같은 자리·같은 모양. 서버가 누르는 버튼을 알려 오면
  /// (작은 팔이 움직이는 실행이면) 이 표시를 쓰지 않고 종전 화면으로 돌아간다.
  final bool thinqOnly;

  final String executionMode;

  bool get _mock => executionMode == 'mock';

  final String title;

  /// 이 실행이 **대상으로 삼은** 가전(서버가 말해준 job의 대상). 모르면 null.
  final ApplianceMap? target;
  final List<KioskButtonResult>? lastButtons;
  final String? currentButton;
  final int? currentAttempt;
  final int? completedSteps;

  /// 이 실행에서 이미 누른 버튼 이름(화면이 본 차례대로, 평가 3차 10/18). 버튼판에서 그 칸에 ✓를 단다 —
  /// 작은 팔이 누른 것이지 가전이 켜졌다는 뜻이 아니다. 지금 누르는 칸에는 달지 않는다.
  final List<String> doneButtons;

  /// 서버가 준 전체 단계 수. 없으면 진행을 비율로 지어내지 않는다.
  final int? totalSteps;
  final double? verificationConfidence;
  final String? verificationDetail;
  final VoidCallback onStop;

  bool get _retrying => (currentAttempt ?? 1) > 1;

  /// 무엇을 하는 중인가 — 가전 이름과 할 일(위 띠에 싣는다, 10/18). 이어받은 실행은 제목이 가전 이름일 수 있고,
  /// 버튼 하나를 누르는 실행이면 제목이 버튼과 같다 — 같은 말이면 한 번만.
  /// 할 일은 사람 명령문('즉석밥 데워줘')이 아니라 행동 이름('즉석밥 데우기')으로 — 폰 기록과 같은 규칙(평가 4차 10/18).
  String get _context {
    final what = actionName(title);
    return [
      if (target != null) target!.name,
      if (what.isNotEmpty && title != currentButton && what != target?.name) what,
    ].join('   ');
  }

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

  /// 이미 누른 칸(버튼판에서 이름이 한 번만 나오는 것만) → ✓. 지금 누르는 칸은 빼고 채움만 둔다.
  Map<String, bool> _donePressed(ApplianceMap target, ApplianceButton current) => {
        for (final label in doneButtons)
          if (KioskPanelPicture.uniqueButton(target, label) case final b?
              when b.id != current.id)
            b.id: true,
      };

  /// 누를 순서 칸(평가 7차 10/18) — 끝낸 수·전체 수가 있을 때만. 끝낸 칸 이름은 화면이 본 [doneButtons],
  /// 지금 칸은 [currentButton], 남은 칸은 이름을 모르니 번호만. 두 칸 미만·너무 많으면 null.
  List<KioskStep>? get steps {
    final total = totalSteps;
    if (total == null || !KioskStepTrail.worth(total)) return null;
    final done = (completedSteps ?? 0).clamp(0, total);
    return [
      for (var i = 0; i < total; i++)
        i < done
            // 끝낸 칸 이름을 화면이 못 봤으면(이어받은 실행·폴링 사이) 빈칸 대신 순서(평가 8차 10/18) — 이름은 지어내지 않는다.
            ? (label: i < doneButtons.length ? doneButtons[i] : '${i + 1}번째', state: KioskStepState.done)
            : i == done && currentButton != null
                ? (label: currentButton, state: KioskStepState.current)
                : (label: null, state: KioskStepState.todo),
    ];
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
        _mock ? '다시 누르는 연습 중' : '자리를 맞춰 다시 누르는 중',
        Icons.autorenew,
        KioskColors.warning
      );
    }
    if (_mock) return ('누르는 연습 중', Icons.touch_app_outlined, Colors.white);
    return _hasVerification
        // 보는 중은 눈 아이콘 하나(평가 3차 10/18 — 목록+돋보기 모양은 뜻이 둘로 읽혔다).
        ? ('제대로 눌렸는지 보는 중', Icons.visibility_outlined, Colors.white)
        : ('누르는 중', Icons.touch_app_outlined, Colors.white);
  }

  /// 무엇을 보고 있는지 숫자 없이 한 줄(2026-10-15 — 'mA·dB·센서 %'는 뜻을 몰랐다). 몇 번째 시도인지는 남긴다.
  /// 큰 글씨에서는 확인 문장을 뺀다 — 위 상태('제대로 눌렸는지 확인하는 중')가 같은 말을 하고, 남기면 마지막 줄이
  /// 스크롤 아래에서 잘렸다(UI 평가 3차 10/17).
  String? _evidence({bool large = false}) {
    final parts = <String>[
      if (_hasVerification && !_mock && !large) '가전이 켜지는지 보고 있어요',
      if (_retrying) '$currentAttempt번째 시도',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// 진행 한 줄(2026-10-15 B1) — 서버의 completed_steps는 **끝낸** 수다. 지금 누르는 번호는 끝낸 수 + 1이고,
  /// 다 끝났으면 '모두'라고 쓴다(예전에는 첫 버튼에서 '총 2단계 중 0단계'가 보였다).
  String progressLine(int total, int completed) {
    if (completed >= total) {
      return '$total개 모두 눌렀어요';
    }
    final now = (completed + 1).clamp(1, total);
    return '누를 버튼 $total개 중 $now번째';
  }

  /// LG 가전 보내는 중 — 위 띠(실행 중·가전 이름) + 가운데 기다림 + 한 줄 + 정지.
  Widget _thinqSending(BuildContext context) {
    final name = target?.name ?? '가전';
    final line = thinqSendingLine(name, practice: _mock);
    final sub = thinqSendingSub(practice: _mock);
    final large = KioskLayout.isLarge(context);
    return KioskRunFrame(
      band: _mock
          ? const KioskStatusBand.practice()
          : KioskStatusBand(
              tone: KioskBandTone.running,
              icon: Icons.play_circle_outline,
              label: '실행 중',
              detail: target?.name,
              detailIcon: target?.icon,
            ),
      header: const SizedBox.shrink(),
      body: Semantics(
        liveRegion: true,
        label: '$line. $sub',
        excludeSemantics: true,
        child: KioskScrollArea(
          key: const ValueKey('thinq-sending'),
          center: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: large ? 64 : 96,
                height: large ? 64 : 96,
                child: const CircularProgressIndicator(strokeWidth: 8, color: KioskColors.running),
              ),
              SizedBox(height: large ? KioskSpace.sm : KioskSpace.lg),
              KioskText(
                line,
                textKey: const ValueKey('thinq-sending-line'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: KioskType.status, fontWeight: FontWeight.w800, height: 1.25, color: Colors.white),
              ),
              const SizedBox(height: KioskSpace.xs),
              KioskText(
                sub,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: KioskType.body, height: 1.3, color: KioskColors.muted),
              ),
            ],
          ),
        ),
      ),
      stop: KioskStopButton(label: '정지', onPressed: onStop),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (thinqOnly && currentButton == null) return _thinqSending(context);
    final isDone = lastButtons != null;
    final target = this.target;
    final onPanel = currentOnPanel;
    final (phrase, icon, color) = _phrase();

    // 무엇을 하는 중인가(가전·할 일)는 위 띠로(화면 구조 개편 10/18) — 왼쪽 글은 상태·진행·한 줄 세 단계만.
    // 이어받은 실행은 제목이 가전 이름일 수 있다 — 같은 말이면 한 번만. 버튼 하나를 누르는 실행이면 제목이 버튼과 같다.
    final bandDetail = _context;

    final scroll = KioskScrollArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
    // 왼쪽 아래 빈자리에 누를 순서(평가 7차 10/18) — 큰 글씨는 세로 1열이라 자리가 없어 위 진행 줄만 둔다.
    final trail = isDone || KioskLayout.isLarge(context) ? null : steps;
    final body = trail == null
        ? scroll
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: scroll),
              const SizedBox(height: KioskSpace.sm),
              // 머리말은 결과 화면('누른 순서')과 같은 모양(평가 8차 10/18).
              KioskStepTrail(
                  key: const ValueKey('exec-step-trail'),
                  title: _mock ? '연습으로 누를 순서' : '누를 순서',
                  steps: trail,
                  caution: _retrying),
            ],
          );

    return KioskRunFrame(
      // 연습은 위 청록 띠(§3-2·2026-10-16 §4) — 작은 '연습 모드' 칩은 처음 보는 사람이 놓쳤다.
      band: _mock
          // 연습 띠는 한 줄로 둔다(문장이 길다) — 가전·할 일은 왼쪽 마지막 한 줄이 말한다.
          ? const KioskStatusBand.practice()
          : KioskStatusBand(
              tone: KioskBandTone.running,
              icon: Icons.play_circle_outline,
              label: '실행 중',
              detail: bandDetail,
              detailIcon: target?.icon,
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
                if (bandDetail.isNotEmpty) bandDetail,
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
      body: body,
      // 버튼판은 누를 수 없는 설명 그림이다 — 지금 누르는 자리만 채운다(§1-6).
      picture: target != null && onPanel != null
          ? KioskPanelPicture(
              appliance: target,
              current: onPanel,
              pressed: _donePressed(target, onPanel),
              caution: _retrying,
              caption: _mock ? '연습으로 누르는 자리예요. 화면은 누르지 않아도 돼요' : kPanelCaption,
              captionKey: const ValueKey('exec-panel-caption'),
            )
          : null,
      stop: KioskStopButton(label: '정지', onPressed: onStop),
    );
  }
}

// ── 진행 · 지금 버튼 · 한 줄 ─────────────────────────────────────────────────

/// 상태 제목(위 [KioskStatusHeader]) 아래 두 단계 — **진행**(N개 중 K번째, 지금 버튼 이름을 크게)과 **한 줄**
/// (다시 누르는 이유·무엇을 보는지). 예전의 '이번 버튼' 이름표·대상 줄·할 일 제목은 위 띠가 말한다(10/18).
class _NowBlock extends StatelessWidget {
  const _NowBlock({required this.view});

  final KioskExecutingView view;

  @override
  Widget build(BuildContext context) {
    final large = KioskLayout.isLarge(context);
    final evidence = view._evidence(large: large);
    final total = view.totalSteps;
    final done = view.completedSteps ?? 0;
    // 한 줄 — 다시 누르는 중이면 그 이유가 먼저, 아니면 무엇을 보는지.
    final String? line = view._retrying
        // '재시도'는 실패로 읽힌다. 사실만 말한다 — 한 번 더 누른다(안전하다고 말하지 않는다, 열린 문제 R1).
        ? [
            // 연습은 위 띠가 '실제 가전은 그대로예요'를 말한다 — 같은 말을 또 쓰지 않는다(평가 4차 10/18).
            if (!view._mock) '눌렸는지 몰라서 한 번 더 눌러요',
            '${view.currentAttempt}번째 시도',
          ].join('. ')
        : view._mock
            // 연습 띠는 한 줄이라 가전·할 일을 싣지 않는다 — 여기 마지막 한 줄로.
            ? (view._context.isEmpty ? null : view._context)
            : evidence;

    // 스크린리더는 위 상태 영역이 한 번에 읽는다.
    return ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (total != null && total > 0) ...[
            KioskText(view.progressLine(total, done),
                textKey: const ValueKey('execution-step'),
                style: const TextStyle(
                    fontSize: KioskType.body,
                    color: KioskColors.muted,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
          ] else if (view.completedSteps != null) ...[
            KioskText('버튼 $done개를 눌렀어요',
                style: const TextStyle(
                    fontSize: KioskType.body, color: KioskColors.muted)),
            const SizedBox(height: 4),
          ],
          if (view.currentButton != null)
            // 따옴표로 감싸지 않는다(평가 7차 10/18 — "'시작'"은 개발자 말투). 이름은 크게, '버튼'은 한 단계 작게.
            Text.rich(
              TextSpan(children: [
                TextSpan(text: view.currentButton),
                const TextSpan(
                    text: ' 버튼',
                    style: TextStyle(
                        fontSize: KioskType.status,
                        fontWeight: FontWeight.w700,
                        color: KioskColors.muted)),
              ]),
              style: const TextStyle(
                fontSize: KioskType.key,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.15,
              ),
            ),
          if (line != null) ...[
            const SizedBox(height: KioskSpace.sm),
            KioskText(
              line,
              style: TextStyle(
                  fontSize: KioskType.body,
                  height: 1.3,
                  color: view._retrying ? KioskColors.warning : KioskColors.muted),
            ),
          ],
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
            child: KioskText(
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
