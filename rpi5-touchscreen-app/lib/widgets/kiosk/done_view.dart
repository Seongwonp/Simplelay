import 'package:flutter/material.dart';

import '../../models/action_name.dart';
import '../../models/appliance.dart';
import '../../models/command_result.dart';
import '../../models/scenario_run.dart';
import '../../models/thinq_run.dart';
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
import 'step_trail.dart';

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
    this.stopPending = false,
    this.thinqOnly = false,
    this.thinqActionText,
  });

  /// LG 가전 명령 하나만 보낸 실행(사용자 요청 10/18) — 성공·확인 못 함은 가운데 결과 창 하나([thinqResultCopy]):
  /// 확인한 결과만 초록 체크, 확인 못 함은 체크 없이 '공기청정기에 켜기를 보냈어요'(평가 11차 10/18). 실패·정지는 종전 화면.
  final bool thinqOnly;

  /// 하려던 일을 알아볼 문장(명령 요약·고른 이름, [KioskExecutingView.thinqActionText]와 같은 값). 모르면 null.
  final String? thinqActionText;

  /// 정지로 끝난 실행의 확인 보고(stop_level)를 아직 기다리는 중(평가 8차 10/18) — 결과가 아니라 진행 상태로 보인다:
  /// '멈추는 중이에요', 처음 화면·보조 단추 없이 기다림 표시. 보고가 오거나 기다리기를 그만두면 화면이 false로 바꾼다.
  /// 정지(stopped)에만 쓴다.
  final bool stopPending;

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
                    child: const Text('네, 한 번 더 하기',
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

  /// LG 가전 결과 창의 말. 이 화면을 쓰지 않는 결과(실패·정지·물리 경로)면 null.
  ThinqResultCopy? get thinqCopy {
    if (!thinqOnly || route != 'thinq') return null;
    final r = reason;
    final kind = success
        ? ResultKind.success
        : (r?.isUnconfirmed ?? false)
            ? ResultKind.unconfirmed
            : null;
    if (kind == null) return null;
    return thinqResultCopy(
      applianceName: target?.name ?? '가전',
      kind: kind,
      receipt: r == KioskFailureReason.receiptUnknown ? 'unknown' : 'accepted',
      confirmation: resultConfirmation,
      detail: detail,
      executionMode: executionMode,
      action: thinqActionOf(target?.name ?? '가전', [thinqActionText, label]),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (thinqCopy case final copy?) {
      return _ThinqResult(
          copy: copy,
          target: this.target,
          success: success,
          held: autoReturnHeld,
          onHold: onHold,
          onClose: onDismiss);
    }
    // 큰 글자(§1-8): 결과 원을 줄이고, 보조 단추(다시 시도·화면으로 조작하기)는 할 일 문장 아래 같은 세로 흐름으로
    // 옮긴다 — 가로 단추 줄이 두 줄로 접혀 할 일 줄을 스크롤 아래로 밀었다(2026-10-16 골든). '처음 화면으로'는 아래 고정.
    final large = KioskLayout.isLarge(context);
    // 제목은 사람 명령문('즉석밥 데워줘')이 아니라 행동 이름('즉석밥 데우기') — 폰 기록과 같은 규칙(평가 4차 10/18).
    final label = actionName(this.label);
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
    // 정지 확인 보고를 기다리는 중 — 끝난 결과가 아니다(평가 8차 10/18).
    final pending = userStop && stopPending;
    // 연습 정지는 실제로 움직인 것이 없다 — 작은 팔이 멈췄는지 묻지 않는다(평가 8차 10/18).
    final practiceStop = userStop && !pending && executionMode == 'mock';
    final thinq = route == 'thinq';
    final mock = executionMode == 'mock';
    // 실행 환경을 판정보다 먼저 본다 — 모의 실행의 true는 모의 판정일 뿐(10/6 Copilot 리뷰 66990be),
    // 실물 모션이어도 L3 입력은 따로 모의일 수 있다(외부 평가 2026-10-13 M5) — 출처가 real일 때만 확인.
    final operationVerified =
        operationConfirmed == true && !mock && operationSource == 'real';
    // 큰 체크·성공색은 **확인한 성공**에만(2026-10-14 UI 정리): 실제 ThinQ 상태 재조회, 또는 실측 동작 확인.
    // 누름 완료(중립)와 가전 상태 확인(초록)을 구분한다. 환경 미상은 앰버, 연습은 중립이다.
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
            ? Colors.white // 누름 보고만은 중립색 — 진행색(파랑)은 확인처럼 읽혔다(평가 3차 10/18)
            : success
                ? (mock ? Colors.white : KioskColors.warning)
                : userStop
                    ? (stopVerified || pending || practiceStop ? Colors.white : KioskColors.warning)
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
                    // 띠가 '됐어요'라 제목은 본 사실로(같은 말 두 번 금지, 평가 3차 10/18).
                    ? '가전 설정을 확인했어요'
                    : '됐는지 몰라요')
            : mock
                ? '연습을 마쳤어요'
                : executionMode == 'real'
                    // 전력 변화(L3)를 본 것만 '가전이 켜졌어요'(쉬운 말 사전 10/17 — 전력 변화 확인 → 켜졌어요).
                    // 누름 보고만이면 '다 눌렀어요', 원하는 동작인지는 사람이 본다(아래 한 줄).
                    ? (operationVerified
                        ? '가전이 켜졌어요'
                        : pressCompleted
                            // 누름 보고만 — 버튼까지만 말한다. 가전은 사람이 본다(평가 3차 10/18).
                            ? '버튼은 다 눌렀어요'
                            : '눌렸는지 몰라요')
                    // 실행 환경을 모를 때도 같은 말 하나로(평가 4차 10/18 — '작은 팔이 다 눌렀다고 알려 왔어요'는 기계 말투).
                    // 확인 수준은 그대로다: 띠 '확인해 주세요'(앰버) + 아래 '가전이 움직이는지 봐 주세요'.
                    : '버튼은 다 눌렀어요';
    // 제목 바로 아래, 같은 크기 계열의 한 줄 — 가전은 사람이 본다. 확인한 것은 전력 변화(L3)이지 조리 시작이 아니다.
    // 연습은 위 띠가 '실제 가전은 움직이지 않아요'를 말한다 — 같은 말을 아래에 또 쓰지 않는다(10/18).
    final String? successSub = thinq || mock
        ? null
        : operationVerified
                ? '원하는 대로 됐는지 봐 주세요'
                // 폰·서버와 같은 말(평가 14차 10/18 — 폰 '버튼은 다 눌렀어요, 움직이는지 봐 주세요'). 제목이 '버튼은 다 눌렀어요'.
                : '가전이 움직이는지 봐 주세요';
    // 판정 출처가 real일 때만 실제 동작을 확인했다고 말한다. 출처를 모르면 단정하지 않는다(폰과 같은 규칙).
    // 모의 출처는 아래 작은 글씨("연습 값이에요")가 같이 밝힌다. 물리 성공의 확인은 위 한 줄이 이미 말했다.
    // 연습에는 두지 않는다 — '연습이라 가전은 보지 않았어요'는 위 연습 띠와 부딪혔다(평가 4차 10/18).
    final operationSentence = switch (operationConfirmed) {
      _ when mock => null,
      true when operationSource == 'real' =>
        success && !thinq ? null : '가전이 켜졌어요',
      true => '켜졌는지 몰라요',
      false => '가전이 켜진 것은 못 봤어요',
      null => null,
    };
    final headline = success
        ? successHeadline
        : pending
            ? kStopPendingHeadline
            : practiceStop
            ? kPracticeStopHeadline
            : userStop
            ? stopLevelHeadline(stopLevel, ackMs: stopAckMs)
            : mock && !r.isUnconfirmed && motion == null
                ? kPracticeStoppedHeadline
                : (motion ?? r.headline);
    // 연습 실패도 이유 한 줄(외부 평가 10/16 2차 k04). 실제 가전을 움직이지 않았다는 말은 위 띠가 한다(10/18).
    // 제목이 '연습이 중간에 멈췄어요'면 아래 줄을 두지 않는다 — '연습 누르기를 끝내지 못했어요'가 같은 말을 되풀이했다(평가 5차 10/18).
    final practiceStopped = headline == kPracticeStoppedHeadline;
    final String failureDetail = practiceStopped || practiceStop
        ? ''
        : pending
        ? '잠시 기다려 주세요'
        : mock && !userStop
        ? r.practiceWhy
        : motion != null
            // 큰 글자 줄은 마침표 없이(평가 8차 10/18).
            ? '다시 누르지 않았어요\n가전과 작은 팔을 봐 주세요'
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
    // 위 상태 띠(평가 3차 10/18) — 결과 띠 말은 **두 가지뿐**: '됐어요'(초록, 실제로 확인한 성공)와
    // '확인해 주세요'(그 밖의 모름·주의·실패 전부). 예전에는 봐 주세요·몰라요·주의·못 했어요·결과가 섞여 같은 뜻을
    // 다섯 말로 했다. 색은 뜻을 지킨다 — 실패·안전 정지는 빨강, 모름은 앰버, 연습은 청록(연습 칸은 늘 남는다).
    // 같은 말 두 번 금지는 제목을 바꿔 지킨다(띠 '확인해 주세요' / 제목 '눌렸는지 몰라요'). 확인 수준은 높이지 않는다.
    final KioskStatusBand band;
    if (pending) {
      // 아직 끝나지 않았다 — 결과 띠('확인해 주세요')가 아니라 진행 띠(평가 8차 10/18).
      // 띠는 무엇을 멈추는지(가전·할 일)만 — '멈추는 중'은 아래 큰 제목이 모래시계와 함께 한 번만 말한다(평가 10차 10/18).
      final what = [
        if (target != null) target.name,
        if (showLabel) label,
      ].join(' · ');
      band = KioskStatusBand(
          tone: KioskBandTone.neutral,
          icon: target?.icon ?? Icons.power_outlined,
          label: what.isEmpty ? '가전' : what,
          practice: mock);
    } else if (verifiedSuccess) {
      band = const KioskStatusBand(
          tone: KioskBandTone.confirmed, icon: Icons.check, label: kBandDone);
    } else if (mock &&
        color != KioskColors.warning &&
        color != KioskColors.danger) {
      band = const KioskStatusBand.practice();
    } else {
      final danger = color == KioskColors.danger;
      band = KioskStatusBand(
          tone: danger ? KioskBandTone.danger : KioskBandTone.attention,
          icon: danger ? Icons.error_outline : Icons.help_outline,
          label: kBandCheck,
          practice: mock);
    }

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
          failureDetail.isEmpty ? headline : '$headline. $failureDetail',
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
            icon: verifiedSuccess
                ? Icons.check
                : pressCompleted
                    ? Icons.touch_app_outlined
                    : success
                        // 확인 못 한 성공은 위 띠('?' 확인해 주세요)와 같은 물음표(평가 11차 10/18 — 띠 '?'·원 'i'가 달랐다).
                        // 연습은 띠가 연습 표시라 종전 그대로.
                        ? (mock ? Icons.info_outline : Icons.question_mark)
                        : pending
                            ? Icons.hourglass_top
                            : practiceStop
                            ? Icons.pan_tool_outlined
                            : userStop
                            ? (stopVerified ? Icons.check : Icons.question_mark)
                            : r.isUnconfirmed ||
                                    r == KioskFailureReason.execution
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
          if (!success && failureDetail.isNotEmpty) ...[
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
          // 실패·정지는 무엇이었는지를 가전·이름 한 줄로(평가 5차 10/18 — 제목 한 줄 + 할 일 한 줄 + 작은 한 줄).
          // 멈추는 중이면 위 띠가 가전·할 일을 말한다 — 같은 줄을 또 두지 않는다(평가 10차 10/18).
          if (target != null && !pending) ...[
            const SizedBox(height: 10),
            KioskTargetLine(
                appliance: target,
                detail: !success && showLabel ? label : null,
                textKey: const ValueKey('done-target')),
          ],
          // 경로(ThinQ)와 확인 수준. 서버가 준 값만 말한다(물리 경로는 배지 없음).
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 8),
            KioskText(
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
              KioskText(
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
              KioskText(
                thinqLine,
                textAlign: ta,
                style: const TextStyle(
                    fontSize: KioskType.body, color: KioskColors.muted),
              ),
          ] else ...[
            // 무엇이었는지 이름 한 줄(문장 앞에 '이름 — '를 붙이지 않는다, 쉬운 말 10/17). 대상 가전을 알면 위 가전 줄에 함께 있다.
            if (showLabel && target == null) ...[
              KioskText(
                label,
                textKey: const ValueKey('done-label'),
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
              KioskText(
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
    // 큰 글자에서는 세로 한 줄로 — 주 단추 '처음 화면으로'가 먼저(위), 보조 단추는 그 아래(평가 10차 10/18 — 보조 단추가
    // 할 일 아래 흐름에 있어 주 단추보다 위에 보였다).
    // 사용자가 직접 멈춘 결과에는 '다시 시도'를 두지 않는다 — 멈춘 사람에게 같은 무게의 다시 시도는 다시 누를 위험을
    // 키웠다(UI 평가 5차 10/17). 다시 하려면 처음 화면에서 고른다.
    final retry = userStop ? null : onRetry;
    final stacked = !pending && large && !success;
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
                    Expanded(
                      // 왼쪽 아래 빈자리에 누른 순서(평가 7차 10/18) — 버튼판의 ✓와 같은 뜻(작은 팔이 눌렀다고 알려 옴).
                      child: KioskStepTrail.worth(pressed!.length)
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: KioskScrollArea(child: content)),
                                const SizedBox(height: KioskSpace.sm),
                                KioskStepTrail(
                                  key: const ValueKey('done-step-trail'),
                                  title: mock ? '연습으로 누른 순서' : '누른 순서',
                                  steps: [
                                    for (final b in pressed!)
                                      (
                                        label: b.button,
                                        state: b.success
                                            ? KioskStepState.done
                                            : KioskStepState.unknown
                                      ),
                                  ],
                                ),
                              ],
                            )
                          : KioskScrollArea(child: content),
                    ),
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
                child: content,
              ),
            ),
          ),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(24, 4, 24, KioskSizes.actionsBottom),
            child: Center(
              child: pending
                  // 처음 화면·보조 단추 없이 기다림 표시만(평가 8차 10/18) — 정지 확인 보고는 몇 초 안에 오거나 끊긴다.
                  ? const SizedBox(
                      key: ValueKey('done-pending'),
                      height: KioskSizes.primaryButton,
                      child: Center(
                        child: SizedBox(
                            width: 40,
                            height: 40,
                            child: CircularProgressIndicator(
                                strokeWidth: 4, color: KioskColors.muted)),
                      ),
                    )
                  : success
                  ? _SuccessActions(onDismiss: onDismiss, held: autoReturnHeld)
                  : _FailureActions(
                      onRetry: retry == null
                          ? null
                          : () => _confirmRetry(context, mock),
                      onManual: onManual,
                      stacked: stacked,
                      onDismiss: onDismiss,
                      retryHint: !mock,
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
                      KioskText(
                        _stepTitle(i, steps[i]),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: KioskType.body,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      KioskText(
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
                child: KioskText(
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
            KioskText(
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

/// 연습 실패 제목 — 이 제목이면 아래 할 일 줄을 두지 않는다(같은 말 두 번 금지, 평가 5차 10/18).
const kPracticeStoppedHeadline = '연습이 중간에 멈췄어요';

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
        // 연습은 실제 가전을 누르지 않는다 — '눌렸는지 몰라요'는 연습 띠와 부딪혔다(평가 4차 10/18).
        KioskFailureReason.execution => '연습 누르기를 끝내지 못했어요',
        KioskFailureReason.safetyStop => '연습에서 다시 누르지 않고 멈췄어요',
        KioskFailureReason.serverLost => '연습 결과를 받지 못했어요',
        KioskFailureReason.stopped => kPracticeStopHeadline,
        KioskFailureReason.unconfirmed => '연습 결과를 몰라요',
        KioskFailureReason.receiptUnknown => '연습이 전해졌는지 몰라요',
        KioskFailureReason.notExecuted => '연습을 하지 못했어요',
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
  /// 큰 글자 줄이라 끝에 마침표를 두지 않는다(평가 8차 10/18 — 한 화면 안에서 이 줄만 마침표였다). 두 문장이면 가운데만.
  String detail(String label, {bool canRetry = true}) => switch (this) {
        KioskFailureReason.execution => '가전을 봐 주세요',
        KioskFailureReason.serverLost => '본체와 연결이 끊겼어요. 가전을 봐 주세요',
        KioskFailureReason.stopped => stopLevelNextStep(null),
        KioskFailureReason.safetyStop => '가전을 봐 주세요',
        KioskFailureReason.unconfirmed => '가전을 봐 주세요',
        KioskFailureReason.receiptUnknown => '다시 보내기 전에 가전을 봐 주세요',
        KioskFailureReason.notExecuted => '가전 연결을 봐 주세요',
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

/// LG 가전 결과(사용자 요청 10/18) — 다른 결과 화면과 같은 틀(평가 14차 10/18): 위 상태 띠 아래 왼쪽 선에서 큰 글자 ·
/// 한 줄 · (이름이 큰 글자에 없으면) 가전 줄, 아래 '처음 화면으로'. 테두리 상자·큰 결과 원은 없다 — 확인한 결과만 초록인
/// 것은 띠('됐어요'·초록 체크)와 큰 글자 색이 말한다. 띠 말은 다른 결과 화면과 같은 두 말('됐어요'·'확인해 주세요', 연습은 청록 띠).
/// 확인한 성공은 몇 초 뒤 처음 화면(화면을 만지면 멈춘다), 확인 못 함은 '처음 화면으로'를 누를 때까지 남는다
/// (사용자 결정 — 카운트다운 문구도 없다).
class _ThinqResult extends StatelessWidget {
  const _ThinqResult({
    required this.copy,
    required this.target,
    required this.success,
    required this.held,
    required this.onHold,
    required this.onClose,
  });

  final ThinqResultCopy copy;
  final ApplianceMap? target;
  final bool success;
  final bool held;
  final VoidCallback? onHold;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final (Color color, KioskStatusBand band) = switch (copy.tone) {
      ThinqResultTone.confirmed => (
          KioskColors.confirmed,
          const KioskStatusBand(tone: KioskBandTone.confirmed, icon: Icons.check, label: kBandDone),
        ),
      ThinqResultTone.attention => (
          KioskColors.warning,
          const KioskStatusBand(tone: KioskBandTone.attention, icon: Icons.help_outline, label: kBandCheck),
        ),
      ThinqResultTone.practice => (Colors.white, const KioskStatusBand.practice()),
    };
    final name = target?.name;
    // 큰 글자에 가전 이름이 없으면(바람 세기 결과 등) 아래 작게 무엇의 결과인지 — 다른 결과 화면과 같은 가전 줄(아이콘 + 이름).
    final showName = name != null && name.isNotEmpty && !copy.headline.contains(name) && !copy.sub.contains(name);
    // 다른 결과 화면(전자레인지 결과 kiosk15_done_verified)과 같은 틀 — 위 띠 아래 왼쪽 선에서 큰 글자 · 한 줄 · 가전 줄
    // (평가 14차 10/18: 띠 '됐어요' + 테두리 상자 + 큰 체크 원은 같은 뜻을 세 번 장식했다). 뜻은 띠의 아이콘·색과 글자가 말한다.
    final content = Semantics(
      liveRegion: true,
      label: [if (showName) name, copy.spoken].join('. '),
      excludeSemantics: true,
      child: Column(
        key: const ValueKey('thinq-result'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KioskText(
            copy.headline,
            textKey: const ValueKey('thinq-result-headline'),
            textAlign: TextAlign.start,
            style: TextStyle(fontSize: KioskType.key, fontWeight: FontWeight.w800, height: 1.2, color: color),
          ),
          const SizedBox(height: 8),
          KioskText(
            copy.sub,
            textKey: const ValueKey('thinq-result-sub'),
            textAlign: TextAlign.start,
            style: const TextStyle(
                fontSize: KioskType.status, fontWeight: FontWeight.w700, height: 1.3, color: Colors.white),
          ),
          if (showName && target != null) ...[
            const SizedBox(height: 10),
            KioskTargetLine(appliance: target!, textKey: const ValueKey('thinq-result-name')),
          ],
        ],
      ),
    );
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onHold?.call(),
      child: ColoredBox(
        color: KioskColors.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            band,
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    KioskSizes.runLeft, KioskSizes.runTop, KioskSizes.stopRight, KioskSpace.xs),
                child: KioskScrollArea(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: KioskSizes.resultMaxWidth),
                    child: content,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, KioskSizes.actionsBottom),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: KioskSpace.lg,
                runSpacing: KioskSpace.xs,
                children: [
                  if (success)
                    held
                        ? const Text('자동으로 닫지 않아요',
                            style: TextStyle(fontSize: KioskType.caption, color: KioskColors.muted))
                        : const _AutoReturn(),
                  // 나가는 단추는 다른 결과 화면과 같은 '⌂ 처음 화면으로'(평가 11차 10/18 — 여기만 '× 닫기'였다).
                  if (onClose != null) _homeButton(onClose!, key: const ValueKey('thinq-result-close')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
              maxLines: 1,
              softWrap: false,
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
  const _SuccessActions({required this.onDismiss, this.held = false});

  final VoidCallback? onDismiss;
  final bool held;

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
          if (onDismiss != null) _homeButton(onDismiss!),
        ],
      );
}

/// '처음 화면으로' — 모든 결과 화면의 나가는 단추(화면당 채움 단추는 이것 하나, §1-5). 늘 같은 자리·같은 크기로 쉽게 닿는다.
/// 이름·아이콘·색은 하나(평가 11차 10/18 — LG 가전 결과는 '× 닫기', 성공은 골드, 확인 필요는 흰색으로 화면마다 달랐다):
/// 흰 면·검은 글자 중립 채움. 골드 면은 앰버·빨강 띠 아래에서 '잘 됐으니 다음으로'처럼 읽혔다(10/18).
/// 연습 대기(hold_view)도 같은 단추를 쓴다(평가 12차 10/18).
Widget kioskHomeButton(VoidCallback onTap, {Key key = const ValueKey('done-home')}) => _homeButton(onTap, key: key);

Widget _homeButton(VoidCallback onTap, {Key key = const ValueKey('done-home')}) => ElevatedButton.icon(
      key: key,
      onPressed: onTap,
      icon: const Icon(Icons.home_outlined, size: KioskType.status),
      label: const Text('처음 화면으로',
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
              fontSize: KioskType.status, fontWeight: FontWeight.w800)),
      style: KioskButtons.primary(
          background: KioskColors.neutralFill, foreground: KioskColors.onAccent),
    );

/// 실패·정지 화면의 단추 — **주 출구 하나 + 보조 묶음**(평가 12차 10/18 — 같은 무게로 보이는 출구 셋이 많았다).
///
/// 화면의 주인공은 단추가 아니라 할 일 문장('가전을 봐 주세요')이다.
/// - 주: `처음 화면으로`(채움, 늘 쉽게 닿게 — 안전상 빠져나갈 길).
/// - 보조: `작은 팔로 골라 누르기`(테두리 + 아이콘) — 실패·사용자 정지 두 화면에서 같은 꼴(평가 12차 — 하나는 테두리, 하나는
///   글자 단추였다). 밑줄 글자는 링크로 읽혔다(평가 5차). '직접 누르기'는 같은 화면의 '가전 버튼을 직접 눌러 주세요'(손으로)와
///   헷갈렸다(평가 8차) — 누르는 것은 작은 팔이라는 말은 남긴다. 누르는 자리는 48 이상.
/// - `한 번 더 하기`(가장 약한 글자 단추) — 언제 다시 하는지 말하는 안내 문장 **바로 옆** 한 줄로 묶는다(평가 12차). 가전 상태를
///   보지 않고 같은 버튼을 다시 누르기 때문에 덜 강조한다(열린 문제 R1). 누르면 확인 창이 먼저 뜬다. 다시 보낼 요청이 없으면
///   (폰이 시작한 실행·놓친 결과·사용자 정지 등, B2) 그리지 않는다.
class _FailureActions extends StatelessWidget {
  const _FailureActions({
    required this.onRetry,
    required this.onManual,
    required this.onDismiss,
    this.retryHint = false,
    this.stacked = false,
  });

  /// 큰 글씨 — 주 단추 아래 보조 단추를 세로로(주 단추가 먼저).
  final bool stacked;

  final VoidCallback? onRetry;
  final VoidCallback? onManual;
  final VoidCallback? onDismiss;

  /// '한 번 더 하기' 옆 안내 문장을 둘까(실제 가전 실행). 연습은 실제 가전을 누르지 않아 두지 않는다.
  final bool retryHint;

  @override
  Widget build(BuildContext context) {
    final retry = onRetry;
    final buttons = <Widget>[
          if (onDismiss != null) _homeButton(onDismiss!),
          if (onManual != null)
            OutlinedButton.icon(
              key: const ValueKey('done-manual'),
              onPressed: onManual,
              icon: const Icon(Icons.touch_app_outlined, size: KioskType.body),
              label: const Text(kManualEntryLabel,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w600)),
              style: KioskButtons.secondary(foreground: Colors.white, border: KioskColors.border),
            ),
    ];
    final Widget main = stacked
        ? Column(
            key: const ValueKey('done-actions-stacked'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, b) in buttons.indexed) ...[
                if (i > 0) const SizedBox(height: KioskSpace.xs),
                b,
              ],
            ],
          )
        : Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: KioskSpace.sm,
            runSpacing: KioskSpace.xs,
            children: buttons,
          );
    if (retry == null) return main;
    // 안내 문장 + '한 번 더 하기'를 한 줄 묶음으로(평가 12차 10/18) — 따로 떨어진 세 번째 출구로 보이지 않게.
    // 켜기/끄기가 한 버튼인 가전은 두 번 누르면 도로 꺼질 수 있다. 다시 보내는 정책은 그대로(누르면 확인 창이 먼저).
    // 작은 테두리 보조 단추(평가 13차 10/18) — 회색 글자·테두리 없는 좁은 글자 단추는 꺼진 단추로 보였다. 글자는 흰색(바탕 위
    // 4.5:1 이상), 테두리는 옅게, 높이 48(실패널 약 98px), 글자는 '처음 화면으로'(채움·큰 글자)보다 작게 — 주 출구보다 약하다.
    final retryButton = OutlinedButton.icon(
      key: const ValueKey('done-retry'),
      onPressed: retry,
      icon: const Icon(Icons.refresh, size: KioskType.caption + 3),
      // '다시 시도'는 기계 말(평가 5차 10/18).
      label: const Text('한 번 더 하기',
          maxLines: 1,
          softWrap: false,
          style: TextStyle(fontSize: KioskType.caption + 1, fontWeight: FontWeight.w700)),
      style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          foregroundColor: Colors.white,
          side: const BorderSide(color: KioskColors.muted, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: KioskSpace.md),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KioskSizes.buttonRadius))),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        main,
        const SizedBox(height: KioskSpace.xs),
        Wrap(
          key: const ValueKey('done-retry-group'),
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          // 안내 문장과 단추를 뗀다(평가 13차 10/18 — 붙어 있어 단추가 문장 끝 말처럼 보였다).
          spacing: KioskSpace.lg,
          runSpacing: KioskSpace.xs,
          children: [
            if (retryHint)
              Row(
                key: const ValueKey('done-retry-hint'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.info_outline, size: KioskType.caption + 3, color: KioskColors.warning),
                  const SizedBox(width: 6),
                  Text(kRetryOnlyIfNot,
                      maxLines: 1,
                      softWrap: false,
                      style: const TextStyle(fontSize: KioskType.caption, color: Colors.white)),
                ],
              ),
            retryButton,
          ],
        ),
      ],
    );
  }
}

/// 결과 화면에서 버튼판(작은 팔이 누를 버튼을 고르는 화면)으로 가는 단추 이름(평가 8차 10/18).
/// 짧게(평가 12차 10/18) — 누르는 것은 작은 팔이라는 말은 남긴다(손으로 누르라는 말과 헷갈리지 않게, 평가 8차).
const kManualEntryLabel = '작은 팔로 골라 누르기';

/// '한 번 더 하기' 바로 위 한 줄(평가 7차 10/18).
const kRetryOnlyIfNot = '가전을 보고 안 됐을 때만 다시 하세요';



