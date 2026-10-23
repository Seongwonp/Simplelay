import 'package:flutter/material.dart';

import '../../models/action_name.dart';
import '../../models/appliance.dart';
import '../../models/command_result.dart';
import '../../models/josa.dart';
import '../../models/scenario_run.dart';
import '../../models/thinq_run.dart';
import '../../theme/kiosk_colors.dart';
import '../../theme/kiosk_tokens.dart';
import '../../services/kiosk_api_service.dart' show KioskButtonResult;
import 'appliance_art.dart';
import 'kiosk_scroll_area.dart';
import 'panel_picture.dart';
import 'kiosk_text.dart';
import 'kiosk_timings.dart';
import 'practice_band.dart';
import 'run_frame.dart' show KioskStopButton;
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
    this.autoReturnSeconds,
    this.onHold,
    this.pressed,
    this.stopPending = false,
    this.thinqOnly = false,
    this.thinqActionText,
    this.onStopAgain,
    this.stopAgain,
    this.onChecked,
    this.onRetryAfterCheck,
    this.onContinue,
    this.onPickOther,
    this.continueName,
  });

  /// 직접 고른 가전에서 시작한 실행의 '이 가전 계속 조작'(R7 연속 조작, 2026-10-24) — 같은 조작판으로 돌아가기만 한다.
  /// 있으면 확인한 성공의 주 단추가 되고 자동 복귀 말은 그리지 않는다(화면이 처음 화면으로 보내지 않는다). null이면 종전.
  final VoidCallback? onContinue;

  /// '다른 가전 고르기'(보조) — [onContinue]와 함께 온다.
  final VoidCallback? onPickOther;

  /// 계속 조작할 가전 이름. 비면 '이 가전'.
  final String? continueName;

  /// '가전을 보고 알려 주세요'에 사람이 답했다(휴리스틱 평가 10/18) — true '바뀌었어요·켜졌어요', false '안 …' 뒤
  /// '손으로 할게요'. 화면(kiosk_screen)이 키오스크 안에 사람 확인으로 기억하고 처음 화면으로 간다('지난 일' 줄은 남기지
  /// 않는다 — 사람이 이미 답했다). null이면(시험·옛 호출) 두 답 모두 [onDismiss]로 나간다.
  final ValueChanged<bool>? onChecked;

  /// 사람이 '안 바뀌었어요·안 켜졌어요'라고 답한 뒤의 '한 번 더 하기'(확인 창을 거친다). null이면 [onRetry]를 쓴다 —
  /// LG 가전 확인 못 함처럼 답 없이는 다시 보내지 않는 결과에서, 사람이 바뀌지 않았다고 본 뒤에만 연다.
  final VoidCallback? onRetryAfterCheck;

  /// 누름 장치가 멈췄는지 모르는 정지 결과의 '다시 멈추기'(평가 15차 10/18) — 정지 대기 화면과 같은 정지 경로(/stop)를 다시 보낸다.
  /// null이면(연습·LG 가전·다시 보낼 수 없음) 단추를 두지 않는다. 이 결과에는 '누름 장치로 골라 누르기'를 두지 않는다(안전).
  final VoidCallback? onStopAgain;

  /// '다시 멈추기'를 누른 결과 — 'sent'(본체가 받음) | 'failed'(닿지 않음) | null(아직 안 누름).
  final String? stopAgain;

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

  /// 처음 화면으로 돌아가기까지 남은 초(kiosk_screen이 1초마다 센다, 접근성 감사 10/18). null이면(시험·옛 호출) 전체 길이.
  final int? autoReturnSeconds;

  /// 화면을 만지면 부른다(성공 화면의 자동 복귀 멈춤). 단추를 누를 때도 불리지만 단추 동작은 그대로다.
  final VoidCallback? onHold;

  /// 누름 장치가 누른 버튼 기록(이름·보고 결과). 버튼판에서 모두 자리를 찾으면 오른쪽 그림에 누른 칸을 표시한다
  /// (화면 구조 개편 10/18). 모르면 null — 지금처럼 가운데 글만.
  final List<KioskButtonResult>? pressed;

  /// 모션 걸림·재시작 등으로 재시도 없이 멈춘 원인(2026-10-14, /status last_abort_reason). 안전 정지에만 쓴다.
  final String? abortReason;

  /// 정지로 멈춘 실행의 확인 단계(2026-10-13, /status last_stop_level): sent | mcu_ack | verified.
  /// null이면 정지 줄을 그리지 않는다(옛 서버·로컬 모의). 정지로 멈춘 실행(stopped)에만 쓴다.
  final String? stopLevel;
  final int? stopAckMs;

  Future<void> _confirmRetry(BuildContext context, bool mock) =>
      confirmKioskRetry(context, mock: mock, thinq: route == 'thinq', toggle: retryMayToggle, onRetry: onRetry);

  /// '한 번 더 하기'가 켜고 끄는 한 버튼(서버 버튼 데이터 behavior=toggle)을 다시 누를 수 있나(접근성 감사 10/18) — 그러면
  /// 확인 창에 '이미 켜졌다면 다시 누르면 꺼질 수 있어요'. 누른 버튼 기록이 있으면 그 버튼들로, 없으면(어느 버튼인지 모름)
  /// 이 가전 버튼판에 토글 버튼이 하나라도 있으면 그렇다고 본다(안전한 쪽). 성질을 모르는 버튼(unknown)·버튼판에서 찾지
  /// 못한 버튼도 토글과 같이 본다(검토 10/19 #5 — 두 번 누르면 되돌아갈 수 있다). 되풀이해도 같은 버튼(idempotent)만이면 false.
  bool get retryMayToggle {
    final a = target;
    if (a == null || route == 'thinq') return false;
    final pressed = this.pressed;
    if (pressed == null || pressed.isEmpty) return a.buttons.any((b) => b.mayUndoOnRepeat);
    return pressed.any((p) {
      final b = a.buttons.where((b) => b.label == p.button).firstOrNull;
      return b == null || b.mayUndoOnRepeat;
    });
  }

  /// 사람 확인 흐름(휴리스틱 평가 10/18) — 사람이 가전을 보고 답할 결과면 그 말. 아니면 null.
  ///
  /// 눌렸는지 모름·LG 가전 확인 못 함·본체 끊김(어떻게 됐는지 모름)·버튼 누름 보고만(가전은 사람이 본다) — 주 행동이
  /// '처음 화면으로'면 어르신이 해결 없이 나가 결과를 잃었다. 대신 '바뀌었어요 / 안 바뀌었어요' 두 개의 대등한 큰 단추.
  /// '한 번 더 하기'는 '안 …'이라고 답한 뒤에만, 확인 창을 거쳐서(열린 문제 R1 — 다시 누르기를 가장 쉬운 행동으로 두지 않는다).
  /// 연습·확인한 성공·사용자 정지(정지가 주인공)·원인을 아는 걸림에는 없다.
  KioskCheckWords? get personCheck {
    if (executionMode == 'mock') return null;
    final name = target?.displayName;
    if (thinqCopy case final copy?) {
      return copy.tone == ThinqResultTone.attention ? _thinqCheckWords(name) : null;
    }
    final r = reason ?? KioskFailureReason.execution;
    if (!success && r == KioskFailureReason.stopped) return null;
    if (route == 'thinq') {
      return _thinqUnconfirmed || (!success && r == KioskFailureReason.serverLost) ? _thinqCheckWords(name) : null;
    }
    if (success) {
      final verified = executionMode == 'real' && operationConfirmed == true && operationSource == 'real';
      return verified ? null : KioskCheckWords.moved(name);
    }
    if (_pressUnknown || r == KioskFailureReason.serverLost) return KioskCheckWords.moved(name);
    return null;
  }

  KioskCheckWords _thinqCheckWords(String? name) {
    final action = thinqActionOf(name ?? '가전', [thinqActionText, label]);
    return switch (action.kind) {
      ThinqActionKind.powerOn => KioskCheckWords.on(name),
      ThinqActionKind.powerOff => KioskCheckWords.off(name),
      _ => KioskCheckWords.changed(name),
    };
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
      applianceName: target?.displayName ?? '가전',
      kind: kind,
      receipt: r == KioskFailureReason.receiptUnknown ? 'unknown' : 'accepted',
      confirmation: resultConfirmation,
      detail: detail,
      executionMode: executionMode,
      action: thinqActionOf(target?.displayName ?? '가전', [thinqActionText, label]),
    );
  }

  /// 실제 LG 가전에 보낸 결과를 확인하지 못했나(성공으로 왔지만 상태를 못 본 것 포함). 연습은 아니다.
  bool get _thinqUnconfirmed {
    if (executionMode == 'mock' || route != 'thinq') return false;
    // LG 가전 결과 창이면 그 창의 판정(확인한 실제 성공만 초록)을 따른다.
    if (thinqCopy case final copy?) return copy.tone == ThinqResultTone.attention;
    // 그 밖은 이 화면의 큰 글자와 같은 기준 — 상태를 본 근거가 없으면 '됐는지 확인하지 못했어요'.
    if (success) return !_thinqStateSeen;
    return reason?.isUnconfirmed ?? false;
  }

  bool get _thinqStateSeen => const {
        'state_confirmed',
        'state_confirmed_unknown_before',
        'already_at_target'
      }.contains(resultConfirmation);

  /// 누름 장치로 눌렀는데 눌렸는지 모르나(실제 실행). 사용자 정지·누름 장치 걸림(원인을 아는 정지)·본체 끊김은 아니다.
  bool get _pressUnknown {
    if (executionMode == 'mock' || route == 'thinq') return false;
    if (success) return executionMode == 'real' && resultConfirmation == 'none';
    final r = reason ?? KioskFailureReason.execution;
    return r == KioskFailureReason.execution ||
        (r == KioskFailureReason.safetyStop && motionAbortSentence(abortReason) == null);
  }

  /// 사용자가 멈췄는데 누름 장치가 멈춘 것을 확인하지 못했나(실제 실행·누름 장치 경로, 보고 기다림이 끝난 뒤, 평가 15차 10/18).
  bool get _stopUnknown {
    if (success || executionMode == 'mock' || route == 'thinq' || stopPending) return false;
    if ((reason ?? KioskFailureReason.execution) != KioskFailureReason.stopped) return false;
    return !stopLevelConfirmed(stopLevel);
  }

  /// '확인 못 함' 결과의 순서 안내(사용자 결정 10/18) — LG 가전 확인 못 함·누름 장치 눌렸는지 모름·누름 장치가 멈췄는지 모름
  /// (평가 15차 10/18). 그 밖은 null. 자동으로 다시 하지 않는다 — '한 번 더 하기'는 종전 정책 그대로다.
  List<String>? get recoverySteps => _thinqUnconfirmed
      ? kThinqRecoverySteps
      : _pressUnknown
          ? kPressRecoverySteps
          : _stopUnknown
              ? kStopUnknownSteps
              : null;

  /// 결과 화면을 닫은 뒤 처음 화면에 남길 큰 글자(사용자 결정 10/18) — 실패·'확인 못 함'만. 성공·연습·확인한 정지·
  /// 정지 보고를 기다리는 중이면 null. 글은 이 화면의 큰 글자와 같다.
  String? get pastHeadline {
    if (executionMode == 'mock') return null;
    if (thinqCopy case final copy?) {
      return copy.tone == ThinqResultTone.attention ? copy.headline : null;
    }
    if (success) {
      if (_thinqUnconfirmed) return '됐는지 확인하지 못했어요'; // 이 화면의 LG 가전 성공 큰 글자와 같은 말
      if (_pressUnknown) return '눌렸는지 확인하지 못했어요';
      // 버튼 누름 보고만 — 가전은 사람이 본다(2차 독립 평가 C, 10/18). 답하지 않고 나가면 처음 화면에 남긴다.
      if (personCheck != null) return kPressDonePastHeadline;
      return null;
    }
    final r = reason ?? KioskFailureReason.execution;
    if (r == KioskFailureReason.stopped) {
      if (stopPending) return null;
      return stopLevelConfirmed(stopLevel) ? null : stopLevelHeadline(stopLevel);
    }
    final motion = r == KioskFailureReason.safetyStop ? motionAbortSentence(abortReason) : null;
    return motion ?? r.headline;
  }

  @override
  Widget build(BuildContext context) {
    if (thinqCopy case final copy?) {
      return _ThinqResult(
          copy: copy,
          target: this.target,
          success: success,
          held: autoReturnHeld,
          autoReturnSeconds: autoReturnSeconds,
          onHold: onHold,
          onClose: onDismiss,
          steps: recoverySteps,
          check: personCheck,
          onChecked: onChecked,
          onRetryAfterCheck: onRetryAfterCheck,
          onContinue: onContinue,
          onPickOther: onPickOther,
          continueName: continueName,
          mock: executionMode == 'mock');
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
    // 모든 결과 화면 한 틀(평가 17차 10/18): 띠 → 제목(사실) → 부제(행동 하나) → 가전 줄 → 아래 '처음 화면으로', 왼쪽 정렬.
    // 큰 결과 원은 두지 않는다 — 결과마다 있고 없고가 달랐다. 뜻은 띠의 아이콘·색과 제목 글자가 말한다.
    const ta = TextAlign.start;
    final r = reason ?? KioskFailureReason.execution;
    final steps = recoverySteps;
    final check = personCheck;
    // 사용자가 멈춘 것은 실패가 아니다 — 빨간 X가 아니라 정지 단계만큼의 표시(2026-10-14, 10-15).
    final userStop = !success && r == KioskFailureReason.stopped;
    // 정지 확인 보고를 기다리는 중 — 끝난 결과가 아니다(평가 8차 10/18).
    final pending = userStop && stopPending;
    // 연습 정지는 실제로 움직인 것이 없다 — 누름 장치가 멈췄는지 묻지 않는다(평가 8차 10/18).
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
    // 누름 장치가 멈춘 것을 확인한 정지(verified)만 흰색·체크(2026-10-15). 그 밖의 정지는 멈췄는지 모른다 — 주의색·물음표.
    final stopVerified = userStop && stopLevelConfirmed(stopLevel);
    // 확인 못 함은 실패가 아니다 — 빨강이 아니라 주의색으로 말한다.
    final baseColor = verifiedSuccess
        ? KioskColors.confirmed
        : pressCompleted
            // 누름 보고만도 '확인 필요' 결과 — 띠('확인해 주세요', 앰버)와 같은 앰버 제목(접근성 감사 10/18: 같은 확인 필요 상태가
            // 흰 제목·노란 제목 둘이었다). 진행색(파랑)·초록은 쓰지 않는다(확인처럼 읽혔다, 평가 3차 10/18).
            ? KioskColors.warning
            : success
                ? (mock ? KioskColors.ink : KioskColors.warning)
                : userStop
                    ? (stopVerified || pending || practiceStop ? KioskColors.ink : KioskColors.warning)
                    // 눌렸는지 모르는 것(execution)도 실패가 아니다 — 확인 필요(외부 평가 10/16 4차).
                    : r.isUnconfirmed || r == KioskFailureReason.execution
                        ? KioskColors.warning
                        : KioskColors.danger;
    // 연습의 확인 필요는 앰버가 아니라 연습 색(청록, 출시 검토 10/18) — 실제 가전은 그대로이니 사람이 확인할 일이 아니다.
    // 실패(빨강)는 그대로 둔다.
    final color = mock && baseColor == KioskColors.warning ? KioskColors.practice : baseColor;
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
    // 실행 환경을 모르면(옛 노드·UART가 보고하지 않음) 누름 장치가 보고한 사실까지만 말한다.
    final successHeadline = already
        ? '이미 그 설정이에요'
        : thinq
            // 모의 ThinQ는 모의 상태를 읽은 것이다(10/6 Copilot 리뷰 66990be).
            ? (mock
                ? '연습을 마쳤어요'
                : thinqVerified
                    // 띠가 '됐어요'라 제목은 본 사실로(같은 말 두 번 금지, 평가 3차 10/18).
                    ? '가전 설정을 확인했어요'
                    : '됐는지 확인하지 못했어요')
            : mock
                ? '연습을 마쳤어요'
                : executionMode == 'real'
                    // 전력 변화(L3 실측)를 본 것만 '<가전 이름>이 켜졌어요'(쉬운 말 사전 10/17 — 전력 변화 확인 → 켜졌어요,
                    // 10/18 §3-5 — 어느 가전인지 이름으로). 누름 보고·누름 센서(L1)·엔코더만이면 '다 눌렀어요', 원하는 동작인지는
                    // 사람이 본다(아래 한 줄).
                    ? (operationVerified
                        ? '${withSubject(target?.displayName ?? '가전')} 켜졌어요'
                        : pressCompleted
                            // 누름 보고만 — 버튼까지만 말한다. 가전은 사람이 본다(평가 3차 10/18).
                            ? '버튼은 다 눌렀어요'
                            : '눌렸는지 확인하지 못했어요')
                    // 실행 환경을 모를 때도 같은 말 하나로(평가 4차 10/18 — '누름 장치가 다 눌렀다고 알려 왔어요'는 기계 말투).
                    // 확인 수준은 그대로다: 띠 '확인해 주세요'(앰버) + 아래 '가전이 움직이는지 봐 주세요'.
                    : '버튼은 다 눌렀어요';
    // 제목 바로 아래, 같은 크기 계열의 한 줄 — 가전은 사람이 본다. 확인한 것은 전력 변화(L3)이지 조리 시작이 아니다.
    // 연습은 위 띠가 '실제 가전은 움직이지 않아요'를 말한다 — 같은 말을 아래에 또 쓰지 않는다(10/18).
    // 사람 확인 흐름(휴리스틱 평가 10/18)이어도 이 할 일 줄은 남긴다(폰과 같은 말) — 아래 물음은 '전자레인지 화면·불빛·소리가 바뀌었나요?'만.
    final String? successSub = thinq || mock || steps != null
        ? null
        : operationVerified
                ? '원하는 대로 됐는지 봐 주세요'
                // 폰·서버와 같은 말(평가 14차 10/18 — 폰 '버튼은 다 눌렀어요, 움직이는지 봐 주세요'). 제목이 '버튼은 다 눌렀어요'.
                : '가전이 움직이는지 봐 주세요';
    // 제목 바로 아래 근거 한 줄(결선 모의 평가 10/18) — 전력 실측으로 확인한 성공에만.
    final String? evidence = success && !thinq && !mock && operationVerified ? kDoneEvidencePower : null;
    // 판정 출처가 real일 때만 실제 동작을 확인했다고 말한다. 출처를 모르면 단정하지 않는다(폰과 같은 규칙).
    // 모의 출처는 아래 작은 글씨("연습 값이에요")가 같이 밝힌다. 물리 성공의 확인은 위 한 줄이 이미 말했다.
    // 연습에는 두지 않는다 — '연습이라 가전은 보지 않았어요'는 위 연습 띠와 부딪혔다(평가 4차 10/18).
    final operationSentence = switch (operationConfirmed) {
      _ when mock => null,
      true when operationSource == 'real' =>
        success && !thinq ? null : '가전이 켜졌어요',
      true => '켜졌는지 확인하지 못했어요',
      false => '가전이 켜졌는지 확인하지 못했어요',
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
    // 순서 안내가 있으면 할 일 한 줄('가전을 봐 주세요')을 따로 두지 않는다 — 같은 뜻을 띠·큰 글자·할 일·번호로 네 번
    // 말했다(평가 15차 10/18). 할 일은 번호 안내가 한 번만 말한다.
    final String failureDetail = practiceStopped || practiceStop || steps != null
        ? ''
        : pending
        // 무엇을 기다리는지(휴리스틱 평가 10/18 — '잠시 기다려 주세요'만으로는 빈 화면처럼 보였다).
        ? kStopPendingDetail
        : mock && !userStop
        ? r.practiceWhy
        : motion != null
            // 큰 글자 줄은 마침표 없이(평가 8차 10/18).
            ? '다시 누르지 않았어요\n가전과 누름 장치를 봐 주세요'
            : userStop
                ? stopLevelNextStep(stopLevel)
                : r.detail(label, canRetry: onRetry != null);
    // 이름이 대상 가전 이름과 같으면(이어받은 실행 등) 같은 말을 두 번 쓰지 않는다.
    final showLabel = label.isNotEmpty && label != target?.displayName;
    // LG 가전 성공 아래 한 줄(확인한 사실만큼).
    final String thinqLine = outcome != null && (!mock || already)
        ? outcome
        : mock
            ? '실제 가전은 바꾸지 않았어요'
            : thinqVerified
                ? '가전에서 설정 변경을 확인했어요'
                : '가전을 봐 주세요';
    // 위 상태 띠(평가 3차 10/18) — 결과 띠 말은 **두 가지뿐**: '됐어요'(초록, 실제로 확인한 성공)와
    // '확인해 주세요'(그 밖의 모름·주의·실패 전부). 예전에는 봐 주세요·확인하지 못했어요·주의·못 했어요·결과가 섞여 같은 뜻을
    // 다섯 말로 했다. 색은 뜻을 지킨다 — 실패·안전 정지는 빨강, 모름은 앰버, 연습은 청록(연습 칸은 늘 남는다).
    // 같은 말 두 번 금지는 제목을 바꿔 지킨다(띠 '확인해 주세요' / 제목 '눌렸는지 확인하지 못했어요'). 확인 수준은 높이지 않는다.
    // 결과 띠는 늘 무엇이었는지(가전 · 할 일)를 오른쪽에 함께 말한다(평가 17차 10/18) — 본문의 가전·이름 줄은 두지 않는다.
    final bandWhat = [
      if (target != null) target.displayName,
      if (showLabel) label,
    ].join(' · ');
    final String? bandDetail = bandWhat.isEmpty ? null : bandWhat;
    final KioskStatusBand band;
    if (pending) {
      // 아직 끝나지 않았다 — 결과 띠('확인해 주세요')가 아니라 진행 띠(평가 8차 10/18).
      // 띠는 무엇을 멈추는지(가전·할 일)만 — '멈추는 중'은 아래 큰 제목이 모래시계와 함께 한 번만 말한다(평가 10차 10/18).
      final what = [
        if (target != null) target.displayName,
        if (showLabel) label,
      ].join(' · ');
      // 띠는 '멈추는 중' + 무엇을(평가 17차 10/18) — 아래 왼쪽의 돌아가는 원은 두지 않는다(같은 뜻 두 번).
      band = KioskStatusBand(
          tone: KioskBandTone.neutral,
          icon: Icons.hourglass_top,
          label: '멈추는 중',
          detail: what.isEmpty ? null : what,
          detailIcon: target?.icon,
          practice: mock);
    } else if (verifiedSuccess) {
      band = KioskStatusBand(
          tone: KioskBandTone.confirmed, icon: Icons.check, label: kBandDone,
          detail: bandDetail, detailIcon: target?.icon);
    } else if (mock &&
        color != KioskColors.warning &&
        color != KioskColors.danger) {
      // 연습의 확인 필요(실패)는 청록 띠에 짧은 '연습' + 가전 줄 한 줄(출시 검토 10/18) — 실제 가전이 그대로라는 말은 본문.
      band = KioskStatusBand.practice(
          detail: bandDetail,
          detailIcon: target?.icon,
          practiceShort: !success && !userStop && bandDetail != null);
    } else {
      final danger = color == KioskColors.danger;
      final what = bandDetail;
      band = KioskStatusBand(
          tone: danger ? KioskBandTone.danger : KioskBandTone.attention,
          icon: danger ? Icons.error_outline : Icons.help_outline,
          label: kBandCheck,
          practice: mock,
          detail: what == null || what.isEmpty ? null : what,
          detailIcon: what == null || what.isEmpty ? null : target?.icon);
    }
    // 연습이 다른 띠(확인 필요·실패)와 겹치고 가전 줄까지 있으면 띠의 연습 표시는 짧은 '연습'([KioskStatusBand]) — 그때 본문이
    // '실제 가전은 그대로예요'를 말한다. 멈추는 중(pending)은 아래 기다림 말이 먼저라 두지 않는다.
    final practiceInBand = mock &&
        (band.tone != KioskBandTone.practice || band.practiceShort) &&
        (band.detail?.isNotEmpty ?? false);

    final content = Semantics(
      liveRegion: true,
      label: [
        if (mock) kPracticeBandText,
        if (success) ...[
          if (showLabel) label,
          successHeadline,
          if (evidence != null) evidence,
          if (successSub != null) successSub,
        ] else ...[
          if (showLabel) label,
          failureDetail.isEmpty ? headline : '$headline. $failureDetail',
        ],
        ...facts,
        if (operationSentence != null) operationSentence,
        if (steps != null) recoveryStepsSpoken(steps),
        if (runSteps.length > 1)
          for (var i = 0; i < runSteps.length; i++)
            '${_stepTitle(i, runSteps[i])}. ${runStepFacts(runSteps[i])}',
      ].join('. '),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 가장 큰 글자가 그냥 '완료'면, 사용자는 조리나 냉방 자체가
          // 끝났다고 읽는다. 이 시스템이 끝낸 것은 **버튼 누르기**다.
          // 제목은 2줄까지 자연스럽게 넘어간다(폭은 [KioskSizes.resultMaxWidth], 2026-10-16 §1-7).
          if (pending)
            // 멈추는 중 — 돌아가는 표시를 제목 왼쪽에(휴리스틱 평가 10/18 — 진행 표시 없이 글만 있어 멈춘 화면처럼 보였다).
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  key: ValueKey('done-pending-spinner'),
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 5, color: KioskColors.ink),
                ),
                const SizedBox(width: KioskSpace.md),
                Flexible(
                  child: KioskText(
                    headline,
                    textAlign: ta,
                    style: TextStyle(
                        fontSize: KioskType.key, fontWeight: FontWeight.w800, height: 1.2, color: color),
                  ),
                ),
              ],
            )
          else
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
              style: TextStyle(
                  fontSize: KioskType.status,
                  fontWeight: FontWeight.w700,
                  color: KioskColors.ink,
                  height: 1.3),
            ),
          ],
          // 연습이 확인 필요·실패 띠와 겹치면 띠의 연습 표시는 짧은 '연습'이다(결선 모의 평가 10/18) — 실제 가전이 그대로라는
          // 말은 본문 한 줄로(띠가 하던 말, 같은 말 두 번이 아니다).
          if (practiceInBand && !pending) ...[
            const SizedBox(height: KioskSpace.xs),
            KioskText(
              kPracticeRealUnchanged,
              textKey: const ValueKey('done-practice-note'),
              textAlign: ta,
              style: TextStyle(fontSize: KioskType.body, height: 1.3, color: KioskColors.ink),
            ),
          ],
          // 기다림 상한(kiosk_screen이 실제로 끊는 시간과 같은 값)과 정지를 또 누르지 않아도 된다는 말(휴리스틱 평가 10/18).
          if (pending) ...[
            const SizedBox(height: KioskSpace.xs),
            KioskText(
              stopPendingNote(KioskTimings.stopConfirmMaxWait),
              textKey: const ValueKey('done-pending-note'),
              textAlign: ta,
              style: TextStyle(fontSize: KioskType.body, height: 1.3, color: KioskColors.ink),
            ),
          ],
          // 무엇으로 확인했는지 제목 바로 아래 한 줄(결선 모의 평가 10/18 — 근거가 없어 '켜졌어요'가 과장으로 읽혔다).
          // 콘센트 모듈 전력 실측(L3, 출처 real)일 때만 — 누름 보고·연습에는 두지 않는다. 본문 크기·흰 글자.
          if (success && evidence != null) ...[
            const SizedBox(height: KioskSpace.xs),
            KioskText(
              evidence,
              textKey: const ValueKey('done-evidence'),
              textAlign: ta,
              style: TextStyle(
                  fontSize: KioskType.body, fontWeight: FontWeight.w700, height: 1.3, color: KioskColors.ink),
            ),
          ],
          if (success && successSub != null) ...[
            const SizedBox(height: 8),
            // 할 일 한 줄 — 상태 크기(§1-3). 근거 줄이 있으면 그 아래 본문 크기로(근거가 먼저 읽힌다).
            KioskText(
              successSub,
              textKey: const ValueKey('done-sub'),
              textAlign: ta,
              style: TextStyle(
                  fontSize: evidence != null ? KioskType.body : KioskType.status,
                  fontWeight: evidence != null ? FontWeight.w500 : FontWeight.w700,
                  color: KioskColors.ink),
            ),
          ],
          // '확인 못 함'이면 순서 안내 2~3단계(사용자 결정 10/18). 자동 재시도 단추는 두지 않는다.
          if (steps != null) KioskRecoverySteps(steps: steps, fold: !_stopUnknown),
          // '다시 멈추기'를 누른 뒤 — 본체가 받았으면 사람이 볼 상태로, 닿지 않았으면 손으로 할 일(hold_view 정지 미확인과 같은 말).
          if (_stopUnknown && stopAgain != null) ...[
            const SizedBox(height: KioskSpace.xs),
            KioskText(
              stopAgain == 'failed'
                  ? '정지 요청 결과를 확인하지 못했어요. 가전 전원을 직접 꺼 주세요'
                  : '한 번 더 멈추라고 했어요. 누름 장치를 봐 주세요',
              textKey: const ValueKey('done-stop-again-note'),
              textAlign: ta,
              style: TextStyle(
                  fontSize: KioskType.body,
                  fontWeight: FontWeight.w700,
                  color: stopAgain == 'failed' ? KioskColors.danger : KioskColors.ink),
            ),
          ],
          // 경로(ThinQ)와 확인 수준. 서버가 준 값만 말한다(물리 경로는 배지 없음).
          if (facts.isNotEmpty) ...[
            const SizedBox(height: 8),
            KioskText(
              facts.join(' · '),
              textAlign: ta,
              style: TextStyle(
                  fontSize: KioskType.body, color: KioskColors.ink),
            ),
          ],
          // 위 한 줄은 /status의 **마지막 단계** 기준이다. 두 가전을
          // 잇는 실행이면 단계마다 경로·확인 수준을 따로 말한다.
          if (runSteps.length > 1) _RunSteps(steps: runSteps),
          const SizedBox(height: 6),
          if (success) ...[
            // 무엇을 했는지는 위 띠가 말한다(평가 17차 10/18).
            if (thinq)
              KioskText(
                thinqLine,
                textAlign: ta,
                style: TextStyle(
                    fontSize: KioskType.body, color: KioskColors.muted),
              ),
          ] else ...[
            // 무엇이었는지(가전·이름)는 위 띠가 말한다(평가 17차 10/18).
            if (detail case final d? when d.isNotEmpty && !mock) ...[
              const SizedBox(height: 4),
              KioskText(
                d,
                textAlign: ta,
                style: TextStyle(
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
    // 누름 장치가 멈췄는지 모르는 정지(평가 15차 10/18, 안전) — 누름 장치를 다시 움직이게 하는 '누름 장치로 골라 누르기'는 두지
    // 않고, 정지 대기 화면(hold_view 정지 미확인)과 같은 '다시 멈추기'를 정지 자리에 둔다. 처음 화면은 보조 크기(같은 모양).
    final showStopAgain = _stopUnknown && onStopAgain != null;
    final manual = _stopUnknown ? null : onManual;
    // 확실히 못 한 결과에서 다시 하는 것이 안전할 때만 '한 번 더 하기'가 주 단추(휴리스틱 평가 10/18) — 연습, 또는 LG 가전이
    // 거절해 아무것도 바뀌지 않은 것(notExecuted). 눌렸는지 모르는 결과는 위 사람 확인 흐름으로 간다(R1).
    final retryFirst = !success && retry != null && check == null && (mock || r == KioskFailureReason.notExecuted);
    // 직접 고른 가전의 성공(R7) — '이 가전 계속 조작'이 주 단추, '다른 가전 고르기'가 보조, 처음 화면은 보조 모양.
    final continueFirst = success && onContinue != null;
    final Widget actions = check != null
        ? KioskCheckActions(
            words: check,
            // 위에 할 일 줄('가전이 움직이는지 봐 주세요')이 있으면 물음만 — 같은 당부를 두 번 하지 않는다.
            shortPrompt: success && successSub != null,
            mock: mock,
            thinq: thinq,
            retryToggle: retryMayToggle,
            onChecked: onChecked,
            onRetry: onRetryAfterCheck ?? retry,
            onHome: onDismiss,
          )
        : pending
        // 처음 화면·보조 단추 없이 기다림 표시만(평가 8차 10/18) — 정지 확인 보고는 몇 초 안에 오거나 끊긴다.
        ? Align(
            alignment: Alignment.centerLeft,
            // '처음 화면으로'가 나타날 자리(왼쪽 아래)에서 기다림을 보인다.
            child: SizedBox(
              key: const ValueKey('done-pending'),
              width: KioskSizes.primaryButton,
              height: KioskSizes.primaryButton,
            ),
          )
        : KioskResultActions(
            onHome: onDismiss,
            homeCompact: showStopAgain,
            stacked: stacked,
            primary: retryFirst
                ? KioskRetryPrimary(onTap: () => _confirmRetry(context, mock))
                : continueFirst
                    ? KioskContinuePrimary(name: continueName, onTap: onContinue!)
                    : null,
            note: success && !continueFirst
                ? (autoReturnHeld ? const _AutoReturnHeld() : _AutoReturn(seconds: autoReturnSeconds))
                : null,
            secondaries: success
                ? [if (continueFirst && onPickOther != null) kioskPickOtherAction(onPickOther!)]
                : [
                    if (manual != null)
                      KioskSecondaryAction(
                        buttonKey: const ValueKey('done-manual'),
                        icon: Icons.touch_app_outlined,
                        label: kManualEntryLabel,
                        onTap: manual,
                      ),
                    if (retry != null && !retryFirst)
                      KioskSecondaryAction(
                        buttonKey: const ValueKey('done-retry'),
                        icon: Icons.refresh,
                        // '다시 시도'는 기계 말(평가 5차 10/18). 누르면 확인 창이 먼저 뜬다(열린 문제 R1 — 정책 그대로).
                        label: '한 번 더 하기',
                        onTap: () => _confirmRetry(context, mock),
                      ),
                  ],
            stop: showStopAgain
                ? KioskStopButton(
                    label: '다시 멈추기',
                    onPressed: onStopAgain,
                    buttonKey: const ValueKey('done-stop-again'),
                    semanticsLabel: '다시 멈추기. 누름 장치에 한 번 더 멈추라고 해요')
                : null,
          );
    final who = kioskResultWho(context, target);
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
                      // 왼쪽 아래 빈자리에 누른 순서(평가 7차 10/18) — 버튼판의 ✓와 같은 뜻(누름 장치가 눌렀다고 알려 옴).
                      // 번호 안내(확인 못 함)가 있으면 누른 순서 줄은 두지 않는다(출시 검토 10/18 — 셋째 안내가 스크롤 아래로
                      // 밀려 잘렸다). 누른 칸 ✓·?는 오른쪽 버튼판이 같은 자리에서 말한다.
                      child: KioskStepTrail.worth(pressed!.length) && steps == null
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: KioskScrollArea(child: content)),
                                const SizedBox(height: KioskSpace.sm),
                                // 어두운 표시창 안에 누른 순서(시안 B ④ 10/24).
                                KioskGlassPanel(
                                  child: KioskStepTrail(
                                    key: const ValueKey('done-step-trail'),
                                    title: mock ? '연습으로 누른 순서' : '누른 순서',
                                    onGlass: true,
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
                        caption: mock ? '연습으로 누른 자리예요' : '누름 장치가 누른 자리예요',
                        captionKey: const ValueKey('done-panel-caption'),
                        pressed: pressedMap,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
          // 버튼판이 없는 결과도 같은 왼쪽 선(LG 가전 결과와 같은 틀) — 띠와 아래 줄 사이 세로 가운데, 길면 위에서부터 스크롤.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  KioskSizes.runLeft, KioskSizes.runTop, KioskSizes.stopRight, KioskSpace.xs),
              child: LayoutBuilder(
                builder: (context, box) => KioskScrollArea(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minHeight: box.maxHeight.isFinite ? box.maxHeight : 0,
                        maxWidth: KioskSizes.resultMaxWidth),
                    child: Align(alignment: Alignment.centerLeft, child: kioskWithWho(who, content)),
                  ),
                ),
              ),
            ),
          ),
          // 모든 결과 화면의 아래 줄 — 같은 자리(왼쪽 아래, 내용 왼쪽 선)·같은 모양의 '처음 화면으로'(평가 15차 10/18).
          Padding(
            padding: kResultActionsPadding,
            child: actions,
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
                        style: TextStyle(
                          fontSize: KioskType.body,
                          fontWeight: FontWeight.w600,
                          color: KioskColors.ink,
                        ),
                      ),
                      KioskText(
                        runStepFacts(steps[i]),
                        textAlign: TextAlign.center,
                        style: TextStyle(
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
              style: TextStyle(
                  fontSize: KioskType.caption, color: KioskColors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// 전력 실측(콘센트 모듈 L3, 출처 real)으로 확인한 성공의 근거 한 줄(결선 모의 평가 10/18). 확인한 것은 전기를 쓰기
/// 시작한 것이지 조리·동작이 끝난 것이 아니다 — 그 아래 '원하는 대로 됐는지 봐 주세요'가 사람이 볼 것을 말한다.
const kDoneEvidencePower = '전기를 쓰기 시작한 걸 확인했어요';

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
        // 연습은 실제 가전을 누르지 않는다 — '눌렸는지 확인하지 못했어요'는 연습 띠와 부딪혔다(평가 4차 10/18).
        KioskFailureReason.execution => '연습으로 누르다가 끝내지 못했어요',
        KioskFailureReason.safetyStop => '연습에서 다시 누르지 않고 멈췄어요',
        KioskFailureReason.serverLost => '연습 결과를 받지 못했어요',
        KioskFailureReason.stopped => kPracticeStopHeadline,
        KioskFailureReason.unconfirmed => '연습 결과를 확인하지 못했어요',
        KioskFailureReason.receiptUnknown => '연습 요청이 전달됐는지 확인하지 못했어요',
        KioskFailureReason.notExecuted => '연습을 하지 못했어요',
      };

  /// 실패가 아니라 '확인 못 함'. 다시 보내면 중복 실행이 될 수 있다.
  bool get isUnconfirmed =>
      this == KioskFailureReason.unconfirmed ||
      this == KioskFailureReason.receiptUnknown;

  /// 가장 큰 글자(2026-10-15 문구 개선 §2-1) — 실패 화면의 주인공은 단추가 아니라 할 일이다.
  String get headline => switch (this) {
        KioskFailureReason.execution => '눌렸는지 확인하지 못했어요',
        KioskFailureReason.serverLost => '어떻게 됐는지 확인하지 못했어요',
        KioskFailureReason.stopped => stopLevelHeadline(null),
        KioskFailureReason.safetyStop => '버튼 눌림을 확인하지 못해 멈췄어요',
        KioskFailureReason.unconfirmed => '보냈지만 됐는지 확인하지 못했어요',
        KioskFailureReason.receiptUnknown => '가전이 받았는지 확인하지 못했어요',
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
/// 확인한 성공은 몇 초 뒤 처음 화면(남은 초를 숫자로 — 접근성 감사 10/18, 화면을 만지면 멈춘다), 확인 못 함은 '처음 화면으로'를
/// 누를 때까지 남는다(사용자 결정 — 확인 못 함에는 카운트다운이 없다).
class _ThinqResult extends StatelessWidget {
  const _ThinqResult({
    required this.copy,
    required this.target,
    required this.success,
    required this.held,
    this.autoReturnSeconds,
    required this.onHold,
    required this.onClose,
    this.steps,
    this.check,
    this.onChecked,
    this.onRetryAfterCheck,
    this.onContinue,
    this.onPickOther,
    this.continueName,
    this.mock = false,
  });

  final VoidCallback? onContinue;
  final VoidCallback? onPickOther;
  final String? continueName;

  /// '확인 못 함'이면 순서 안내(사용자 결정 10/18). 없으면 null.
  final List<String>? steps;

  /// 확인 못 함이면 사람 확인 흐름(휴리스틱 평가 10/18) — '켜졌어요 / 안 켜졌어요'. 없으면 null.
  final KioskCheckWords? check;
  final ValueChanged<bool>? onChecked;
  final VoidCallback? onRetryAfterCheck;
  final bool mock;

  final ThinqResultCopy copy;
  final ApplianceMap? target;
  final bool success;
  final bool held;
  final int? autoReturnSeconds;
  final VoidCallback? onHold;
  final VoidCallback? onClose;

  String? get _name => (target?.displayName.isNotEmpty ?? false) ? target!.displayName : null;

  @override
  Widget build(BuildContext context) {
    final (Color color, KioskStatusBand band) = switch (copy.tone) {
      ThinqResultTone.confirmed => (
          KioskColors.confirmed,
          KioskStatusBand(tone: KioskBandTone.confirmed, icon: Icons.check, label: kBandDone,
              detail: _name, detailIcon: target?.icon),
        ),
      ThinqResultTone.attention => (
          KioskColors.warning,
          KioskStatusBand(tone: KioskBandTone.attention, icon: Icons.help_outline, label: kBandCheck,
              detail: _name, detailIcon: target?.icon),
        ),
      ThinqResultTone.practice => (KioskColors.ink, KioskStatusBand.practice(detail: _name, detailIcon: target?.icon)),
    };
    final name = target?.displayName;
    // 큰 글자에 가전 이름이 없으면(바람 세기 결과 등) 아래 작게 무엇의 결과인지 — 다른 결과 화면과 같은 가전 줄(아이콘 + 이름).
    // 무엇의 결과인지는 다른 결과 화면과 같이 위 띠 오른쪽이 늘 말한다(평가 17차 10/18). 본문에는 가전 줄을 두지 않는다.
    final showName = name != null && name.isNotEmpty && !copy.headline.contains(name) && !copy.sub.contains(name);
    // 다른 결과 화면(전자레인지 결과 kiosk15_done_verified)과 같은 틀 — 위 띠 아래 왼쪽 선에서 큰 글자 · 한 줄 · 가전 줄
    // (평가 14차 10/18: 띠 '됐어요' + 테두리 상자 + 큰 체크 원은 같은 뜻을 세 번 장식했다). 뜻은 띠의 아이콘·색과 글자가 말한다.
    final content = Semantics(
      liveRegion: true,
      label: [if (showName) name, copy.spoken, if (steps != null) recoveryStepsSpoken(steps!)].join('. '),
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
            style: TextStyle(
                fontSize: KioskType.status, fontWeight: FontWeight.w700, height: 1.3, color: KioskColors.ink),
          ),
          if (steps != null) KioskRecoverySteps(steps: steps!),
        ],
      ),
    );
    final who = kioskResultWho(context, target);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onHold?.call(),
      child: ColoredBox(
        color: KioskColors.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            band,
            // 내용은 띠와 아래 줄 사이 세로 가운데, 왼쪽 선(평가 15차 10/18 — 확인한 결과는 두 줄뿐이라 위에 붙이면 가운데 60%가
            // 비었다). 순서 안내까지 있어 길면 위에서부터 스크롤.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                    KioskSizes.runLeft, KioskSizes.runTop, KioskSizes.stopRight, KioskSpace.xs),
                child: LayoutBuilder(
                  builder: (context, box) => KioskScrollArea(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                          minHeight: box.maxHeight.isFinite ? box.maxHeight : 0,
                          maxWidth: KioskSizes.resultMaxWidth),
                      child: Align(alignment: Alignment.centerLeft, child: kioskWithWho(who, content)),
                    ),
                  ),
                ),
              ),
            ),
            // 나가는 단추는 다른 결과 화면과 같은 자리·모양의 '⌂ 처음 화면으로'(평가 11차·15차 10/18).
            Padding(
              padding: kResultActionsPadding,
              child: check != null
                  ? KioskCheckActions(
                      words: check!,
                      mock: mock,
                      thinq: true,
                      onChecked: onChecked,
                      onRetry: onRetryAfterCheck,
                      onHome: onClose,
                      homeKey: const ValueKey('thinq-result-close'),
                    )
                  : KioskResultActions(
                onHome: onClose,
                homeKey: const ValueKey('thinq-result-close'),
                primary: success && onContinue != null
                    ? KioskContinuePrimary(name: continueName, onTap: onContinue!)
                    : null,
                secondaries: [
                  if (success && onContinue != null && onPickOther != null) kioskPickOtherAction(onPickOther!),
                ],
                note: success && onContinue == null
                    ? (held ? const _AutoReturnHeld() : _AutoReturn(seconds: autoReturnSeconds))
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 성공 뒤 자동 복귀 말 — 실제 남은 초(접근성 감사 10/18: '잠시 뒤'는 얼마나 남았는지 몰라 서두르게 했다).
String autoReturnLine(int seconds) => '$seconds초 뒤 처음 화면으로 돌아가요';

/// 화면을 만져 자동 복귀를 멈춘 뒤의 말.
const kAutoReturnHeldLine = '자동으로 닫지 않아요';

/// 성공 후 자동 복귀를 **글자로도** 말한다 — 남은 초를 숫자로, 본문 크기(접근성 감사 10/18 — 작은 글씨 한 단계 위).
/// 화면을 만지면 멈춘다(종전, 시간 제한 조절). 기다리기 싫은 사람의 길은 옆의 '처음 화면으로'.
class _AutoReturn extends StatelessWidget {
  const _AutoReturn({this.seconds});

  /// 남은 초(kiosk_screen이 센다). null이면 전체 길이.
  final int? seconds;

  @override
  Widget build(BuildContext context) {
    // 큰 글씨면 두 배(kiosk_screen의 실제 전환과 같은 값, UI 평가 4차 10/17).
    final total = (KioskLayout.isLarge(context) ? KioskTimings.doneReturnLarge : KioskTimings.doneReturn).inSeconds;
    final left = (seconds ?? total).clamp(0, total);
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              autoReturnLine(left),
              key: const ValueKey('done-auto-return'),
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 220,
            height: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: total > 0 ? left / total : 0,
                minHeight: 4,
                backgroundColor: KioskColors.border,
                valueColor: AlwaysStoppedAnimation(
                  KioskColors.ink.withValues(alpha: 0.3),
                ),
              ),
            ),
          ),
        ],
    );
  }
}

/// 만져서 자동 복귀를 멈춘 뒤 — 남은 초 대신 한 말(같은 크기).
class _AutoReturnHeld extends StatelessWidget {
  const _AutoReturnHeld();

  @override
  Widget build(BuildContext context) => Text(kAutoReturnHeldLine,
      key: const ValueKey('done-auto-return-held'),
      style: TextStyle(fontSize: KioskType.body, color: KioskColors.muted));
}

/// 결과 화면 아래 줄 여백 — 왼쪽은 내용 왼쪽 선(실행 화면과 같은 [KioskSizes.runLeft]), 오른쪽은 정지 자리와 같은 끝.
const kResultActionsPadding =
    EdgeInsets.fromLTRB(KioskSizes.runLeft, 4, KioskSizes.stopRight, KioskSizes.actionsBottom);

/// '처음 화면으로' — 모든 결과 화면의 나가는 단추(화면당 채움 단추는 이것 하나, §1-5).
/// **한 모양·한 자리**(평가 15차 10/18 — 큰 흰 단추+집 아이콘 / 작은 테두리·아이콘 없음 / 가운데 흰 단추 세 가지였다):
/// 흰 면·검은 글자·집 아이콘·'처음 화면으로', 자리는 결과 화면 왼쪽 아래(내용 왼쪽 선). 정지가 주인공인 화면(정지 대기의
/// 정지 미확인, 정지 미확인 결과)에서는 [compact] — 크기만 보조이고 모양(아이콘·글자·색)은 같다.
/// 골드 면은 앰버·빨강 띠 아래에서 '잘 됐으니 다음으로'처럼 읽혔다(10/18). 연습 대기(hold_view)도 같은 단추를 쓴다.
class KioskHomeButton extends StatelessWidget {
  const KioskHomeButton(
      {super.key, this.buttonKey = const ValueKey('done-home'), required this.onTap, this.compact = false});

  /// 단추 자체의 키(시험이 쓰는 'done-home'·'hold-home'·'thinq-result-close').
  final Key buttonKey;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? KioskType.body : KioskType.status;
    // 보조 크기는 보조 모양 — 흰 테두리·투명 면(휴리스틱 평가 10/18: 작아도 흰 채움이면 화면에서 가장 눈에 띄는 단추라
    // 실패·모름 결과에서 어르신이 해결 없이 처음 화면으로 나갔다). 아이콘·글자는 같다.
    if (compact) {
      return OutlinedButton.icon(
        key: buttonKey,
        onPressed: onTap,
        icon: Icon(Icons.home_outlined, size: size),
        label: Text('처음 화면으로',
            maxLines: 1, softWrap: false, style: TextStyle(fontSize: size, fontWeight: FontWeight.w700)),
        style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.muted).copyWith(
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: KioskSpace.md)),
        ),
      );
    }
    return ElevatedButton.icon(
      key: buttonKey,
      onPressed: onTap,
      icon: Icon(Icons.home_outlined, size: size),
      label: Text('처음 화면으로',
          maxLines: 1, softWrap: false, style: TextStyle(fontSize: size, fontWeight: FontWeight.w800)),
      style: KioskButtons.primary(background: KioskColors.neutralFill, foreground: KioskColors.onAccent).copyWith(
        minimumSize: compact ? const WidgetStatePropertyAll(Size(0, KioskSizes.secondaryButton)) : null,
        padding: compact ? const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: KioskSpace.md)) : null,
      ),
    );
  }
}

/// 옛 호출(hold_view)용 — [KioskHomeButton]과 같다.
Widget kioskHomeButton(VoidCallback onTap, {Key key = const ValueKey('done-home'), bool compact = false}) =>
    KioskHomeButton(buttonKey: key, onTap: onTap, compact: compact);

/// 결과 화면 보조 단추 하나(테두리·아이콘·흰 글자, 높이 [KioskSizes.secondaryButton]) — '누름 장치로 골라 누르기'·'한 번 더 하기'.
/// 주 단추 '처음 화면으로'보다 작은 글자다.
class KioskSecondaryAction extends StatelessWidget {
  const KioskSecondaryAction(
      {super.key, this.buttonKey, required this.icon, required this.label, required this.onTap});

  /// 단추 자체의 키(시험이 쓰는 'done-manual'·'done-retry').
  final Key? buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  static const _style = TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700);
  static const double _iconSize = KioskType.body;
  static const double _padH = KioskSpace.md;

  /// 이 단추가 줄이지 않고 다 보이는 폭(글자 + 아이콘 + 여백 + 테두리).
  static double widthFor(BuildContext context, String label) {
    final tp = TextPainter(
      text: TextSpan(text: label, style: DefaultTextStyle.of(context).style.merge(_style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w + _iconSize + KioskSpace.xs + 2 * _padH + 6;
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        key: buttonKey,
        onPressed: onTap,
        icon: Icon(icon, size: _iconSize),
        label: Text(label, maxLines: 1, softWrap: false, style: _style),
        style: KioskButtons.secondary(foreground: KioskColors.ink, border: KioskColors.muted).copyWith(
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: _padH)),
        ),
      );
}

/// 결과 화면 아래 줄(평가 15차 10/18) — **주 단추 하나 + 보조 한 줄**.
///
/// - 왼쪽: '처음 화면으로'([KioskHomeButton]) — 모든 결과 화면에서 같은 자리.
/// - 그 옆: [note](자동 복귀 안내 등).
/// - 오른쪽 끝: 보조 단추들([secondaries]) — 모두 같은 폭·같은 높이, 오른쪽 끝은 정지 자리와 같은 선. 한 줄에 다 들어가지 않으면
///   주 단추 아래 줄로 내리고 그때도 같은 폭·같은 오른쪽 끝(평가 15차 — 예전에는 세 단추 크기·오른쪽 끝이 어긋났다).
/// - [stop]: 정지가 주인공일 때(정지 미확인 결과의 '다시 멈추기') 오른쪽 끝 정지 자리.
/// - [stacked](큰 글씨): 세로 한 줄, 모든 단추 같은 폭(주 단추가 먼저).
class KioskResultActions extends StatelessWidget {
  const KioskResultActions({
    super.key,
    required this.onHome,
    this.homeKey = const ValueKey('done-home'),
    this.homeCompact = false,
    this.note,
    this.secondaries = const [],
    this.stop,
    this.stacked = false,
    this.primary,
  });

  final VoidCallback? onHome;
  final Key homeKey;
  final bool homeCompact;
  final Widget? note;
  final List<KioskSecondaryAction> secondaries;
  final Widget? stop;
  final bool stacked;

  /// 주 단추가 '처음 화면으로'가 아닐 때(휴리스틱 평가 10/18 — 다시 하는 것이 안전한 실패의 '한 번 더 하기'). 있으면 왼쪽
  /// 주 자리에 두고 '처음 화면으로'는 그 옆 보조 모양.
  final Widget? primary;

  @override
  Widget build(BuildContext context) {
    final homeButton =
        onHome == null ? null : KioskHomeButton(buttonKey: homeKey, onTap: onHome!, compact: homeCompact || primary != null);
    // 주 단추가 따로 있으면 [주 단추 · 처음 화면으로(보조)]가 한 묶음으로 왼쪽 주 자리에.
    final Widget? home = primary == null
        ? homeButton
        : Row(mainAxisSize: MainAxisSize.min, children: [
            primary!,
            if (homeButton != null) ...[const SizedBox(width: KioskSpace.sm), homeButton],
          ]);
    if (stacked && stop == null && (secondaries.isNotEmpty || primary != null)) {
      return Align(
        alignment: Alignment.centerLeft,
        child: IntrinsicWidth(
          child: Column(
            key: const ValueKey('done-actions-stacked'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, b) in <Widget>[
                if (primary != null) primary!,
                if (homeButton != null) homeButton,
                ...secondaries,
              ].indexed) ...[
                if (i > 0) const SizedBox(height: KioskSpace.xs),
                b,
              ],
            ],
          ),
        ),
      );
    }
    // 주 단추가 따로 있고 보조 단추도 있으면(연습 실패의 '한 번 더 하기' + '처음 화면으로'·'누름 장치로 골라 누르기') 같은 폭
    // 격자(결선 모의 평가 10/18 — 세 단추의 크기·줄이 어긋났다): 윗줄 첫 칸이 주 단추, 아랫줄은 보조 단추들이 같은 폭·같은 높이.
    if (primary != null && secondaries.isNotEmpty && stop == null) {
      final lower = <Widget>[if (homeButton != null) homeButton, ...secondaries];
      return Column(
        key: const ValueKey('done-actions-grid'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            for (var i = 0; i < lower.length; i++) ...[
              if (i > 0) const SizedBox(width: KioskSpace.sm),
              Expanded(
                child: i == 0
                    ? primary!
                    : i == 1 && note != null
                        ? Align(alignment: Alignment.centerLeft, child: note!)
                        : const SizedBox.shrink(),
              ),
            ],
          ]),
          const SizedBox(height: KioskSpace.xs),
          Row(
            key: const ValueKey('done-secondary-row'),
            children: [
              for (var i = 0; i < lower.length; i++) ...[
                if (i > 0) const SizedBox(width: KioskSpace.sm),
                Expanded(child: lower[i]),
              ],
            ],
          ),
        ],
      );
    }
    return LayoutBuilder(builder: (context, box) {
      var secW = 0.0;
      for (final s in secondaries) {
        final w = KioskSecondaryAction.widthFor(context, s.label);
        if (w > secW) secW = w;
      }
      Widget secRow(double w) => Row(
            key: const ValueKey('done-secondary-row'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, s) in secondaries.indexed) ...[
                if (i > 0) const SizedBox(width: KioskSpace.sm),
                SizedBox(width: w, child: s),
              ],
            ],
          );
      final gaps = secondaries.isEmpty ? 0.0 : (secondaries.length - 1) * KioskSpace.sm;
      final secTotal = secondaries.length * secW + gaps;
      // 주 단추 폭 어림(글자 크기·여백) — 넘칠 것 같으면 보조 줄을 아래로 내린다.
      final homeW = (home == null ? 0.0 : (homeCompact || primary != null ? 210.0 : 290.0)) +
          (primary == null ? 0.0 : 290.0 + KioskSpace.sm);
      final stopW = stop == null ? 0.0 : KioskSizes.stopWidth + KioskSpace.lg;
      final oneRow = secondaries.isEmpty || homeW + KioskSpace.lg + secTotal + stopW <= box.maxWidth;
      final row = Row(
        // 정지 단추가 있으면 아래 끝을 맞춘다 — 보조 크기 '처음 화면으로'가 정지 대기 화면과 같은 자리(왼쪽 아래)에 온다.
        crossAxisAlignment: stop != null ? CrossAxisAlignment.end : CrossAxisAlignment.center,
        children: [
          if (home != null) home,
          if (note != null) ...[
            const SizedBox(width: KioskSpace.lg),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: note!)),
          ] else
            const Spacer(),
          if (oneRow && secondaries.isNotEmpty) secRow(secW),
          if (stop != null) ...[const SizedBox(width: KioskSpace.lg), stop!],
        ],
      );
      if (oneRow) return row;
      // 보조 단추가 한 줄에 다 들어가지 않으면 주 단추 아래 한 줄을 반씩 — 같은 폭, 왼쪽 끝은 주 단추와, 오른쪽 끝은 정지 자리와
      // 같은 선(계단처럼 어긋나지 않게).
      // 두 줄일 때는 같은 폭 격자(평가 17차 10/18 — 주 단추만 좁아 아래 두 단추와 칸이 어긋났다): 윗줄 왼쪽 칸이 주 단추.
      final grid = stop == null && secondaries.length == 2;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (grid)
            Row(
              key: const ValueKey('done-actions-grid'),
              children: [
                Expanded(child: home ?? const SizedBox.shrink()),
                const SizedBox(width: KioskSpace.sm),
                Expanded(child: note == null ? const SizedBox.shrink() : Align(alignment: Alignment.centerLeft, child: note!)),
              ],
            )
          else
            row,
          const SizedBox(height: KioskSpace.xs),
          // 보조 단추가 하나뿐이면 제 폭으로 왼쪽에(휴리스틱 평가 10/18 — 연습 실패의 '누름 장치로 골라 누르기'가 화면 전체 폭으로
          // 늘어나 주 단추보다 커 보였다).
          if (secondaries.length == 1)
            Align(
              key: const ValueKey('done-secondary-row'),
              alignment: Alignment.centerLeft,
              child: SizedBox(width: secW, child: secondaries.single),
            )
          else
          Row(
            key: const ValueKey('done-secondary-row'),
            children: [
              for (final (i, s) in secondaries.indexed) ...[
                if (i > 0) const SizedBox(width: KioskSpace.sm),
                Expanded(child: s),
              ],
            ],
          ),
        ],
      );
    });
  }
}

/// 결과 화면에서 버튼판(누름 장치가 누를 버튼을 고르는 화면)으로 가는 단추 이름(평가 8차 10/18).
/// 짧게(평가 12차 10/18) — 누르는 것은 누름 장치라는 말은 남긴다(손으로 누르라는 말과 헷갈리지 않게, 평가 8차).
const kManualEntryLabel = '누름 장치로 골라 누르기';

/// LG 가전에 부탁했지만 확인하지 못했을 때의 순서 안내(사용자 결정 10/18) — 짧은 말, 하나씩 해 볼 순서.
/// 말끝을 서로 다르게·짧게(평가 15차 10/18 — 제목·번호 셋이 모두 '~봐 주세요'였다).
/// 벽 화면 앞 어르신에게 '휴대폰 앱에서 지금 상태 보기'는 맞지 않았다(2차 독립 평가 E, 10/18) — 가전을 직접 보고,
/// 모르면 가족에게. 다 본 뒤 아래 '켜졌어요 / 안 켜졌어요'로 답한다.
/// 첫 줄은 할 일 한 가지(크게), 나머지는 '더 볼 것' 뒤([KioskRecoverySteps], 심사 의견 10/19) — 첫 줄은 폰 결과 화면과 같은 말.
const kThinqRecoverySteps = [
  '가전 앞에 가서 직접 봐 주세요',
  '가전 화면·불빛이 바뀌었나요?',
  '모르겠으면 가족에게 물어보세요',
];

/// 정지 확인 보고를 기다리는 동안 제목 아래 한 줄(휴리스틱 평가 10/18).
const kStopPendingDetail = '멈췄는지 확인하고 있어요';

/// 기다림 상한과 정지를 또 누르지 않아도 된다는 말 — '길어도 6초쯤 걸려요. 정지를 다시 누르지 않아도 돼요'.
String stopPendingNote(Duration maxWait) => '길어도 ${maxWait.inSeconds}초쯤 걸려요. 정지를 다시 누르지 않아도 돼요';

/// 버튼 누름 보고만 받은 결과를 답하지 않고 닫았을 때 처음 화면 '지난 일' 말(2차 독립 평가 C, 10/18).
const kPressDonePastHeadline = '움직였는지 확인하지 못했어요';

/// 사람 확인 흐름의 물음 머리(휴리스틱 평가 10/18).
const kCheckPrompt = '가전을 보고 알려 주세요';

/// 사람 확인 흐름의 말 — 물음 · 그렇다 · 아니다 · 아니라고 답한 것을 되짚는 말.
@immutable
class KioskCheckWords {
  const KioskCheckWords({required this.question, required this.yes, required this.no, required this.noSaid});

  /// '전자레인지 화면·불빛·소리가 바뀌었나요?'
  final String question;

  /// '바뀌었어요'
  final String yes;

  /// '안 바뀌었어요'
  final String no;

  /// '가전이 안 바뀌었다고 알려 주셨어요'의 가운데 — '안 바뀌었다고'.
  final String noSaid;

  static String _who(String? name) => withSubject((name?.isNotEmpty ?? false) ? name! : '가전');

  /// 누름 장치 가전 — 화면·불빛·소리 무엇이든 가전이 반응했는가(어느 버튼이든 맞는 말).
  /// 무엇을 보면 되는지 물음에 적는다(첫 사용 검토 10/19 #11) — '움직였나요?'는 '30초'만 누른 뒤처럼 화면만 바뀌는 때에 헷갈렸다.
  factory KioskCheckWords.moved(String? name) => KioskCheckWords(
      question: '${(name?.isNotEmpty ?? false) ? name : '가전'} 화면·불빛·소리가 바뀌었나요?',
      yes: '바뀌었어요',
      no: '안 바뀌었어요',
      noSaid: '가전이 안 바뀌었다고');

  /// LG 가전 켜기.
  factory KioskCheckWords.on(String? name) =>
      KioskCheckWords(question: '${_who(name)} 켜졌나요?', yes: '켜졌어요', no: '안 켜졌어요', noSaid: '가전이 안 켜졌다고');

  /// LG 가전 끄기.
  factory KioskCheckWords.off(String? name) =>
      KioskCheckWords(question: '${_who(name)} 꺼졌나요?', yes: '꺼졌어요', no: '안 꺼졌어요', noSaid: '가전이 안 꺼졌다고');

  /// LG 가전 설정(바람 세기 등).
  factory KioskCheckWords.changed(String? name) => KioskCheckWords(
      question: '${(name?.isNotEmpty ?? false) ? name : '가전'} 설정이 바뀌었나요?',
      yes: '바뀌었어요',
      no: '안 바뀌었어요',
      noSaid: '가전 설정이 안 바뀌었다고');
}

/// 켜고 끄는 한 버튼을 다시 누르게 될 때 확인 창의 경고(접근성 감사 10/18). 버튼 데이터에 토글 성질이 있을 때만 쓴다.
const kRetryToggleWarning = '가전이 이미 켜졌다면 다시 누르면 꺼질 수 있어요';

/// '한 번 더 하기' 확인 창 — 결과 화면 어디서 눌러도 같은 창(열린 문제 R1: 다시 누르기 전에 한 번 더 묻는다).
/// [toggle]: 다시 누를 버튼이 켜고 끄는 한 버튼(behavior=toggle)이면 [kRetryToggleWarning]을 먼저 말한다.
Future<void> confirmKioskRetry(BuildContext context,
    {required bool mock, bool thinq = false, bool toggle = false, required VoidCallback? onRetry}) async {
  final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
            title: Text(mock ? '연습을 다시 할까요?' : '가전을 봐 주셨나요?',
                style: const TextStyle(fontSize: KioskType.status)),
            content: Text(
                mock
                    ? '실제 가전에는 보내지 않아요.'
                    // LG 가전은 버튼을 다시 누르는 것이 아니라 같은 설정을 다시 보낸다 — 이미 그 설정이면 바꾸지 않는다.
                    : thinq
                        ? '같은 부탁을 가전에 한 번 더 보내요. 이미 그렇게 돼 있으면 그대로 둬요.'
                        : toggle
                            ? '$kRetryToggleWarning. 같은 버튼이 한 번 더 눌려요.'
                            : '$kDontRetryIfOn.',
                key: const ValueKey('done-retry-dialog-text'),
                style: const TextStyle(fontSize: KioskType.body)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: TextButton.styleFrom(minimumSize: const Size(120, 48)),
                  // 창을 닫는 단추는 '닫기'로 한 말(평가 17차 10/18).
                  child: const Text('닫기', style: TextStyle(fontSize: KioskType.body))),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(minimumSize: const Size(180, 48)),
                  child: const Text('네, 한 번 더 하기', style: TextStyle(fontSize: KioskType.body))),
            ],
          ));
  if (confirmed == true && context.mounted) onRetry?.call();
}

/// 다시 하는 것이 안전한 실패의 주 단추 '한 번 더 하기'(휴리스틱 평가 10/18) — 흰 채움, 누르면 확인 창.
/// 결과 화면 주 단추 '‹가전› 계속 조작'(R7 연속 조작, 2026-10-24) — 같은 조작판으로 돌아간다. 명령을 다시 보내지 않는다.
class KioskContinuePrimary extends StatelessWidget {
  const KioskContinuePrimary({super.key, this.name, required this.onTap});

  final String? name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final who = (name == null || name!.isEmpty) ? '이 가전' : name!;
    return ElevatedButton.icon(
      key: const ValueKey('done-continue'),
      onPressed: onTap,
      icon: const Icon(Icons.touch_app_outlined, size: KioskType.status),
      // 긴 가전 이름도 잘리지 않게 — 한 줄에 다 들어가도록 글자만 줄인다(단추 크기는 그대로).
      label: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text('$who 계속 조작',
            maxLines: 1, softWrap: false, style: const TextStyle(fontSize: KioskType.status, fontWeight: FontWeight.w800)),
      ),
      // 성공 뒤 할 일이 정해진 주 행동 — 강조색(시안 B ④ 10/24, 폰과 같은 청록).
      style: KioskButtons.primary(background: KioskColors.primary, foreground: KioskColors.onAccent),
    );
  }
}

/// 결과 화면 보조 단추 '다른 가전 고르기'(R7).
KioskSecondaryAction kioskPickOtherAction(VoidCallback onTap) => KioskSecondaryAction(
      buttonKey: const ValueKey('done-pick-other'),
      icon: Icons.grid_view_outlined,
      label: '다른 가전 고르기',
      onTap: onTap,
    );

class KioskRetryPrimary extends StatelessWidget {
  const KioskRetryPrimary({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ElevatedButton.icon(
        key: const ValueKey('done-retry'),
        onPressed: onTap,
        icon: const Icon(Icons.refresh, size: KioskType.status),
        label: const Text('한 번 더 하기',
            maxLines: 1, softWrap: false, style: TextStyle(fontSize: KioskType.status, fontWeight: FontWeight.w800)),
        style: KioskButtons.primary(background: KioskColors.neutralFill, foreground: KioskColors.onAccent),
      );
}

/// 사람 확인 흐름의 아래 줄(휴리스틱 평가 10/18, 2차 독립 평가 C).
///
/// 1단계: 물음('전자레인지 화면·불빛·소리가 바뀌었나요?') + **대등한 큰 단추 둘** '바뀌었어요' / '안 바뀌었어요'(같은 크기·같은 모양 —
/// 어느 쪽도 먼저 눌리게 하지 않는다) + 옆에 보조 모양 '처음 화면으로'(답하지 않고 나가면 처음 화면 '지난 일'에 남는다).
/// 2단계('안 …'): '가전이 안 바뀌었다고 알려 주셨어요' + '손으로 할게요'(처음 화면) · '한 번 더 하기'(확인 창, 다시 할 수
/// 있을 때만). '손으로 할게요'가 앞이다 — 다시 누르기를 가장 쉬운 행동으로 두지 않는다(R1).
class KioskCheckActions extends StatefulWidget {
  const KioskCheckActions({
    super.key,
    required this.words,
    this.shortPrompt = false,
    required this.mock,
    required this.thinq,
    this.retryToggle = false,
    required this.onChecked,
    required this.onRetry,
    required this.onHome,
    this.homeKey = const ValueKey('done-home'),
  });

  final KioskCheckWords words;

  /// '한 번 더 하기'가 켜고 끄는 한 버튼을 다시 누르나 — 확인 창 경고([confirmKioskRetry]의 toggle).
  final bool retryToggle;

  /// 물음만('전자레인지 화면·불빛·소리가 바뀌었나요?') — 위에 할 일 줄이 이미 '봐 주세요'라고 말할 때.
  final bool shortPrompt;
  final bool mock;
  final bool thinq;
  final ValueChanged<bool>? onChecked;
  final VoidCallback? onRetry;
  final VoidCallback? onHome;
  final Key homeKey;

  @override
  State<KioskCheckActions> createState() => _KioskCheckActionsState();
}

class _KioskCheckActionsState extends State<KioskCheckActions> {
  bool _saidNo = false;

  void _answer(bool worked) {
    final f = widget.onChecked;
    if (f != null) {
      f(worked);
    } else {
      widget.onHome?.call();
    }
  }

  Widget _big({required Key key, required IconData icon, required String label, required VoidCallback? onTap}) =>
      SizedBox(
        height: KioskSizes.primaryButton,
        child: OutlinedButton.icon(
          key: key,
          onPressed: onTap,
          icon: Icon(icon, size: KioskType.status),
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label,
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(fontSize: KioskType.status, fontWeight: FontWeight.w800)),
          ),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, KioskSizes.primaryButton),
            foregroundColor: KioskColors.ink,
            backgroundColor: KioskColors.surface2,
            side: BorderSide(color: KioskColors.ink, width: 2),
            padding: const EdgeInsets.symmetric(horizontal: KioskSpace.md),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KioskSizes.buttonRadius)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final w = widget.words;
    final large = KioskLayout.isLarge(context);
    final String prompt;
    final List<Widget> pair;
    if (!_saidNo) {
      prompt = widget.shortPrompt ? w.question : '${w.question} $kCheckPrompt';
      pair = [
        // 동그라미·가위표(O·X) — 체크는 '기계가 확인했다'로 읽혀 확인한 성공에만 쓴다(평가 3차 10/18).
        _big(
            key: const ValueKey('done-check-yes'),
            icon: Icons.circle_outlined,
            label: w.yes,
            onTap: () => _answer(true)),
        _big(
            key: const ValueKey('done-check-no'),
            icon: Icons.close,
            label: w.no,
            onTap: () => setState(() => _saidNo = true)),
      ];
    } else {
      prompt = '${w.noSaid} 알려 주셨어요';
      final retry = widget.onRetry;
      pair = [
        _big(
            key: const ValueKey('done-check-hand'),
            icon: Icons.back_hand_outlined,
            label: '손으로 할게요',
            onTap: () => _answer(false)),
        if (retry != null)
          _big(
              key: const ValueKey('done-retry'),
              icon: Icons.refresh,
              label: '한 번 더 하기',
              onTap: () => confirmKioskRetry(context,
                  mock: widget.mock, thinq: widget.thinq, toggle: widget.retryToggle, onRetry: retry)),
      ];
    }
    // 1단계에서만 '처음 화면으로'(보조) — 2단계의 '손으로 할게요'가 처음 화면으로 간다.
    final home = !_saidNo && widget.onHome != null
        ? KioskHomeButton(buttonKey: widget.homeKey, onTap: widget.onHome!, compact: true)
        : null;
    final row = Row(
      key: const ValueKey('done-check-row'),
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (final (i, b) in pair.indexed) ...[
          if (i > 0) const SizedBox(width: KioskSpace.sm),
          // 2단계에 단추가 하나뿐이어도 1단계 한 칸 폭(반쪽) — 화면 전체 폭 단추가 되지 않게.
          Expanded(child: b),
        ],
        if (pair.length == 1) ...[const SizedBox(width: KioskSpace.sm), const Spacer()],
        if (home != null && !large) ...[const SizedBox(width: KioskSpace.lg), home],
      ],
    );
    return Semantics(
      container: true,
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          KioskText(prompt,
              textKey: const ValueKey('done-check-prompt'),
              style: TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700, color: KioskColors.ink)),
          const SizedBox(height: KioskSpace.xs),
          row,
          if (home != null && large) ...[const SizedBox(height: KioskSpace.xs), home],
        ],
      ),
    );
  }
}

/// 누름 장치가 눌렀는지 모를 때의 순서 안내(사용자 결정 10/18). 바뀌지 않았을 때만 손으로 누르게 한다 — 이미 눌렸으면 한 번 더
/// 눌려 꺼질 수 있다(열린 문제 R1과 같은 이유). 말끝은 서로 다르게·짧게(평가 15차 10/18).
/// 첫 줄은 할 일 한 가지(크게), 나머지는 '더 볼 것' 뒤(심사 의견 10/19) — 첫 줄은 폰 결과 화면과 같은 말.
const kPressRecoverySteps = [
  '가전 화면이 바뀌었는지 봐 주세요',
  '누름 장치가 버튼 앞에 있나요?',
  '안 바뀌었으면 가전 버튼을 손으로 누르세요',
];

/// 누름 장치가 멈췄는지 모를 때(사용자 정지, 확인 못 함)의 순서 안내(평가 15차 10/18) — 정지가 먼저, 그다음 가전.
/// 누름 장치를 다시 움직이게 하는 일('누름 장치로 골라 누르기')은 권하지 않는다.
const kStopUnknownSteps = [
  "누름 장치가 아직 움직이면 '다시 멈추기'를 누르세요",
  '가전이 켜져 있으면 가전 정지 버튼을 손으로 눌러 주세요',
];

/// 화면 읽기·음성용 한 문장 — '첫째, …. 둘째, …'.
String recoveryStepsSpoken(List<String> steps) {
  const order = ['첫째', '둘째', '셋째', '넷째'];
  return [
    for (var i = 0; i < steps.length; i++) '${i < order.length ? order[i] : '${i + 1}'}, ${steps[i]}',
  ].join('. ');
}

/// 순서 안내 — 결과 화면의 큰 글자 아래에 둔다.
///
/// [fold]면 가장 중요한 할 일 **하나만** 크게(첫 줄) 보이고 나머지는 '더 볼 것' 뒤에 접는다(심사 의견 10/19 — 가전 불빛·누름 장치
/// 자리·손으로 누르기를 한꺼번에 보이면 눈이 어둡거나 나이 든 사용자에게 많았다). 화면 읽기는 접어도 모든 단계를 듣는다 — 위
/// 결과 묶음의 말([recoveryStepsSpoken])이 다 말한다. 정지를 확인 못 한 안내([kStopUnknownSteps])는 둘 다 안전에 걸려 접지 않는다.
class KioskRecoverySteps extends StatefulWidget {
  const KioskRecoverySteps({super.key, required this.steps, this.center = false, this.fold = true});

  final List<String> steps;

  /// 가운데 정렬 결과 화면(누른 자리 그림이 없을 때)이면 묶음째 가운데에 둔다. 줄 안 글은 늘 왼쪽 정렬.
  final bool center;

  /// 첫 줄만 크게 보이고 나머지는 '더 볼 것' 뒤에.
  final bool fold;

  @override
  State<KioskRecoverySteps> createState() => _KioskRecoveryStepsState();
}

class _KioskRecoveryStepsState extends State<KioskRecoverySteps> {
  bool _open = false;

  Widget _row(int i, {bool big = false}) => Padding(
        padding: const EdgeInsets.only(top: KioskSpace.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 28,
              height: 28,
              margin: EdgeInsets.only(top: big ? 6 : 0),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: KioskColors.muted, width: 1.5),
              ),
              child: Text('${i + 1}',
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                      fontSize: KioskType.caption, height: 1, fontWeight: FontWeight.w700, color: KioskColors.ink)),
            ),
            const SizedBox(width: KioskSpace.sm),
            Flexible(
              child: KioskText(
                widget.steps[i],
                textKey: ValueKey('done-recovery-step-$i'),
                style: big
                    // 할 일 한 줄과 같은 크기(상태 크기·굵게) — 처음 보는 사람도 이것 하나는 읽는다.
                    ? TextStyle(
                        fontSize: KioskType.status, fontWeight: FontWeight.w700, height: 1.3, color: KioskColors.ink)
                    : TextStyle(fontSize: KioskType.body, height: 1.3, color: KioskColors.ink),
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final steps = widget.steps;
    final folds = widget.fold && steps.length > 1;
    final list = Column(
      key: const ValueKey('done-recovery-steps'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!folds)
          for (var i = 0; i < steps.length; i++) _row(i)
        else ...[
          _row(0, big: true),
          if (_open)
            for (var i = 1; i < steps.length; i++) _row(i),
          Padding(
            padding: const EdgeInsets.only(top: KioskSpace.xs),
            child: TextButton.icon(
              key: const ValueKey('done-recovery-more'),
              onPressed: () => setState(() => _open = !_open),
              icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: KioskType.status),
              label: Text(_open ? '접기' : '더 볼 것 ${steps.length - 1}가지',
                  style: const TextStyle(fontSize: KioskType.body, fontWeight: FontWeight.w700)),
              style: TextButton.styleFrom(
                foregroundColor: KioskColors.ink,
                minimumSize: const Size(0, KioskSizes.secondaryButton),
                padding: const EdgeInsets.symmetric(horizontal: KioskSpace.sm),
              ),
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: KioskSpace.sm),
      child: ExcludeSemantics(child: widget.center ? Center(child: list) : list),
    );
  }
}

/// 결과 화면 왼쪽 위 어느 가전인지(시안 B ④ 10/24) — 폰과 같은 가전 그림 + 이름. 큰 글씨·대상 모름이면 null(위 띠가 말한다).
Widget? kioskResultWho(BuildContext context, ApplianceMap? target) => target == null || KioskLayout.isLarge(context)
    ? null
    : KioskWhoRow(category: target.category, fallbackIcon: target.icon);

/// 결과 본문 위에 [who]를 얹는다(없으면 본문 그대로).
Widget kioskWithWho(Widget? who, Widget content) => who == null
    ? content
    : Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [who, const SizedBox(height: KioskSpace.md), content],
      );
