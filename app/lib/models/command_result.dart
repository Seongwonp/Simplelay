/// 실행 결과를 화면 말로 옮기는 규칙 — 서버의 `/status`·`/history` 필드를 읽는다.
///
/// 결과(outcome)·경로(route)·수신(receipt)·확인 근거(confirmation)는 서로 다른 축이다
/// (계약 U1-a). 특히 ThinQ의 `unconfirmed`(보냈지만 확인 못 함)는 **실패도 성공도
/// 아니다** -- 실패로 말하면 사용자가 다시 보내 중복 실행이 되고, 성공으로 말하면
/// 확인하지 않은 일을 확인했다고 하게 된다.
///
/// 필드가 없는 옛 서버는 종전 `last_status` 판정으로 돌아간다. 키오스크
/// (`rpi5-touchscreen-app/lib/models/command_result.dart`)와 같은 규칙이다.
library;

enum ResultKind {
  /// 성공 — 물리는 버튼 조작 완료, ThinQ는 상태 확인됨.
  success,

  /// 실패 — 실행하지 못했거나 거절됐다.
  failed,

  /// 정지 요청으로 멈췄다.
  stopped,

  /// 확인에 실패해 스스로 안전 정지했다.
  safetyStop,

  /// 보냈지만 확인하지 못했다(ThinQ). 실패가 아니다.
  unconfirmed,
}

/// `last_outcome`(또는 이력의 `outcome`)을 우선 읽고, 없으면 `last_status`로.
ResultKind resultKindOf({String? outcome, String? status}) {
  switch (outcome) {
    case 'success':
      return ResultKind.success;
    case 'failed':
      return ResultKind.failed;
    case 'stopped':
      return ResultKind.stopped;
    case 'safety_stop':
      return ResultKind.safetyStop;
    case 'unconfirmed':
      return ResultKind.unconfirmed;
  }
  // 옛 서버(last_outcome 없음) — 종전 판정 그대로. safety_stopped는 정지 요청과
  // 안전 정지가 뭉개진 값이라, 예전처럼 '멈췄어요'로만 말한다.
  switch (status) {
    case 'succeeded':
      return ResultKind.success;
    case 'unconfirmed':
      return ResultKind.unconfirmed;
    case 'safety_stopped':
    case 'stopped':
      return ResultKind.stopped;
    default:
      return ResultKind.failed;
  }
}

/// 한 단어 결과(이력 열·배지).
String resultWord(ResultKind kind) => switch (kind) {
      ResultKind.success => '됐어요',
      ResultKind.failed => '못 했어요',
      ResultKind.stopped => '멈췄어요',
      ResultKind.safetyStop => '스스로 멈췄어요',
      ResultKind.unconfirmed => '몰라요',
    };

/// 제어 경로 배지. 모르면 null(말하지 않는다).
///
/// 물리 경로는 칩을 두지 않는다(2026-10-14 UX) — 이 제품의 기본 동작이라 "버튼을
/// 대신 눌러요"를 줄마다 되풀이하면 잡음이다. ThinQ만 결과 문장으로 경로가 드러나지
/// 않아 남긴다.
String? routeLabel(String? route) => switch (route) {
      'thinq' => 'LG 가전',
      _ => null,
    };

/// 무엇을 근거로 확인했나. 모르면(옛 기록 unknown·필드 없음) null.
///
/// ThinQ는 수신과 확인을 나눠 말한다: 상태까지 봤으면 "상태 확인됨", 받았다는
/// 응답만 있으면 "접수됨", 받았는지조차 모르면 "가전이 받았는지 확인이 필요해요"
/// (받았다·확인됐다로도, 실패로도 읽히지 않게).
String? confirmationLabel({
  String? route,
  String? receipt,
  String? confirmation,
  ResultKind? kind,
  String? executionMode,
  bool aborted = false,
}) {
  // 보내기 전 조회에서 이미 목표값이라 보내지 않았다(2026-10-14) — 실패·미확인도, 바꿨다는 말도 아니다.
  if (confirmation == 'already_at_target') {
    return executionMode == 'mock' ? '연습이에요. 이미 그 설정이었어요' : '이미 그 설정이라 보내지 않았어요';
  }
  // 보낸 뒤 목표값을 봤지만 보내기 전 값은 몰랐다(2026-10-14) — '바뀐 것 확인'이 아니다.
  if (confirmation == 'state_confirmed_unknown_before') {
    return executionMode == 'mock' ? '연습이에요. 그 설정인 것을 봤어요' : '그 설정인 것을 확인했어요';
  }
  // 누름 장치에 보내기 전에 끝났다 — 확인 못 함이 아니라 누르지 않았다.
  if (route != 'thinq' && receipt == 'not_dispatched') return '누르지 않았어요';
  // 사용자가 멈췄거나 모션 장치가 걸려 멈췄으면(aborted) 눌림 확인을 묻지 않는다 —
  // 멈춘 사실이 이미 결과 문장이고, "눌렸는지 확인하지 못했어요"는 고장처럼 읽힌다(2026-10-14 UX).
  if (confirmation == 'none' &&
      (kind == ResultKind.stopped || aborted)) {
    return null;
  }
  // 모의가 앞선다 — 모의 상태를 읽은 것을 실제 가전 상태 확인으로 말하지
  // 않는다(10/6 Copilot 리뷰 66990be).
  if (confirmation == 'state_confirmed') {
    return executionMode == 'mock' ? '연습 상태를 봤어요' : '상태를 확인했어요';
  }
  if (route == 'thinq') {
    if (receipt == 'not_dispatched') return '보내지 않았어요';
    if (receipt == 'unknown') return '가전이 받았는지 몰라요';
    if (receipt == 'accepted') {
      return kind == ResultKind.unconfirmed ? '가전이 받았어요' : '가전이 하지 않았어요';
    }
    return null;
  }
  // 모의 실행의 근거는 모의 실행기가 낸 것이다 — 누름 장치·가전이 응답했다고
  // 말하지 않는다(10/6 S11 실패널, 키오스크와 같은 규칙). 시스템 말("모의 실행기
  // 응답"·"확인 근거 없음") 대신 사람 말로 — 모의라는 사실은 남긴다(2026-10-13).
  if (executionMode == 'mock') {
    return switch (confirmation) {
      // 같은 상태를 '연습'과 '모의'로 섞어 쓰지 않는다(2026-10-15 키오스크 문구 개선 안 A — '연습'으로 통일).
      'operation_confirmed' => '연습 결과',
      'press_confirmed' => '연습 결과',
      'reported' => '연습 결과',
      'none' => '연습이에요. 눌렸는지 몰라요',
      _ => null,
    };
  }
  return switch (confirmation) {
    // 확인한 것은 콘센트 전력이 늘어난 것이다 — 켜졌다·조리를 시작했다고 말하지 않는다(2026-10-15, 키오스크와 같은 말).
    'operation_confirmed' => '가전이 전기를 쓰기 시작했어요',
    'press_confirmed' => '버튼을 눌렀어요',
    'reported' => '누름 장치가 눌렀다고 알려 왔어요',
    'none' => '눌렸는지 몰라요',
    _ => null,
  };
}

/// ThinQ 확인 못 함의 한 문장. 접수 불명이면 다시 보내기 전에 확인하라고 한다.
String unconfirmedSentence({String? receipt}) => receipt == 'unknown'
    ? '보냈지만 가전이 받았는지 몰라요. 다시 보내기 전에 집에서 가전을 확인해야 해요.'
    : '보냈지만 설정이 바뀌었는지 몰라요. 집에서 가전을 확인해야 해요.';

/// 정지 확인 단계(2026-10-13)의 한 문장. 서버가 올리는 단계는
/// `sent`(정지 명령을 보냄) · `mcu_ack`(모션 보드가 받음) · `verified`(엔코더로 멈춤 확인).
/// 모르는 값·단계 없음은 null — 호출자가 종전 문장을 쓴다(단계를 지어내지 않는다).
///
/// [ackMs]는 정지를 보낸 뒤 **모션 보드가 응답하기까지**(sent→mcu_ack)다. 엔코더로 멈춤을 확인(verified)하기까지의
/// 시간이 아니다 — verified 문장에서는 '모션 보드 응답'이라고 밝혀 혼동하지 않게 한다(외부 평가 2026-10-13 L2).
///
/// 사용자 화면은 숫자 없이 말한다(2026-10-14 UX 평가 — 키오스크와 같은 문장). ms와 '모션 보드'는
/// [detail]이 참일 때(개발자 도구)만.
///
/// 2026-10-15 키오스크 문구 개선 안 A(원칙 0-1~3): 주어는 누름 장치이고(가전이 멈췄다는 뜻이 아니다), 확인하지 못한
/// 단계는 문장 첫머리부터 모른다고 말한다. 2026-10-17 쉬운 말 사전: 폰도 '누름 장치'. mcu_ack는 '받았어요'까지만(확인 아님).
String? stopLevelSentence(String? level, {int? ackMs, bool detail = false}) {
  if (!detail) {
    return switch (level) {
      'verified' => '누름 장치가 멈췄어요',
      'mcu_ack' => '누름 장치가 멈추라는 신호를 받았어요. 멈췄는지는 몰라요',
      'sent' => '멈추라고 보냈어요. 멈췄는지는 아직 몰라요',
      _ => null,
    };
  }
  final ms = ackMs == null ? '' : ' ($ackMs ms)';
  return switch (level) {
    'verified' => ackMs == null
        ? '멈춘 것을 확인했어요'
        : '멈춘 것을 확인했어요 (누름 장치 응답 $ackMs ms)',
    'mcu_ack' => '누름 장치가 정지 신호를 받았어요$ms',
    'sent' => '멈추라고 보냈어요. 멈췄는지는 아직 몰라요',
    _ => null,
  };
}

/// 정지 문장 뒤 할 일 한 가지(원칙 0-3). 누름 장치가 멈췄어도 가전은 이미 켜졌을 수 있다.
String stopLevelNextStep(String? level) => switch (level) {
      'verified' => '가전이 이미 켜졌다면 집에서 가전의 정지 버튼을 눌러야 해요',
      'mcu_ack' || 'sent' => '가전은 집에서 확인해야 해요',
      _ => '누름 장치와 가전이 멈췄는지 집에서 봐 주세요',
    };

/// 다시 시도 위험(열린 문제 R1) — 자동 재시도·다시 시도는 가전 상태를 보지 않고 같은 버튼을 다시 누른다.
// 어느 가전에나 맞는 말(UI 평가 10/17 — 전자레인지 '시작'에 토글 전용 '꺼질 수 있어요'가 붙었다).
const kDontRetryIfOn = '가전이 이미 움직이고 있으면 다시 누르지 마세요. 같은 버튼이 한 번 더 눌려요';

/// 수동 조작에서 방금 누른 버튼 한 줄(2026-10-15) — 확인한 만큼만. 예전에는 실행이 성공으로 끝나기만 하면
/// "눌림을 확인했어요"라고 했다(연습·누름 장치 보고만인 경우에도).
/// 직접 누르기에서 정한 시간 안에 결과를 못 본 한 줄 — 실패가 아니라 모름이다(검토 10/19). 아직 돌거나 이미 눌렸을 수 있다.
String manualPressUnknownSentence(String label) =>
    "'$label' 아직 결과를 몰라요. 같은 버튼을 다시 누르면 두 번 눌릴 수 있어요";

///
/// [kind]는 끝난 실행의 결과 축(`resultKindOf(outcome: last_outcome, status: last_status)`, 검토 10/19) — 성공이 아니면 멈춤·
/// 스스로 멈춤·못 함·확인 못 함을 따로 말한다. 없으면 종전 문장.
String manualPressSentence(String label,
    {required bool success, ResultKind? kind, String? confirmation, String executionMode = 'unknown'}) {
  if (!success) {
    return switch (kind) {
      ResultKind.stopped => "'$label' 멈추라고 해서 멈췄어요. 눌렸는지는 가전을 보고 확인해 주세요",
      ResultKind.safetyStop => "'$label' 눌렸는지 확인이 안 돼 스스로 멈췄어요. 가전을 보고 확인해 주세요",
      ResultKind.unconfirmed => "'$label' 보냈지만 눌렸는지 확인하지 못했어요. 집에서 가전을 확인해야 해요",
      ResultKind.failed => "'$label' 하지 못했어요. 눌렸는지는 집에서 가전을 확인해야 해요",
      _ => "'$label' 눌렸는지 몰라요. 집에서 가전을 확인해야 해요",
    };
  }
  if (executionMode == 'mock') return "'$label' 연습으로 눌렀어요. 실제 가전은 누르지 않았어요";
  if (executionMode == 'real' &&
      (confirmation == 'press_confirmed' || confirmation == 'operation_confirmed')) {
    return "'$label' 눌린 것을 확인했어요";
  }
  return "'$label' 누름 장치가 눌렀다고 알려 왔어요. 가전은 집에서 확인해야 해요";
}

/// '확인'은 모션 보드가 받았을 때(mcu_ack)부터다. 보냄(sent)은 확인이 아니다.
bool stopLevelConfirmed(String? level) =>
    level == 'mcu_ack' || level == 'verified';

/// 끝난 실행의 한 문장(상태 화면·음성 안내).
///
/// "실행 완료"는 조리가 끝난 뜻으로 읽힐 수 있다 — 물리 경로가 보장하는 것은
/// 버튼 조작까지다. ThinQ 성공은 서버가 상태를 다시 읽어 확인한 경우뿐이다.
/// [stopLevel]·[stopAckMs]: 사용자가 멈춘 실행이면 마지막 정지의 확인 단계(서버 /status).
/// ThinQ 성공은 [confirmation]으로 확인한 사실만큼 말한다(2026-10-14, [thinqOutcomeSentence]) — 이미 목표값(보내지 않음)·
/// 바꿈·보낸 뒤 목표값(전 값 모름). 모의는 모의라고 밝힌다.
String finishedMessage({
  required ResultKind kind,
  String executionMode = 'unknown',
  String? route,
  String? receipt,
  String? confirmation,
  String? detail,
  String? stopLevel,
  int? stopAckMs,
  String? abortReason,
}) {
  final thinq = route == 'thinq';
  switch (kind) {
    case ResultKind.success:
      final said = thinq ? thinqOutcomeSentence(confirmation, detail) : null;
      if (said != null &&
          (executionMode != 'mock' || confirmation != 'state_confirmed')) {
        return executionMode == 'mock'
            ? '연습이에요. $said 실제 가전은 그대로예요.'
            : said;
      }
      if (thinq) {
        return executionMode == 'mock'
            ? '연습으로 보내고 연습 상태를 봤어요. 실제 가전은 그대로예요.'
            : '가전 상태를 확인했어요.';
      }
      // 확인한 만큼만(2026-10-15, 키오스크와 같은 규칙) — 끝낸 것은 버튼 누르기, 가전은 사람이 본다.
      return executionMode == 'mock'
          ? '연습을 마쳤어요. 실제 가전은 누르지 않았어요.'
          : executionMode == 'real'
              ? '버튼을 다 눌렀어요. 움직이는지는 집에서 봐 주세요.'
              : '누름 장치가 다 눌렀다고 알려 왔어요. 움직이는지는 집에서 봐 주세요.';
    case ResultKind.unconfirmed:
      return unconfirmedSentence(receipt: receipt);
    case ResultKind.stopped:
      // 서버가 확인한 것은 실행 루프 종료까지다. 정지 확인 단계가 오면 그만큼만
      // 말하고(2026-10-13), 없으면 가전 쪽 장치가 멈췄는지는 사람이 본다.
      // '실행을 멈췄어요'를 앞에 붙이지 않는다(2026-10-15) — 보냄(sent)에서도 멈춘 것처럼 읽혔다.
      final stop = stopLevelSentence(stopLevel, ackMs: stopAckMs);
      return stop == null
          ? '멈추라고 해서 실행이 끝났어요. ${stopLevelNextStep(null)}.'
          : '$stop. ${stopLevelNextStep(stopLevel)}.';
    case ResultKind.safetyStop:
      // 모션 걸림 등(2026-10-14): 눌림 확인 실패가 아니다 — 원인 그대로, 다시 누르지 않았다고 말한다.
      final motion = motionAbortSentence(abortReason);
      if (motion != null) return '$motion. 다시 누르지 않았어요. 가전과 누름 장치를 집에서 봐 주세요.';
      return '눌렸는지 몰라서 멈췄어요. 다시 하기 전에 집에서 가전을 확인해야 해요. $kDontRetryIfOn.';
    case ResultKind.failed:
      // 실패라는 것만으로는 시작하지 않았는지 모른다 — 접수된 뒤 일부 버튼을 누르고 실패했을 수 있다(외부 평가
      // 2026-10-13 M4). 미전송 근거(not_dispatched)가 있을 때만 보내지 못했다고 하고 다시 시도를 권한다.
      // 접수됨·부분 실행·원인 불명은 기록 화면(display_status.dart)과 같은 근거 수준으로, 이미 한 조작을
      // 되풀이하지 않게 다시 시도를 권하지 않는다.
      if (receipt == 'not_dispatched') {
        return thinq
            ? '가전에 보내지 못했어요. 연결을 보고 다시 해 주세요.'
            : '누름 장치에 보내지 못했어요. 연결을 보고 다시 해 주세요.';
      }
      return thinq
          ? '가전이 하지 않았어요. 가전 상세에서 지금 상태를 볼 수 있어요.'
          : '끝까지 하지 못했어요. 집에서 가전을 확인해야 해요.';
  }
}

/// ThinQ 성공 한 문장(마침표 포함, 2026-10-14) — 확인한 사실만큼:
/// - `already_at_target`: "이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요."
/// - `state_confirmed`: "강풍으로 바꿨어요."
/// - `state_confirmed_unknown_before`: "강풍으로 설정된 것을 확인했어요." ('바꿨어요' 금지 — 원래 그 값이었을 수 있다)
///
/// 설정 이름은 서버 문장([detail], 그 실행의 사본)에서만 온다. 서버 문장이 그 경우의 말이 아니면 일반 문장,
/// `state_confirmed`는 null(종전 문장).
String? thinqOutcomeSentence(String? confirmation, String? detail) {
  final d = detail?.trim() ?? '';
  String dot(String s) => s.endsWith('.') ? s : '$s.';
  return switch (confirmation) {
    'already_at_target' => d.contains('이미') && d.contains('보내지 않았어요')
        ? dot(d)
        : '이미 그 설정이라 보내지 않았어요.',
    'state_confirmed_unknown_before' => d.contains('설정된 것을 확인')
        ? dot(d)
        : '원하는 설정인 것을 확인했어요.',
    'state_confirmed' => d.contains('바꿨어요') ? dot(d) : null,
    _ => null,
  };
}

/// 모션 중단 원인(서버 `abort_reason`, 2026-10-14) → 한 문장(마침표 없음). 모르는 값·null이면 null.
///
/// 10/13 보드 날: 모터 걸림(stall) 알람이 '눌림을 확인하지 못해 안전 정지'로 보여 원인이 바뀌어 보였다.
String? motionAbortSentence(String? reason) {
  if (reason == null || !reason.startsWith('motion_')) return null;
  if (reason == 'motion_alarm: stall') return '누름 장치가 움직이지 못해 멈췄어요';
  if (reason.startsWith('motion_alarm')) return '누름 장치가 이상을 알려 멈췄어요';
  return switch (reason) {
    'motion_reset' => '누름 장치가 다시 켜져 멈췄어요',
    'motion_timeout' => '누름 장치가 제때 답하지 않아 멈췄어요',
    'motion_not_ready' => '누름 장치가 준비되지 않아 멈췄어요',
    'motion_position_mismatch' => '누름 장치 위치가 맞지 않아 멈췄어요',
    'motion_link_error' => '누름 장치 연결이 끊겨 멈췄어요',
    // 실행 중 생존 신호가 끊겨 스스로 멈춤(G5, 2026-10-16) — 누가 멈췄는지 기록이 아는 만큼(보호자 과업 평가 10/18).
    'motion_link_lost' => '연결이 끊겨 스스로 멈췄어요',
    _ => '누름 장치가 멈췄어요',
  };
}
