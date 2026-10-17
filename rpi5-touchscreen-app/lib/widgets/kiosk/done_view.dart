import 'package:flutter/material.dart';

import '../../models/appliance.dart';
import '../../models/command_result.dart';
import '../../models/scenario_run.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import '../../services/kiosk_api_service.dart' show KioskButtonResult;
import 'kiosk_scroll_area.dart';
import 'panel_picture.dart';
import 'kiosk_target_line.dart';
import 'kiosk_text.dart';
import 'kiosk_timings.dart';
import 'practice_band.dart';
import 'status_band.dart';

/// 실행 결과 화면.
///
/// 성공과 실패는 다르게 끝나야 한다. 성공은 확인만 하면 되니 잠시 뒤 자동으로
/// 대기 화면으로 돌아가지만, 실패는 사용자가 **무엇을 해야 하는지** 알아야
/// 하므로 자동으로 사라지지 않고 다음 행동 버튼을 제공한다 — 이전에는 둘 다
/// 3초 뒤 사라져서, 고령 사용자는 이유도 대처법도 모른 채 화면만 놓쳤다.
///
/// 이 시스템이 끝낸 것은 **버튼 누르기**다. 조리·세탁이 끝났다고 말하지 않는다.
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
    this.resultConfirmation,
    this.detail,
    this.operationConfirmed,
    this.operationSource,
    this.operationDetail,
    this.runSteps = const [],
    this.stopLevel,
    this.stopAckMs,
    this.abortReason,
    this.autoReturnHeld = false,
    this.onHold,
    this.pressed,
  });

  /// 사용자가 화면을 만져 자동 복귀를 멈췄다(UI 평가 10/17) — 남은 초 대신 '자동으로 닫지 않아요'.
  final bool autoReturnHeld;

  /// 화면을 만지면 부른다(성공 화면의 자동 복귀 멈춤). 단추를 누를 때도 불리지만 단추 동작은 그대로다.
  final VoidCallback? onHold;

  /// 작은 팔이 누른 버튼 기록(이름·보고 결과). 버튼판에서 모두 자리를 찾으면 오른쪽 그림에 누른 칸을 표시한다
  /// (화면 구조 개편 10/18). 모르면 null — 지금처럼 가운데 글만.
  final List<KioskButtonResult>? pressed;

  /// 모션 걸림·재시작 등으로 재시도 없이 멈춘 원인(2026-10-14, /status last_abort_reason). 안전 정지에만 쓴다.
  final String? abortReason;

  /// 정지로 멈춘 실행의 확인 단계(2026-10-13, /status last_stop_level): sent | mcu_ack | verified.
  /// null이면 정지 줄을 그리지 않는다(옛 서버·로컬 모의). 정지로 멈춘 실행(stopped)에만 쓴다.
  final String? stopLevel;
  final int? stopAckMs;

  Future<void> _confirmRetry(BuildContext context, bool mock) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(mock ? '연습을 다시 할까요?' : '가전을 봐 주셨나요?',
                  style: const TextStyle(fontSize: KioskType.status)),
              content: Text(
                  mock
                      ? '실제 가전에는 보내지 않아요.'
                      : '$kDontRetryIfOn.',
                  style: const TextStyle(fontSize: KioskType.body)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style:
                        TextButton.styleFrom(minimumSize: const Size(120, 48)),
                    child: const Text('취소',
                        style: TextStyle(fontSize: KioskType.body))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(180, 48)),
                    child: const Text('네, 다시 시도',
                        style: TextStyle(fontSize: KioskType.body))),
              ],
            ));
    if (confirmed == true && context.mounted) onRetry?.call();
  }

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

  /// 확인 근거 원값(/status last_confirmation, 2026-10-14). ThinQ 성공을 확인한 사실만큼 말한다 —
  /// already_at_target(보내지 않음) · state_confirmed(바꿈) · state_confirmed_unknown_before(보낸 뒤 목표값, 전 값 모름).
  final String? resultConfirmation;

  final String executionMode;

  final bool success;

  /// 실행 이름(가전·루틴·버튼). 모르면 빈 문자열이고, 그때는 "이름 — " 머리를 붙이지 않는다.
  final String label;

  /// 이 실행이 대상으로 삼은 가전. 모르면 null이고 지어내지 않는다.
  final ApplianceMap? target;

  /// 실패 원인 — 문구와 권하는 행동이 달라진다. null이면 일반 실행 실패.
  final KioskFailureReason? reason;

  /// 다시 보낼 요청이 있을 때만 있다(2026-10-15 B2) — 없으면 '다시 시도'를 그리지 않는다.
  final VoidCallback? onRetry;
  final VoidCallback? onManual;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    // 큰 글자(§1-8): 결과 원을 줄이고, 보조 단추(다시 시도·화면으로 조작하기)는 할 일 문장 아래 같은 세로 흐름으로
    // 옮긴다 — 가로 단추 줄이 두 줄로 접혀 할 일 줄을 스크롤 아래로 밀었다(2026-10-16 골든). '처음 화면으로'는 아래 고정.
    final large = KioskLayout.isLarge(context);
    // 누른 칸을 버튼판에 표시할 수 있나(화면 구조 개편 10/18) — 제안·실행과 같은 자리(오른쪽)·같은 폭.
    // 큰 글씨·LG 가전·기록 없음·자리를 못 찾은 이름이 있으면 지금처럼 가운데 글만.
    final pressedMap = large || route == 'thinq' || pressed == null
        ? null
        : KioskPanelPicture.pressedOf(
            this.target, [for (final b in pressed!) (b.button, b.success)]);
    final side = pressedMap != null;
    final ta = side ? TextAlign.start : TextAlign.center;
    final r = reason ?? KioskFailureReason.execution;
    // 사용자가 멈춘 것은 실패가 아니다 — 빨간 X가 아니라 정지 단계만큼의 표시(2026-10-14, 10-15).
    final userStop = !success && r == KioskFailureReason.stopped;
    final thinq = route == 'thinq';
    final mock = executionMode == 'mock';
    // 실행 환경을 판정보다 먼저 본다 — 모의 실행의 true는 모의 판정일 뿐(10/6 Copilot 리뷰 66990be),
    // 실물 모션이어도 L3 입력은 따로 모의일 수 있다(외부 평가 2026-10-13 M5) — 출처가 real일 때만 확인.
    final operationVerified =
        operationConfirmed == true && !mock && operationSource == 'real';
    // 큰 체크·성공색은 **확인한 성공**에만(2026-10-14 UI 정리): 실제 ThinQ 상태 재조회, 또는 실측 동작 확인.
    // 누름 완료(파랑)와 가전 상태 확인(초록)을 구분한다. 환경 미상은 앰버, 연습은 중립이다.
    final thinqVerified = thinq &&
        const {
          'state_confirmed',
          'state_confirmed_unknown_before',
          'already_at_target'
        }.contains(resultConfirmation);
    final verifiedSuccess = success &&
        executionMode == 'real' &&
        (thinqVerified || operationVerified);
    final pressCompleted = success &&
        !thinq &&
        executionMode == 'real' &&
        resultConfirmation != 'none';
    // 작은 팔이 멈춘 것을 확인한 정지(verified)만 흰색·체크(2026-10-15). 그 밖의 정지는 멈췄는지 모른다 — 주의색·물음표.
    final stopVerified = userStop && stopLevelConfirmed(stopLevel);
    // 확인 못 함은 실패가 아니다 — 빨강이 아니라 주의색으로 말한다.
    final color = verifiedSuccess
        ? KioskColors.confirmed
        : pressCompleted
            ? KioskColors.running
            : success
                ? (mock ? Colors.white : KioskColors.warning)
                : userStop
                    ? (stopVerified ? Colors.white : KioskColors.warning)
                    // 눌렸는지 모르는 것(execution)도 실패가 아니다 — 확인 필요(외부 평가 10/16 4차).
                    : r.isUnconfirmed || r == KioskFailureReason.execution
                        ? KioskColors.warning
                        : KioskColors.danger;
    final target = this.target;
    // 모션 걸림 등(2026-10-14) — '눌림을 확인하지 못해'로 원인을 바꿔 말하지 않는다.
    final motion = !success && r == KioskFailureReason.safetyStop
        ? motionAbortSentence(abortReason)
        : null;
    // 정지·모터 걸림은 원인을 이미 말했다 — "눌렸는지 확인 못 했어요" 같은 확인 칩을 덧붙이지 않는다.
    // 물리 성공도 제목과 아래 한 줄이 확인 수준을 말한다(2026-10-15) — 눌림을 확인하지 못한 경우(none)만 칩으로 남긴다.
    final physicalSuccessSaid =
        success && !thinq && resultConfirmation != 'none';
    final facts = [
      if (routeLabel(route) case final path?) path,
      if (confirmation case final c?
          when !userStop && motion == null && !physicalSuccessSaid)
        c,
    ];
    final already = thinq && resultConfirmation == 'already_at_target';
    // 실제 실행이면 작은 글자는 서버 문장(그 실행의 설정 이름)으로 확인한 사실만큼. 연습은 연습 문장을 지킨다.
    final outcome =
        thinq ? thinqOutcomeSentence(resultConfirmation, detail) : null;
    // 성공의 가장 큰 글자(2026-10-15 문구 개선 §2-1) — 확인한 것만큼. 물리 경로가 끝낸 것은 버튼 누르기이고,
    // 실행 환경을 모르면(옛 노드·UART가 보고하지 않음) 작은 팔이 보고한 사실까지만 말한다.
    final successHeadline = already
        ? '이미 그 설정이에요'
        : thinq
            // 모의 ThinQ는 모의 상태를 읽은 것이다(10/6 Copilot 리뷰 66990be).
            ? (mock
                ? '연습을 마쳤어요'
                : thinqVerified
                    ? '설정이 됐어요'
                    : '됐는지 몰라요')
            : mock
                ? '연습을 마쳤어요'
                : executionMode == 'real'
                    // 전력 변화(L3)를 본 것만 '가전이 켜졌어요'(쉬운 말 사전 10/17 — 전력 변화 확인 → 켜졌어요).
                    // 누름 보고만이면 '다 눌렀어요', 원하는 동작인지는 사람이 본다(아래 한 줄).
                    ? (operationVerified
                        ? '가전이 켜졌어요'
                        : pressCompleted
                            ? '다 눌렀어요'
                            : '눌렸는지 몰라요')
                    : '작은 팔이 다 눌렀다고 알려 왔어요';
    // 제목 바로 아래, 같은 크기 계열의 한 줄 — 가전은 사람이 본다. 확인한 것은 전력 변화(L3)이지 조리 시작이 아니다.
    // 연습은 위 띠가 '실제 가전은 움직이지 않아요'를 말한다 — 같은 말을 아래에 또 쓰지 않는다(10/18).
    final String? successSub = thinq || mock
        ? null
        : operationVerified
                ? '원하는 대로 됐는지 봐 주세요'
                : '가전이 켜졌는지 봐 주세요';
    // 판정 출처가 real일 때만 실제 동작을 확인했다고 말한다. 출처를 모르면 단정하지 않는다(폰과 같은 규칙).
    // 모의 출처는 아래 작은 글씨("연습 값이에요")가 같이 밝힌다. 물리 성공의 확인은 위 한 줄이 이미 말했다.
    final operationSentence = switch (operationConfirmed) {
      true when mock => '연습이라 가전은 보지 않았어요',
      true when operationSource == 'real' =>
        success && !thinq ? null : '가전이 켜졌어요',
      true => '켜졌는지 몰라요',
      false => '가전이 켜진 것은 못 봤어요',
      null => null,
    };
    final headline = success
        ? successHeadline
        : userStop
            ? stopLevelHeadline(stopLevel, ackMs: stopAckMs)
            : mock && !r.isUnconfirmed && motion == null
                ? '연습이 중간에 멈췄어요'
                : (motion ?? r.headline);
    // 연습 실패도 이유 한 줄(외부 평가 10/16 2차 k04). 실제 가전을 움직이지 않았다는 말은 위 띠가 한다(10/18).
    final String failureDetail = mock && !userStop
        ? r.practiceWhy
        : motion != null
            ? '다시 누르지 않았어요.\n가전과 작은 팔을 봐 주세요.'
            : userStop
                ? stopLevelNextStep(stopLevel)
                : r.detail(label, canRetry: onRetry != null);
    // 이름이 대상 가전 이름과 같으면(이어받은 실행 등) 같은 말을 두 번 쓰지 않는다.
    final showLabel = label.isNotEmpty && label != target?.name;
    // LG 가전 성공 아래 한 줄(확인한 사실만큼).
    final String thinqLine = outcome != null && (!mock || already)
        ? outcome
        : mock
            ? '실제 가전은 바꾸지 않았어요'
            : thinqVerified
                ? '가전에서 바뀐 설정을 봤어요'
                : '가전을 봐 주세요';
    // 위 상태 띠(2026-10-16 디자인 규격 §4) — 결과 아이콘·제목 색과 같은 규칙: 확인 필요 = 앰버, 실패 = 빨강,
    // 그 밖 = 중립, 연습이면 청록(실패·확인 필요와 겹쳐도 청록 연습 칸이 함께 남는다).
    // 띠 = 확인 수준, 제목 = 본 사실(화면 구조 개편 10/18) — 띠 말이 아래 제목·할 일에 또 나오면 다음 후보를 쓴다
    // (예: 제목 '설정이 됐어요'면 띠는 '됐어요' 대신 '확인했어요'). 확인 수준을 높여 말하는 후보는 두지 않는다.
    final visible = [
      headline,
      if (success && successSub != null) successSub,
      if (!success) failureDetail,
      if (showLabel) label,
      if (success && thinq) thinqLine,
      ...facts,
      if (operationSentence != null) operationSentence,
    ].map(_flat).join('|');
    String pick(List<String> words) => words.firstWhere(
        (w) => !visible.contains(_flat(w)),
        orElse: () => words.last);
    final KioskStatusBand band;
    if (color == KioskColors.warning) {
      band = KioskStatusBand(
          tone: KioskBandTone.attention,
          icon: Icons.help_outline,
          label: pick(const ['봐 주세요', '몰라요', '주의']),
          practice: mock);
    } else if (color == KioskColors.danger) {
      band = KioskStatusBand(
          tone: KioskBandTone.danger,
          icon: Icons.error_outline,
          label: pick(r == KioskFailureReason.serverLost
              ? const ['몰라요', '연결 끊김']
              : const ['못 했어요', '실패']),
          practice: mock);
    } else if (mock) {
      band = const KioskStatusBand.practice();
    } else if (verifiedSuccess) {
      // 전력(L3)으로 확인했으면 띠도 제목('전력 변화 확인')과 같은 수준으로 — ThinQ 상태 재조회만 '가전 상태 확인'
      // (외부 평가 10/16 3차).
      band = KioskStatusBand(
          tone: KioskBandTone.confirmed,
          icon: Icons.check,
          label: pick(const ['됐어요', '확인했어요']));
    } else if (success && executionMode == 'real') {
      band = KioskStatusBand(
          tone: KioskBandTone.attention,
          icon: Icons.help_outline,
          label: pick(const ['봐 주세요', '몰라요', '주의']));
    } else {
      band = const KioskStatusBand(
          tone: KioskBandTone.neutral, icon: Icons.flag_outlined, label: '결과');
    }
    // 확인 필요·실패(앰버·빨강 띠)에서는 주 단추를 골드가 아닌 중립 채움으로(10/18) — 골드 면은 '잘 됐으니 다음으로'처럼 읽혔다.
    final calmHome = band.tone == KioskBandTone.attention ||
        band.tone == KioskBandTone.danger;

    final content = Semantics(
      liveRegion: true,
      label: [
        if (mock) kPracticeBandText,
        if (success) ...[
          if (showLabel) label,
          successHeadline,
          if (successSub != null) successSub,
        ] else ...[
          if (showLabel) label,
          '$headline. $failureDetail',
        ],
        ...facts,
        if (operationSentence != null) operationSentence,
        if (runSteps.length > 1)
          for (var i = 0; i < runSteps.length; i++)
            '${_stepTitle(i, runSteps[i])}. ${runStepFacts(runSteps[i])}',
      ].join('. '),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            side ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          // 큰 글씨에서는 결과 원을 뺀다 — 위 상태 띠가 같은 아이콘·색으로 말하고, 남기면 이름 줄이 스크롤 아래로
          // 밀렸다(UI 평가 5차 10/17).
          if (!large && !side) _ResultRing(
            icon: verifiedSuccess || pressCompleted
                ? Icons.check
                : success
                    ? Icons.info_outline
                    : userStop
                        ? (stopVerified ? Icons.check : Icons.question_mark)
                        : r.isUnconfirmed || r == KioskFailureReason.execution
                            ? Icons.question_mark
                            : Icons.close,
            color: color,
            size: KioskSizes.resultIcon,
          ),
          if (!large && !side) const SizedBox(height: 12),
          // 가장 큰 글자가 그냥 '완료'면, 사용자는 조리나 냉방 자체가
          // 끝났다고 읽는다. 이 시스템이 끝낸 것은 **버튼 누르기**다.
          // 제목은 2줄까지 자연스럽게 넘어간다(폭은 [KioskSizes.resultMaxWidth], 2026-10-16 §1-7).
          KioskText(
            headline,
            textAlign: ta,
            style: TextStyle(
              fontSize: KioskType.key,
              fontWeight: FontWeight.w800,
              height: 1.2,
              color: color,
            ),
          ),
          // 실패·정지: 제목(본 사실) 바로 아래 할 일 한 가지를 크게(2차 평가 10/18 — '가전을 봐 주세요'가 큰 지시).
          // 흐린 글자로 두지 않는다(원칙 0-3). 무엇이었는지(가전·이름)는 그 아래 작게.
          if (!success) ...[
            const SizedBox(height: KioskSpace.xs),
            KioskText(
              failureDetail,
              textKey: const ValueKey('done-next-step'),
              textAlign: ta,
              style: const TextStyle(
                  fontSize: KioskType.status,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  height: 1.3),
            ),
          ],
          if (success && successSub != null) ...[
            const SizedBox(height: 8),
            // 할 일 한 줄 — 상태 크기(§1-3).
            KioskText(
              successSub,
              textKey: const ValueKey('done-sub'),
              textAlign: ta,
              style: const TextStyle(
                  fontSize: KioskType.status,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
          ],
          if (target != null) ...[
            const SizedBox(height: 10),
            KioskTargetLine(appliance: target),
          ],
          // 경로(ThinQ)와 확인 수준. 서버가 준 값만 말한다(물리 경로는 배지 없음).
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              facts.join(' · '),
              textAlign: ta,
              style: const TextStyle(
                  fontSize: KioskType.body, color: Colors.white),
            ),
          ],
          // 위 한 줄은 /status의 **마지막 단계** 기준이다. 두 가전을
          // 잇는 실행이면 단계마다 경로·확인 수준을 따로 말한다.
          if (runSteps.length > 1) _RunSteps(steps: runSteps),
          const SizedBox(height: 6),
          if (success) ...[
            // 무엇을 했는지 한 줄로 재확인한다.
            if (showLabel) ...[
              Text(
                label,
                textAlign: ta,
                style: const TextStyle(
                  fontSize: KioskType.body,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
            ],
            if (thinq)
              Text(
                thinqLine,
                textAlign: ta,
                style: const TextStyle(
                    fontSize: KioskType.body, color: KioskColors.muted),
              ),
          ] else ...[
            // 무엇이었는지 이름 한 줄(문장 앞에 '이름 — '를 붙이지 않는다, 쉬운 말 10/17).
            if (showLabel) ...[
              Text(
                label,
                key: const ValueKey('done-label'),
                textAlign: ta,
                style: const TextStyle(
                  fontSize: KioskType.body,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
            ],
            if (detail case final d? when d.isNotEmpty && !mock) ...[
              const SizedBox(height: 4),
              Text(
                d,
                textAlign: ta,
                style: const TextStyle(
                    fontSize: KioskType.caption, color: KioskColors.muted),
              ),
            ],
          ],
          _OperationLine(
            sentence: operationSentence,
            confirmed: operationVerified,
            source: mock ? null : operationSource,
            detail: operationDetail,
          ),
        ],
      ),
    );

    // 행동 단추는 스크롤 밖 아래에 고정한다(2026-10-15 B7) — 큰 글씨에서 '처음으로'가 화면 밖으로 밀렸다.
    // 큰 글자에서는 '처음 화면으로'만 고정하고 보조 단추는 할 일 아래로(§1-8 세로 1열).
    // 사용자가 직접 멈춘 결과에는 '다시 시도'를 두지 않는다 — 멈춘 사람에게 같은 무게의 다시 시도는 다시 누를 위험을
    // 키웠다(UI 평가 5차 10/17). 다시 하려면 처음 화면에서 고른다.
    final retry = userStop ? null : onRetry;
    final secondaryInFlow =
        large && !success && (retry != null || onManual != null);
    // 화면을 만지면 자동 복귀를 멈춘다(UI 평가 10/17) — 단추 동작은 그대로 지나간다(translucent).
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onHold?.call(),
      child: ColoredBox(
      color: KioskColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 상태 띠(연습이면 청록) — 스크롤해도 사라지지 않는다(§3-2, 2026-10-16 §4).
          band,
          if (side)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(KioskSizes.runLeft,
                    KioskSizes.runTop, KioskSizes.stopRight, KioskSpace.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: KioskScrollArea(child: content)),
                    const SizedBox(width: KioskSizes.stopGap),
                    SizedBox(
                      width: KioskPanelPicture.width,
                      child: KioskPanelPicture(
                        appliance: target,
                        caption: mock ? '연습으로 누른 자리예요' : '작은 팔이 누른 자리예요',
                        captionKey: const ValueKey('done-panel-caption'),
                        pressed: pressedMap,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
          Expanded(
            child: KioskScrollArea(
              center: true,
              padding: const EdgeInsets.fromLTRB(KioskSpace.xl, KioskSpace.sm, KioskSpace.xl, KioskSpace.xs),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: KioskSizes.resultMaxWidth),
                child: secondaryInFlow
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          content,
                          const SizedBox(height: 14),
                          _FailureActions(
                            key: const ValueKey('done-secondary-in-flow'),
                            onRetry: retry == null
                                ? null
                                : () => _confirmRetry(context, mock),
                            onManual: onManual,
                            onDismiss: null,
                          ),
                        ],
                      )
                    : content,
              ),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(24, 4, 24, KioskSizes.actionsBottom),
            child: Center(
              child: success
                  ? _SuccessActions(
                      onDismiss: onDismiss, held: autoReturnHeld, calm: calmHome)
                  : _FailureActions(
                      onRetry: secondaryInFlow || retry == null
                          ? null
                          : () => _confirmRetry(context, mock),
                      onManual: secondaryInFlow ? null : onManual,
                      onDismiss: onDismiss,
                      calm: calmHome,
                    ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

String _stepTitle(int i, ScenarioRunStep step) =>
    '${i + 1}. ${step.summary.isNotEmpty ? step.summary : '가전을 봐 주세요'}';

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
                          fontSize: KioskType.body,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        runStepFacts(steps[i]),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: KioskType.caption,
                            color: KioskColors.muted),
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
      if (source == 'mock') '연습 값이에요',
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
                  size: KioskType.body + 4, color: color),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  sentence,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: KioskType.body,
                      fontWeight: FontWeight.w600,
                      color: color),
                ),
              ),
            ],
          ),
          if (caption.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              caption,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: KioskType.caption, color: KioskColors.muted),
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

  /// 연습(모의) 실패의 이유 한 줄 — 실제로 누른 것이 아니라 연습 안에서 일어난 일이다.
  String get practiceWhy => switch (this) {
        KioskFailureReason.execution => '연습에서 눌렸는지 몰라요.',
        KioskFailureReason.safetyStop => '연습에서 눌렸는지 몰라서 멈췄어요.',
        KioskFailureReason.serverLost => '연습 결과를 받지 못했어요.',
        KioskFailureReason.stopped => '연습을 멈췄어요.',
        KioskFailureReason.unconfirmed => '연습 결과를 몰라요.',
        KioskFailureReason.receiptUnknown => '연습 명령이 닿았는지 몰라요.',
        KioskFailureReason.notExecuted => '연습을 하지 못했어요.',
      };

  /// 실패가 아니라 '확인 못 함'. 다시 보내면 중복 실행이 될 수 있다.
  bool get isUnconfirmed =>
      this == KioskFailureReason.unconfirmed ||
      this == KioskFailureReason.receiptUnknown;

  /// 가장 큰 글자(2026-10-15 문구 개선 §2-1) — 실패 화면의 주인공은 단추가 아니라 할 일이다.
  String get headline => switch (this) {
        KioskFailureReason.execution => '눌렸는지 몰라요',
        KioskFailureReason.serverLost => '어떻게 됐는지 몰라요',
        KioskFailureReason.stopped => stopLevelHeadline(null),
        KioskFailureReason.safetyStop => '눌렸는지 몰라서 멈췄어요',
        KioskFailureReason.unconfirmed => '보냈지만 됐는지 몰라요',
        KioskFailureReason.receiptUnknown => '가전이 받았는지 몰라요',
        KioskFailureReason.notExecuted => '가전을 바꾸지 못했어요',
      };

  /// 큰 글자 아래 할 일 한 줄(쉬운 말 10/17 — 결과 한 줄 + 할 일 한 줄). 이름은 화면이 따로 한 줄로 보인다.
  /// '다시 시도하지 마세요' 당부는 여기 두지 않는다 — 같은 경고는 화면에 한 번, '다시 시도' 확인 창에만 있다
  /// (열린 문제 R1). [label]·[canRetry]는 옛 호출을 위해 남긴다.
  String detail(String label, {bool canRetry = true}) => switch (this) {
        KioskFailureReason.execution => '가전을 봐 주세요.',
        KioskFailureReason.serverLost => '본체와 연결이 끊겼어요. 가전을 봐 주세요.',
        KioskFailureReason.stopped => stopLevelNextStep(null),
        KioskFailureReason.safetyStop => '가전을 봐 주세요.',
        KioskFailureReason.unconfirmed => '가전을 봐 주세요.',
        KioskFailureReason.receiptUnknown => '다시 보내기 전에 가전을 봐 주세요.',
        KioskFailureReason.notExecuted => '가전 연결을 봐 주세요.',
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
  const _ResultRing(
      {required this.icon, required this.color, required this.size});

  final IconData icon;
  final Color color;
  final double size;

  @override
  // 뜻을 전하는 것은 아이콘이 아니라 글자다 -- 원은 결과를 알리는 정도로만 둔다
  Widget build(BuildContext context) => Container(
        key: const ValueKey('done-ring'),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.14),
          border: Border.all(color: color.withValues(alpha: 0.45), width: 2),
        ),
        child: Icon(
          icon,
          size: size * 0.55,
          color: color,
        ),
      );
}

/// 성공 후 자동 복귀를 **글자로도** 말한다. 기다리기 싫은 사람의 길은 옆의 '처음 화면으로'.
class _AutoReturn extends StatelessWidget {
  const _AutoReturn();

  @override
  Widget build(BuildContext context) {
    // 큰 글씨면 두 배(kiosk_screen의 실제 전환과 같은 값, UI 평가 4차 10/17).
    final total = KioskLayout.isLarge(context) ? KioskTimings.doneReturnLarge : KioskTimings.doneReturn;
    return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: total.inSeconds.toDouble(), end: 0),
            duration: total,
            builder: (_, seconds, __) => Text(
              '${seconds.ceil()}초 뒤 처음 화면으로 돌아가요',
              style: const TextStyle(
                  fontSize: KioskType.caption, color: KioskColors.muted),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 220,
            height: 4,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 1.0, end: 0.0),
              duration: total,
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
        ],
    );
  }
}

/// 성공 화면 아래 줄 — 자동 복귀 안내(왼쪽) + '처음 화면으로'(주 단추).
class _SuccessActions extends StatelessWidget {
  const _SuccessActions(
      {required this.onDismiss, this.held = false, this.calm = false});

  final VoidCallback? onDismiss;
  final bool held;

  /// 앰버 띠(확인 필요) — 주 단추를 골드가 아닌 중립 채움으로.
  final bool calm;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: KioskSpace.lg,
        runSpacing: KioskSpace.xs,
        children: [
          held
              ? const Text('자동으로 닫지 않아요',
                  style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted))
              : const _AutoReturn(),
          if (onDismiss != null) _homeButton(onDismiss!, calm: calm),
        ],
      );
}

/// '처음 화면으로' — 결과 화면의 주 단추(화면당 채움 단추는 이것 하나, §1-5). 늘 같은 자리·같은 크기로 쉽게 닿는다.
/// 확인한 성공·중립 결과는 골드(주 행동색), 확인 필요·실패([calm])는 흰 면·검은 글자 중립 채움(10/18) —
/// 앰버·빨강 띠 아래 골드 면은 '잘 됐으니 다음으로'처럼 읽혔다.
Widget _homeButton(VoidCallback onTap, {bool calm = false}) => ElevatedButton.icon(
      key: const ValueKey('done-home'),
      onPressed: onTap,
      icon: const Icon(Icons.home_outlined, size: KioskType.status),
      label: const Text('처음 화면으로',
          style: TextStyle(
              fontSize: KioskType.status, fontWeight: FontWeight.w800)),
      style: KioskButtons.primary(
          background: calm ? KioskColors.neutralFill : KioskColors.primary,
          foreground: KioskColors.onAccent),
    );

/// 실패·정지 화면의 단추 — **주 하나 · 보조 하나 · 글자 하나**(2차 평가 10/18).
///
/// 화면의 주인공은 단추가 아니라 할 일 문장('가전을 봐 주세요')이다.
/// - 주: `처음 화면으로`(채움, 늘 쉽게 닿게 — 안전상 빠져나갈 길).
/// - 보조: `다시 시도`(테두리) — 가전 상태를 보지 않고 같은 버튼을 다시 누르기 때문에 덜 강조한다(열린 문제 R1).
///   다시 보낼 요청이 없으면(폰이 시작한 실행·놓친 결과 등, B2) 그리지 않는다.
/// - 글자: `화면으로 조작하기` — 글자 단추지만 누르는 자리는 48 이상.
class _FailureActions extends StatelessWidget {
  const _FailureActions({
    super.key,
    required this.onRetry,
    required this.onManual,
    required this.onDismiss,
    this.calm = false,
  });

  final VoidCallback? onRetry;
  final VoidCallback? onManual;
  final VoidCallback? onDismiss;
  final bool calm;

  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: KioskSpace.sm,
        runSpacing: KioskSpace.xs,
        children: [
          if (onDismiss != null) _homeButton(onDismiss!, calm: calm),
          if (onRetry != null)
            OutlinedButton.icon(
              key: const ValueKey('done-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: KioskType.body),
              label: const Text('다시 시도',
                  style: TextStyle(
                      fontSize: KioskType.body, fontWeight: FontWeight.w700)),
              style: KioskButtons.secondary(
                  foreground: Colors.white, border: KioskColors.muted),
            ),
          if (onManual != null)
            TextButton(
              key: const ValueKey('done-manual'),
              onPressed: onManual,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 48),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: KioskSpace.sm),
              ),
              child: const Text('화면으로 조작하기',
                  style: TextStyle(
                      fontSize: KioskType.body,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.white70)),
            ),
        ],
      );
}

/// 같은 말 비교용 — 빈칸·줄바꿈 묶음 문자를 빼고 본다.
String _flat(String s) => s.replaceAll(RegExp(r'[\s ⁠]'), '');
