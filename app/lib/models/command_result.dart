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
      ResultKind.success => '성공',
      ResultKind.failed => '실패',
      ResultKind.stopped => '정지됨',
      ResultKind.safetyStop => '안전 정지',
      ResultKind.unconfirmed => '확인 못 함',
    };

/// 제어 경로 배지. 모르면 null(말하지 않는다).
///
/// 물리 경로는 시스템 말("물리 버튼") 대신 무엇을 하는지로 말한다(2026-10-13,
/// 기록 문구 규칙과 같은 원칙).
String? routeLabel(String? route) => switch (route) {
      'physical' => '버튼을 대신 눌러요',
      'thinq' => 'ThinQ',
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
}) {
  // 모의가 앞선다 — 모의 상태를 읽은 것을 실제 가전 상태 확인으로 말하지
  // 않는다(10/6 Copilot 리뷰 66990be).
  if (confirmation == 'state_confirmed') {
    return executionMode == 'mock' ? '모의 상태 확인' : '상태 확인됨';
  }
  if (route == 'thinq') {
    if (receipt == 'not_dispatched') return '보내지 않음';
    if (receipt == 'unknown') return '가전이 받았는지 확인이 필요해요';
    if (receipt == 'accepted') {
      return kind == ResultKind.unconfirmed ? '접수됨' : '실행 안 됨';
    }
    return null;
  }
  // 모의 실행의 근거는 모의 실행기가 낸 것이다 — 누름 장치·가전이 응답했다고
  // 말하지 않는다(10/6 S11 실패널, 키오스크와 같은 규칙). 시스템 말("모의 실행기
  // 응답"·"확인 근거 없음") 대신 사람 말로 — 모의라는 사실은 남긴다(2026-10-13).
  if (executionMode == 'mock') {
    return switch (confirmation) {
      'operation_confirmed' => '모의 동작 확인',
      'press_confirmed' => '모의 눌림 확인',
      'reported' => '연습(모의) 결과',
      'none' => '연습(모의) · 눌렸는지 확인하지 못했어요',
      _ => null,
    };
  }
  return switch (confirmation) {
    'operation_confirmed' => '켜진 것을 확인했어요',
    'press_confirmed' => '버튼을 눌렀어요',
    'reported' => '누름 장치의 응답을 받았어요',
    'none' => '눌렸는지 확인하지 못했어요',
    _ => null,
  };
}

/// ThinQ 확인 못 함의 한 문장. 접수 불명이면 다시 보내기 전에 확인하라고 한다.
String unconfirmedSentence({String? receipt}) => receipt == 'unknown'
    ? '명령을 보냈지만 가전이 받았는지 확인하지 못했어요. '
        '다시 보내기 전에 가전을 직접 확인해 주세요.'
    : '명령을 보냈지만 확인하지 못했어요. 가전을 직접 확인해 주세요.';

/// 정지 확인 단계(2026-10-13)의 한 문장. 서버가 올리는 단계는
/// `sent`(정지 명령을 보냄) · `mcu_ack`(모션 보드가 받음) · `verified`(엔코더로 멈춤 확인).
/// 모르는 값·단계 없음은 null — 호출자가 종전 문장을 쓴다(단계를 지어내지 않는다).
///
/// [ackMs]는 정지를 보낸 뒤 **모션 보드가 응답하기까지**(sent→mcu_ack)다. 엔코더로 멈춤을 확인(verified)하기까지의
/// 시간이 아니다 — verified 문장에서는 '모션 보드 응답'이라고 밝혀 혼동하지 않게 한다(외부 평가 2026-10-13 L2).
String? stopLevelSentence(String? level, {int? ackMs}) {
  final ms = ackMs == null ? '' : ' ($ackMs ms)';
  return switch (level) {
    'verified' => ackMs == null
        ? '멈춘 것을 확인했어요'
        : '멈춘 것을 확인했어요 (모션 보드 응답 $ackMs ms)',
    'mcu_ack' => '모션 보드가 정지를 확인했어요$ms',
    'sent' => '정지 명령을 보냈어요 — 멈췄는지 기계를 봐 주세요',
    _ => null,
  };
}

/// '확인'은 모션 보드가 받았을 때(mcu_ack)부터다. 보냄(sent)은 확인이 아니다.
bool stopLevelConfirmed(String? level) =>
    level == 'mcu_ack' || level == 'verified';

/// 끝난 실행의 한 문장(상태 화면·음성 안내).
///
/// "실행 완료"는 조리가 끝난 뜻으로 읽힐 수 있다 — 물리 경로가 보장하는 것은
/// 버튼 조작까지다. ThinQ 성공은 서버가 상태를 다시 읽어 확인한 경우뿐이다.
/// [stopLevel]·[stopAckMs]: 사용자가 멈춘 실행이면 마지막 정지의 확인 단계(서버 /status).
String finishedMessage({
  required ResultKind kind,
  String executionMode = 'unknown',
  String? route,
  String? receipt,
  String? stopLevel,
  int? stopAckMs,
  String? abortReason,
}) {
  final thinq = route == 'thinq';
  switch (kind) {
    case ResultKind.success:
      if (thinq) {
        return executionMode == 'mock'
            ? '모의 ThinQ 명령을 보내고 모의 상태를 확인했어요. 실제 가전은 조작하지 않았어요.'
            : '명령을 보냈고 가전 상태를 확인했어요.';
      }
      return executionMode == 'mock'
          ? '모의 버튼 조작을 마쳤어요. 실제 조작은 하지 않았어요.'
          : executionMode == 'real'
              ? '누름 장치가 응답했어요. 켜졌는지 가전을 확인해 주세요.'
              : '누름 장치가 응답했어요. 실제로 눌렀는지 가전을 확인해 주세요.';
    case ResultKind.unconfirmed:
      return unconfirmedSentence(receipt: receipt);
    case ResultKind.stopped:
      // 서버가 확인한 것은 실행 루프 종료까지다. 정지 확인 단계가 오면 그만큼만
      // 말하고(2026-10-13), 없으면 가전 쪽 장치가 멈췄는지는 사람이 본다.
      final stop = stopLevelSentence(stopLevel, ackMs: stopAckMs);
      return stop == null
          ? '실행을 멈췄어요. 장치가 멈췄는지 확인해 주세요.'
          : '실행을 멈췄어요. $stop.';
    case ResultKind.safetyStop:
      // 모션 걸림 등(2026-10-14): 눌림 확인 실패가 아니다 — 원인 그대로, 다시 누르지 않았다고 말한다.
      final motion = motionAbortSentence(abortReason);
      if (motion != null) return '$motion. 다시 누르지 않았어요. 장치를 확인해 주세요.';
      return '눌림을 확인하지 못해 안전하게 멈췄어요. 가전을 확인해 주세요.';
    case ResultKind.failed:
      // 실패라는 것만으로는 시작하지 않았는지 모른다 — 접수된 뒤 일부 버튼을 누르고 실패했을 수 있다(외부 평가
      // 2026-10-13 M4). 미전송 근거(not_dispatched)가 있을 때만 보내지 못했다고 하고 다시 시도를 권한다.
      // 접수됨·부분 실행·원인 불명은 기록 화면(display_status.dart)과 같은 근거 수준으로, 이미 한 조작을
      // 되풀이하지 않게 다시 시도를 권하지 않는다.
      if (receipt == 'not_dispatched') {
        return thinq
            ? '명령을 보내지 않았어요. 연결 상태를 확인하고 다시 시도해 주세요.'
            : '누름 장치에 보내지 못했어요. 연결 상태를 확인하고 다시 시도해 주세요.';
      }
      return thinq
          ? '가전이 명령을 실행하지 않았어요. 가전 상태를 확인해 주세요.'
          : '끝까지 실행하지 못했어요. 가전 상태를 확인해 주세요.';
  }
}

/// 모션 중단 원인(서버 `abort_reason`, 2026-10-14) → 한 문장(마침표 없음). 모르는 값·null이면 null.
///
/// 10/13 보드 날: 모터 걸림(stall) 알람이 '눌림을 확인하지 못해 안전 정지'로 보여 원인이 바뀌어 보였다.
String? motionAbortSentence(String? reason) {
  if (reason == null || !reason.startsWith('motion_')) return null;
  if (reason == 'motion_alarm: stall') return '모터가 걸려 멈췄어요';
  if (reason.startsWith('motion_alarm')) return '모터 보드가 이상을 알려 멈췄어요';
  return switch (reason) {
    'motion_reset' => '모터 보드가 다시 켜져 멈췄어요',
    'motion_timeout' => '모터 보드가 제때 답하지 않아 멈췄어요',
    'motion_not_ready' => '누름 장치가 준비되지 않아 멈췄어요',
    'motion_position_mismatch' => '모터 위치가 맞지 않아 멈췄어요',
    'motion_link_error' => '누름 장치 연결이 끊겨 멈췄어요',
    _ => '누름 장치가 멈췄어요',
  };
}
