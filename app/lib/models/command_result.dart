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
String? routeLabel(String? route) => switch (route) {
      'physical' => '물리 버튼',
      'thinq' => 'ThinQ',
      _ => null,
    };

/// 무엇을 근거로 확인했나. 모르면(옛 기록 unknown·필드 없음) null.
///
/// ThinQ는 수신과 확인을 나눠 말한다: 상태까지 봤으면 "상태 확인됨", 받았다는
/// 응답만 있으면 "접수됨", 받았는지조차 모르면 "접수 불명".
String? confirmationLabel({
  String? route,
  String? receipt,
  String? confirmation,
  ResultKind? kind,
}) {
  if (confirmation == 'state_confirmed') return '상태 확인됨';
  if (route == 'thinq') {
    if (receipt == 'not_dispatched') return '보내지 않음';
    if (receipt == 'unknown') return '접수 불명';
    if (receipt == 'accepted') {
      return kind == ResultKind.unconfirmed ? '접수됨' : '실행 안 됨';
    }
    return null;
  }
  return switch (confirmation) {
    'operation_confirmed' => '동작 확인됨',
    'press_confirmed' => '누름 확인됨',
    'reported' => '실행기 보고만 받음',
    'none' => '확인 근거 없음',
    _ => null,
  };
}

/// ThinQ 확인 못 함의 한 문장. 접수 불명이면 다시 보내기 전에 확인하라고 한다.
String unconfirmedSentence({String? receipt}) => receipt == 'unknown'
    ? '명령을 보냈지만 가전이 받았는지 알 수 없어요(접수 불명). '
        '다시 보내기 전에 가전을 직접 확인해 주세요.'
    : '명령을 보냈지만 확인하지 못했어요. 가전을 직접 확인해 주세요.';

/// 끝난 실행의 한 문장(상태 화면·음성 안내).
///
/// "실행 완료"는 조리가 끝난 뜻으로 읽힐 수 있다 — 물리 경로가 보장하는 것은
/// 버튼 조작까지다. ThinQ 성공은 서버가 상태를 다시 읽어 확인한 경우뿐이다.
String finishedMessage({
  required ResultKind kind,
  String executionMode = 'unknown',
  String? route,
  String? receipt,
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
              ? '버튼 조작을 마쳤어요.'
              : '실행기가 완료를 보고했어요. 실제 조작 여부는 확인하지 못했어요.';
    case ResultKind.unconfirmed:
      return unconfirmedSentence(receipt: receipt);
    case ResultKind.stopped:
      // 서버가 확인한 것은 실행 루프 종료까지다. 가전 쪽 장치가 멈췄는지는
      // 사람이 본다(물리 정지 확인은 실측 대기).
      return '실행을 멈췄어요. 장치가 멈췄는지 확인해 주세요.';
    case ResultKind.safetyStop:
      return '눌림을 확인하지 못해 안전하게 멈췄어요. 가전을 확인해 주세요.';
    case ResultKind.failed:
      return thinq ? '명령이 실행되지 않았어요.' : '실행하지 못했어요.';
  }
}
