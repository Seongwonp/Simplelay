/// 실행 결과를 화면 말로 옮기는 규칙 — 서버의 `/status`·`/history` 필드를 읽는다.
///
/// 결과(outcome)·경로(route)·수신(receipt)·확인 근거(confirmation)는 서로 다른 축이다
/// (계약 U1-a). 특히 ThinQ의 `unconfirmed`(보냈지만 확인 못 함)는 **실패도 성공도
/// 아니다** -- 실패로 말하면 사용자가 다시 보내 중복 실행이 되고, 성공으로 말하면
/// 확인하지 않은 일을 확인했다고 하게 된다.
///
/// 필드가 없는 옛 서버는 종전 `last_status` 판정으로 돌아간다. 폰 앱
/// (`app/lib/models/command_result.dart`)와 같은 규칙이다.
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
/// 물리 경로는 배지를 달지 않는다 — "물리 버튼"은 시스템 말이고, 버튼을 대신
/// 누르는 것은 이 제품의 기본 동작이다(2026-10-14 문구 정리, 폰 10/13과 같은 방향).
String? routeLabel(String? route) => switch (route) {
      'thinq' => 'LG 가전',
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
  String? executionMode,
}) {
  // 보내기 전 조회에서 이미 목표값이라 보내지 않았다(2026-10-14, 폰과 같은 규칙) — 실패·미확인도, 바꿨다는 말도 아니다.
  if (confirmation == 'already_at_target') {
    return '이미 그 설정이라 보내지 않았어요';
  }
  // 보낸 뒤 목표값을 봤지만 보내기 전 값은 몰랐다(2026-10-14) — '바뀐 것 확인'이 아니다.
  if (confirmation == 'state_confirmed_unknown_before') {
    return executionMode == 'mock' ? '연습 결과' : '그 설정인 것을 봤어요';
  }
  // 모의가 앞선다 — 모의 상태를 읽은 것을 실제 가전 상태 확인으로 말하지
  // 않는다(10/6 Copilot 리뷰 66990be).
  if (confirmation == 'state_confirmed') {
    return executionMode == 'mock' ? '연습 결과' : '바뀐 것을 봤어요';
  }
  if (route == 'thinq') {
    if (receipt == 'not_dispatched') return '보내지 않았어요';
    if (receipt == 'unknown') return '받았는지 몰라요';
    if (receipt == 'accepted') {
      return kind == ResultKind.unconfirmed ? '받았어요' : '하지 못했어요';
    }
    return null;
  }
  // 누름 장치에 보내지도 않은 단계는 '확인 못 함'이 아니라 누르지 않은 것이다(2026-10-14).
  if (receipt == 'not_dispatched' &&
      (confirmation == null || confirmation == 'none')) {
    return '누르지 않았어요';
  }
  // 모의 실행의 근거는 모의 실행기가 낸 것이다 — 누름 장치·가전이 응답했다고
  // 말하지 않는다(10/6 S11 실패널). 시스템 말("모의 실행기 응답"·"확인 근거 없음")
  // 대신 사람 말로 하되, 연습이라는 사실은 남긴다(2026-10-14, 폰 10/13과 같은 방향).
  if (executionMode == 'mock') {
    return switch (confirmation) {
      // 연습에서 실물 동사('동작 확인'·'눌림 확인')를 쓰지 않는다(2026-10-15 §3-2).
      'operation_confirmed' => '연습 결과',
      'press_confirmed' => '연습 결과',
      'reported' => '연습 결과',
      // 연습은 실제 가전을 누르지 않는다 — '눌렸는지 몰라요'는 위 연습 띠('실제 가전은 그대로예요')와 부딪혔다(평가 4차 10/18).
      'none' => '연습 결과',
      _ => null,
    };
  }
  return switch (confirmation) {
    // 동작 확인은 콘센트 전력이 늘어난 것이다 — 조리를 시작했다고 말하지 않는다(2026-10-15). 폰과 같은 말(10/18 §3-5).
    'operation_confirmed' => '가전이 전기를 쓰기 시작했어요',
    'press_confirmed' => '버튼을 눌렀어요',
    // 기계 말투('알려 왔어요') 대신 본 사실(평가 4차 10/18) — 누름 장치가 눌렀다는 것까지, 가전은 말하지 않는다.
    'reported' => '누름 장치가 눌렀어요',
    'none' => '눌렸는지 몰라요',
    _ => null,
  };
}

/// ThinQ 확인 못 함의 한 문장. 접수 불명이면 다시 보내기 전에 확인하라고 한다.
String unconfirmedSentence({String? receipt}) => receipt == 'unknown'
    ? '가전이 받았는지 몰라요. 다시 보내기 전에 가전을 봐 주세요.'
    : '보냈지만 됐는지 몰라요. 가전을 봐 주세요.';

/// 정지 확인 단계(2026-10-13)의 제목. 서버가 올리는 단계는
/// `sent`(정지 명령을 보냄) · `mcu_ack`(모션 보드가 받음) · `verified`(엔코더로 멈춤 확인).
///
/// 주어는 **누름 장치**이다(2026-10-15 문구 개선 원칙 0-2) — 세 단계 모두 가전이 멈췄다는 뜻이 아니다.
/// 확인하지 못한 단계는 제목부터 그렇게 말한다(원칙 0-1). 단계를 모르면(옛 서버·로컬 모의)도 확인하지 못한 것이다.
/// [ackMs]는 사용자 화면에 싣지 않는다(2026-10-14 문구 정리).
///
/// 평가 4차(10/18): '멈추라고 보냈어요'는 기계가 한 일을 말했다 — 사람이 볼 상태로.
/// 평가 8차(10/18): 이 제목은 **끝난 결과 화면**의 말이다 — '멈추는 중이에요'(진행 중 말)는 끝난 화면과 엇갈렸다.
/// 결과는 둘뿐이다: 엔코더로 본 verified만 '누름 장치가 멈췄어요', 그 밖(sent·mcu_ack·모름)은 '누름 장치가 멈췄는지 몰라요'.
/// 정지 확인 보고를 아직 기다리는 동안의 말은 [kStopPendingHeadline](결과 화면의 진행 상태)이다.
String stopLevelHeadline(String? level, {int? ackMs}) =>
    stopLevelConfirmed(level) ? '누름 장치가 멈췄어요' : '누름 장치가 멈췄는지 몰라요';

/// 정지 확인 보고를 아직 기다리는 동안(결과 화면이 처음 화면 단추 없이 잠깐 보이는 진행 상태, 평가 8차 10/18).
const kStopPendingHeadline = '멈추는 중이에요';

/// 연습(모의) 실행을 정지로 끝낸 결과 — 실제로 움직인 것이 없어 누름 장치가 멈췄는지 묻지 않는다(평가 8차 10/18).
const kPracticeStopHeadline = '연습을 멈췄어요';

/// 정지 제목 아래 할 일 한 가지(원칙 0-3). 누름 장치가 멈춘 것을 확인했어도 가전은 이미 켜졌을 수 있다.
String stopLevelNextStep(String? level) => stopLevelConfirmed(level)
    ? '가전이 켜져 있으면 가전 정지 버튼을 손으로 눌러 주세요'
    : '가전을 봐 주세요';

/// 누름 장치가 멈춘 것을 **확인한** 단계는 엔코더 확인(verified)뿐이다. 모션 보드가 받음(mcu_ack)은 확인이 아니다
/// (2026-10-15 — 예전에는 mcu_ack에도 확인 표시를 달았다).
bool stopLevelConfirmed(String? level) => level == 'verified';

/// 실패 화면에서 '다시 시도'를 보일 때 함께 쓰는 당부(2026-10-15, 열린 문제 R1) — 자동 재시도와 '다시 시도'는
/// 가전 상태를 보지 않고 같은 버튼을 다시 누른다. 전원·시작 버튼이면 한 번 더 눌려 꺼질 수 있다.
// 어느 가전에나 맞는 말(UI 평가 10/17 — 전자레인지 '시작'에 토글 전용 '꺼질 수 있어요'가 붙었다).
const kDontRetryIfOn = '가전이 이미 움직이고 있으면 한 번 더 하지 마세요. 같은 버튼이 한 번 더 눌려요';

/// 끝난 실행의 한 문장(상태 화면·음성 안내).
///
/// "실행 완료"는 조리가 끝난 뜻으로 읽힐 수 있다 — 물리 경로가 보장하는 것은
/// 버튼 조작까지다. ThinQ 성공은 서버가 상태를 다시 읽어 확인한 경우뿐이다.
/// ThinQ 성공은 [confirmation]으로 확인한 사실만큼 말한다(2026-10-14, [thinqOutcomeSentence], 폰과 같은 규칙).
String finishedMessage({
  required ResultKind kind,
  String executionMode = 'unknown',
  String? route,
  String? receipt,
  String? confirmation,
  String? detail,
  String? abortReason,
  String? stopLevel,
  bool operationVerified = false,
}) {
  final thinq = route == 'thinq';
  switch (kind) {
    case ResultKind.success:
      final said = thinq ? thinqOutcomeSentence(confirmation, detail) : null;
      if (said != null &&
          (executionMode != 'mock' || confirmation != 'state_confirmed')) {
        return executionMode == 'mock'
            ? '연습이에요. $said'
            : said;
      }
      if (thinq) {
        return executionMode == 'mock'
            ? '연습을 마쳤어요. 실제 가전은 바꾸지 않았어요.'
            : '가전 설정이 됐어요.';
      }
      // 화면 제목과 같은 말(2026-10-15) — 누름 장치가 보고한 것까지, 가전은 사람이 본다.
      if (executionMode == 'mock') return '연습을 마쳤어요. 실제 가전은 누르지 않았어요.';
      // 실행 환경을 모를 때도 같은 말(평가 4차 10/18 — '누름 장치가 다 눌렀다고 알려 왔어요'는 기계 말투). 확인 수준은
      // 화면 띠('확인해 주세요')와 뒤 문장('가전이 움직이는지 봐 주세요')이 지킨다.
      const head = '버튼은 다 눌렀어요.';
      return operationVerified
          // 전력 변화(L3 실측)만 — 확인한 그대로 '전기를 쓰기 시작했어요'(폰과 같은 말, 10/18 §3-5).
          ? '$head 가전이 전기를 쓰기 시작했어요. 원하는 대로 됐는지 봐 주세요.'
          : '$head 가전이 움직이는지 봐 주세요.'; // 폰과 같은 말(평가 14차 10/18)
    case ResultKind.unconfirmed:
      return unconfirmedSentence(receipt: receipt);
    case ResultKind.stopped:
      // 정지 단계만큼만 말한다(2026-10-15) — 누름 장치가 멈췄는지와 가전이 멈췄는지는 다른 사실이다.
      // 연습은 실제로 움직인 것이 없다 — 결과 화면과 같은 말(평가 8차 10/18).
      if (executionMode == 'mock') return '$kPracticeStopHeadline.';
      return '${stopLevelHeadline(stopLevel).replaceAll(' — ', '. ')}. ${stopLevelNextStep(stopLevel)}.';
    case ResultKind.safetyStop:
      // 모션 걸림 등(2026-10-14): 눌림 확인 실패가 아니다 — 원인 그대로, 다시 누르지 않았다고 말한다.
      final motion = motionAbortSentence(abortReason);
      if (motion != null) return '$motion. 다시 누르지 않았어요. 가전과 누름 장치를 봐 주세요.';
      return '눌렸는지 몰라서 멈췄어요. 가전을 봐 주세요.';
    case ResultKind.failed:
      return thinq ? '가전을 바꾸지 못했어요. 연결을 보고 다시 해 주세요.' : '시작하지 못했어요. 연결을 보고 다시 해 주세요.';
  }
}

/// ThinQ 성공 한 문장(마침표 포함, 2026-10-14, 폰과 같은 규칙) — 확인한 사실만큼:
/// - `already_at_target`: "이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요."
/// - `state_confirmed`: "강풍으로 바꿨어요."
/// - `state_confirmed_unknown_before`: "강풍으로 설정된 것을 확인했어요." ('바꿨어요' 금지)
///
/// 설정 이름은 서버 문장([detail], 그 실행의 사본)에서만 온다. 아니면 일반 문장, `state_confirmed`는 null(종전 문장).
String? thinqOutcomeSentence(String? confirmation, String? detail) {
  final d = detail?.trim() ?? '';
  String dot(String s) => s.endsWith('.') ? s : '$s.';
  return switch (confirmation) {
    'already_at_target' => d.contains('이미') && d.contains('보내지 않았어요')
        ? dot(d)
        : '이미 그 설정이라 보내지 않았어요.',
    'state_confirmed_unknown_before' => d.contains('설정된 것을 확인')
        ? dot(d)
        : '원하는 설정인 것을 봤어요.',
    'state_confirmed' => d.contains('바꿨어요') ? dot(d) : null,
    _ => null,
  };
}

/// 모션 중단 원인(서버 `abort_reason`, 2026-10-14) → 한 문장(마침표 없음). 모르는 값·null이면 null. 폰과 같은 표.
///
/// 10/13 보드 날: 모터 걸림(stall) 알람이 '눌림을 확인하지 못해 안전하게 멈췄어요'로 보여 원인이 바뀌어 보였다.
String? motionAbortSentence(String? reason) {
  if (reason == null || !reason.startsWith('motion_')) return null;
  // 주어는 화면에 보이는 물건(누름 장치)으로(2026-10-15 문구 개선 원칙 0-5) — 모터·보드 같은 부품 이름 대신.
  if (reason == 'motion_alarm: stall') return '누름 장치가 걸려 멈췄어요';
  if (reason.startsWith('motion_alarm')) return '누름 장치에 이상이 생겨 멈췄어요';
  return switch (reason) {
    'motion_reset' => '누름 장치가 다시 켜져 멈췄어요',
    'motion_timeout' => '누름 장치가 제때 답하지 않아 멈췄어요',
    'motion_not_ready' => '누름 장치가 준비되지 않아 멈췄어요',
    'motion_position_mismatch' => '누름 장치 위치가 맞지 않아 멈췄어요',
    'motion_link_error' => '누름 장치 연결이 끊겨 멈췄어요',
    _ => '누름 장치가 멈췄어요',
  };
}
