import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../models/command_result.dart';
import '../../models/scenario_run.dart';
import '../../theme/kiosk_colors.dart';
import 'kiosk_target_line.dart';
import 'kiosk_timings.dart';

/// 실행 결과 화면.
///
/// 성공과 실패는 다르게 끝나야 한다. 성공은 확인만 하면 되니 잠시 뒤 자동으로
/// 대기 화면으로 돌아가지만, 실패는 사용자가 **무엇을 해야 하는지** 알아야
/// 하므로 자동으로 사라지지 않고 다음 행동 버튼을 제공한다 — 이전에는 둘 다
/// 3초 뒤 사라져서, 고령 사용자는 이유도 대처법도 모른 채 화면만 놓쳤다.
///
/// 이 시스템이 끝낸 것은 **버튼 조작**이다. 조리·세탁이 끝났다고 말하지 않는다.
class KioskDoneView extends StatelessWidget {
  const KioskDoneView({
    this.executionMode = 'unknown',
    super.key,
    required this.success,
    required this.label,
    this.target,
    this.reason,
    this.onRetry,
    this.onManual,
    this.onDismiss,
    this.route,
    this.confirmation,
    this.detail,
    this.operationConfirmed,
    this.operationSource,
    this.operationDetail,
    this.runSteps = const [],
  });

  /// 끝난 다단계 실행의 단계별 결과(G4, GET /scenarios/last-run). **이 job의
  /// 기록일 때만** 화면이 넘긴다. 두 단계 이상일 때만 그린다 — 한 단계는 위
  /// 한 줄이 이미 같은 말을 한다.
  final List<ScenarioRunStep> runSteps;

  /// L3(가전 동작) 판정. **null이면 말하지 않는다** — 버튼을 누른 것과
  /// 가전이 실제로 움직인 것은 다른 사실이고, 판정기가 없는 실행에서
  /// "동작을 확인했다"는 말이 나오면 안 된다.
  final bool? operationConfirmed;

  /// 판정 입력 real | mock. mock의 true는 실제 동작 근거가 아니다.
  final String? operationSource;
  final String? operationDetail;

  /// 제어 경로 physical | thinq. 옛 서버면 null이고 배지를 그리지 않는다.
  final String? route;

  /// 확인 수준 문구(상태 확인됨·접수됨·접수 불명 등). 모르면 null.
  final String? confirmation;

  /// 서버가 쓴 한 줄(ThinQ 결과).
  final String? detail;

  final String executionMode;
  String get modeLabel => executionMode == 'mock' ? '모의 실행 · 실제 조작 아님'
      : executionMode == 'real' ? '실제 장치로 실행' : '실행 환경 미확인';

  final bool success;
  final String label;

  /// 이 실행이 대상으로 삼은 가전. 모르면 null이고 지어내지 않는다.
  final ApplianceMap? target;

  /// 실패 원인 — 문구와 권하는 행동이 달라진다. null이면 일반 실행 실패.
  final KioskFailureReason? reason;

  final VoidCallback? onRetry;
  final VoidCallback? onManual;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final r = reason ?? KioskFailureReason.execution;
    // 확인 못 함은 실패가 아니다 — 빨강이 아니라 주의색으로 말한다.
    final color = success
        ? KioskColors.success
        : r.isUnconfirmed
            ? KioskColors.warning
            : KioskColors.danger;
    final target = this.target;
    final thinq = route == 'thinq';
    final facts = [
      if (routeLabel(route) case final path?) path,
      if (confirmation case final c?) c,
    ];
    // 성공의 가장 큰 글자. 물리 경로에서 실행 환경을 모르면(옛 노드·UART가
    // 보고하지 않음) '버튼 조작을 마쳤어요'라고 단정하지 않는다 — 실행기가
    // 완료를 보고했다는 사실까지만 안다.
    final successHeadline = thinq
        ? '가전 상태를 확인했어요'
        : executionMode == 'unknown'
            ? '실행기가 완료를 보고했어요'
            : '버튼 조작을 마쳤어요';
    final operationSentence = switch (operationConfirmed) {
      true => '가전 동작도 확인했어요',
      false => '가전 동작은 확인하지 못했어요',
      null => null,
    };

    return ColoredBox(
      color: KioskColors.bg,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
          child: Semantics(
            liveRegion: true,
            label: [
              success ? '$label — $successHeadline' : r.detail(label),
              ...facts,
              if (operationSentence != null) operationSentence,
              if (runSteps.length > 1)
                for (var i = 0; i < runSteps.length; i++)
                  '${_stepTitle(i, runSteps[i])}. ${runStepFacts(runSteps[i])}',
            ].join('. '),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(modeLabel, style: const TextStyle(fontSize: 18, color: KioskColors.warning)),
                _ResultRing(
                  icon: success
                      ? Icons.check
                      : r.isUnconfirmed
                          ? Icons.question_mark
                          : Icons.close,
                  color: color,
                ),
                const SizedBox(height: 14),
                // 가장 큰 글자가 그냥 '완료'면, 사용자는 조리나 냉방 자체가
                // 끝났다고 읽는다. 이 시스템이 끝낸 것은 **버튼 조작**이다.
                Text(
                  // 연결 유실은 정지의 증거가 아니다. 서버가 정지 결과를
                  // 반환한 경우에만 실행을 멈췄다고 표시한다.
                  success ? successHeadline : r.headline,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: color,
                  ),
                ),
                if (target != null) ...[
                  const SizedBox(height: 8),
                  KioskTargetLine(appliance: target),
                ],
                // 경로(물리 버튼 / ThinQ)와 확인 수준. 서버가 준 값만 말한다.
                if (facts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    facts.join(' · '),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 22, color: Colors.white),
                  ),
                ],
                // 위 한 줄은 /status의 **마지막 단계** 기준이다. 두 가전을
                // 잇는 실행이면 단계마다 경로·확인 수준을 따로 말한다.
                if (runSteps.length > 1) _RunSteps(steps: runSteps),
                const SizedBox(height: 6),
                if (success) ...[
                  // 무엇을 했는지 한 줄로 재확인하고, 어떻게 확인했는지를 말한다.
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    thinq
                        ? (executionMode == 'mock'
                            ? '모의 ThinQ 상태를 확인했어요 · 실제 가전 아님'
                            : 'ThinQ로 보낸 뒤 가전 상태를 다시 읽어 확인했어요')
                        : executionMode == 'mock'
                            ? '모의 절차를 마쳤어요 · 실제 조작 아님'
                            : executionMode == 'real'
                                ? '실행기가 버튼 조작 완료를 보고했어요'
                                : '실제 조작 여부는 확인하지 못했어요',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, color: KioskColors.muted),
                  ),
                  _OperationLine(
                    sentence: operationSentence,
                    confirmed: operationConfirmed == true,
                    source: operationSource,
                    detail: operationDetail,
                  ),
                  const SizedBox(height: 18),
                  _AutoReturn(onDismiss: onDismiss),
                ] else ...[
                  Text(
                    r.detail(label),
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(fontSize: 22, color: KioskColors.muted),
                  ),
                  if (detail case final d? when d.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      d,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 18, color: KioskColors.muted),
                    ),
                  ],
                  _OperationLine(
                    sentence: operationSentence,
                    confirmed: operationConfirmed == true,
                    source: operationSource,
                    detail: operationDetail,
                  ),
                  const SizedBox(height: 20),
                  _FailureActions(
                    onRetry: onRetry,
                    onManual: onManual,
                    onDismiss: onDismiss,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _stepTitle(int i, ScenarioRunStep step) =>
    '${i + 1}. ${step.summary.isNotEmpty ? step.summary : '가전 확인 필요'}';

/// 단계별 결과 — 번호·서버가 쓴 문장, 그 아래 경로·실행 환경·확인 수준·결과.
/// 확인 수준은 한 줄 요약과 같은 규칙(`confirmationLabel`)이다.
class _RunSteps extends StatelessWidget {
  const _RunSteps({required this.steps});

  final List<ScenarioRunStep> steps;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < steps.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _stepTitle(i, steps[i]),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        runStepFacts(steps[i]),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 18, color: KioskColors.muted),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
}

/// L3(가전 동작) 판정 한 줄. 판정이 없으면 자리도 차지하지 않는다.
class _OperationLine extends StatelessWidget {
  const _OperationLine({
    required this.sentence,
    required this.confirmed,
    this.source,
    this.detail,
  });

  final String? sentence;
  final bool confirmed;
  final String? source;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final sentence = this.sentence;
    if (sentence == null) return const SizedBox.shrink();
    final caption = [
      // 모의 판정의 true는 실제 동작 근거가 아니다 — 출처를 같이 말한다.
      if (source == 'mock') '모의 판정 · 실제 동작 근거는 아니에요',
      if (source == 'real') '실측 판정',
      if (detail case final d? when d.isNotEmpty) d,
    ].join(' · ');
    final color = confirmed ? KioskColors.success : KioskColors.warning;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 색으로만 말하지 않는다 — 모양이 같이 간다.
              Icon(confirmed ? Icons.verified_outlined : Icons.help_outline,
                  size: 24, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  sentence,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w600, color: color),
                ),
              ),
            ],
          ),
          if (caption.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              caption,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, color: KioskColors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// 실패 원인별 안내. "실행 중 문제가 발생했습니다"는 사용자가 무엇을 해야
/// 할지 알려주지 못했다 — 원인마다 다음 행동이 다르다.
enum KioskFailureReason {
  /// 버튼은 눌렀지만 센서가 눌림을 확인하지 못함(재시도 소진)
  execution,

  /// 백엔드 무응답 — 가전이 어떤 상태인지 알 수 없다
  serverLost,

  /// 긴급 정지로 멈춤 — 실패가 아니라 의도된 중단
  stopped,

  /// 눌림을 확인하지 못해 스스로 안전 정지(재시도 소진 등)
  safetyStop,

  /// ThinQ — 보냈고 접수됐지만 상태로 확인하지 못함. 실패가 아니다.
  unconfirmed,

  /// ThinQ — 보냈지만 받았는지조차 모름(접수 불명). 실패가 아니다.
  receiptUnknown,

  /// ThinQ — 거절되거나 보내지 않아 실행되지 않음.
  notExecuted;

  /// 실패가 아니라 '확인 못 함'. 다시 보내면 중복 실행이 될 수 있다.
  bool get isUnconfirmed =>
      this == KioskFailureReason.unconfirmed ||
      this == KioskFailureReason.receiptUnknown;

  /// 가장 큰 글자.
  String get headline => switch (this) {
        KioskFailureReason.execution => '버튼 조작을 확인하지 못했어요',
        KioskFailureReason.serverLost => '실행 상태를 확인할 수 없어요',
        KioskFailureReason.stopped => '실행을 멈췄어요',
        KioskFailureReason.safetyStop => '안전하게 멈췄어요',
        KioskFailureReason.unconfirmed => '보냈지만 확인하지 못했어요',
        KioskFailureReason.receiptUnknown => '받았는지 확인이 필요해요',
        KioskFailureReason.notExecuted => '명령이 실행되지 않았어요',
      };

  String detail(String label) => switch (this) {
        KioskFailureReason.execution =>
          '$label — 버튼이 눌렸는지 확인하지 못했어요.\n가전을 살펴본 뒤 다시 시도해주세요.',
        KioskFailureReason.serverLost =>
          'SimpleLay 본체의 실행 결과를 확인하지 못했어요.\n가전 상태를 직접 확인해주세요.',
        KioskFailureReason.stopped =>
          '$label — 실행을 멈췄어요.\n장치가 완전히 멈췄는지 확인한 뒤 다시 시도해 주세요.',
        KioskFailureReason.safetyStop =>
          '$label — 눌림을 확인하지 못해 안전하게 멈췄어요.\n가전을 살펴본 뒤 다시 시도해 주세요.',
        KioskFailureReason.unconfirmed =>
          '$label — 명령을 보냈지만 확인하지 못했어요.\n가전을 직접 확인해 주세요.',
        KioskFailureReason.receiptUnknown =>
          '$label — 가전이 명령을 받았는지 알 수 없어요.\n다시 보내기 전에 가전을 직접 확인해 주세요.',
        KioskFailureReason.notExecuted =>
          '$label — 명령이 실행되지 않았어요.\n가전 연결을 확인해 주세요.',
      };
}

/// 서버 결과 → 실패 화면의 이유. 성공이면 쓰지 않는다.
///
/// 원격(UART) 실패는 예전에 last_status=safety_stopped로만 와서 "멈췄어요"로
/// 안내됐다(9/29 결함 §4). 이제 last_outcome으로 정지 요청(stopped)·안전 정지·
/// 실패를 가른다.
KioskFailureReason failureReasonOf(
  ResultKind kind, {
  String? route,
  String? receipt,
}) =>
    switch (kind) {
      ResultKind.stopped => KioskFailureReason.stopped,
      ResultKind.safetyStop => KioskFailureReason.safetyStop,
      ResultKind.unconfirmed => receipt == 'unknown'
          ? KioskFailureReason.receiptUnknown
          : KioskFailureReason.unconfirmed,
      ResultKind.failed => route == 'thinq'
          ? KioskFailureReason.notExecuted
          : KioskFailureReason.execution,
      ResultKind.success => KioskFailureReason.execution,
    };

class _ResultRing extends StatelessWidget {
  const _ResultRing({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  // 뜻을 전하는 것은 아이콘이 아니라 글자다 -- 원은 결과를 알리는 정도로만 둔다
  Widget build(BuildContext context) => Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.14),
          border: Border.all(color: color.withValues(alpha: 0.45), width: 2),
        ),
        child: Icon(
          icon,
          size: 38,
          color: color,
        ),
      );
}

/// 성공 후 자동 복귀를 **글자로도** 말하고, 기다리기 싫은 사람의 길을 둔다.
class _AutoReturn extends StatelessWidget {
  const _AutoReturn({required this.onDismiss});

  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: KioskTimings.doneReturn.inSeconds.toDouble(), end: 0),
            duration: KioskTimings.doneReturn,
            builder: (_, seconds, __) => Text(
              '${seconds.ceil()}초 뒤 처음 화면으로 돌아가요',
              style: const TextStyle(fontSize: 18, color: KioskColors.muted),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 220,
            height: 4,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 1.0, end: 0.0),
              duration: KioskTimings.doneReturn,
              builder: (context, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 4,
                  backgroundColor: KioskColors.border,
                  valueColor: AlwaysStoppedAnimation(
                    Colors.white.withValues(alpha: 0.3),
                  ),
                ),
              ),
            ),
          ),
          if (onDismiss != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 56,
              child: OutlinedButton(
                onPressed: onDismiss,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: KioskColors.border),
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  '처음으로',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      );
}

class _FailureActions extends StatelessWidget {
  const _FailureActions({
    required this.onRetry,
    required this.onManual,
    required this.onDismiss,
  });

  final VoidCallback? onRetry;
  final VoidCallback? onManual;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onRetry != null)
              _ActionButton(
                label: '다시 시도',
                icon: Icons.refresh,
                primary: true,
                onTap: onRetry!,
              ),
            if (onRetry != null && onManual != null) const SizedBox(width: 12),
            if (onManual != null)
              _ActionButton(
                label: '버튼으로 조작',
                icon: Icons.grid_view_rounded,
                primary: false,
                onTap: onManual!,
              ),
          ],
        ),
        if (onDismiss != null) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: TextButton(
              onPressed: onDismiss,
              style: TextButton.styleFrom(
                foregroundColor: KioskColors.muted,
                padding: const EdgeInsets.symmetric(horizontal: 28),
              ),
              child: const Text('닫기', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 고령 사용자 기준 터치 타깃 — 높이 60px에 넉넉한 좌우 여백
    final labelText = Text(
      label,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
    );
    return SizedBox(
      height: 60,
      child: primary
          ? ElevatedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 22),
              label: labelText,
              style: ElevatedButton.styleFrom(
                backgroundColor: KioskColors.primary,
                foregroundColor: Colors.black,
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 26),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            )
          : OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, size: 22),
              label: labelText,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFAF7F2),
                side: const BorderSide(color: KioskColors.border),
                padding: const EdgeInsets.symmetric(horizontal: 22),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
    );
  }
}
