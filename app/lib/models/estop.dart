/// 콘센트 모듈 비상정지 걸림(2026-10-05) — `/status.estop_latched`와
/// `POST /stop/ack`의 결과.
///
/// 해제는 **사람이** 버튼을 풀고 확인한 뒤에만 보낸다. 앱이 스스로 보내는 경로는
/// 없다(자동 해제 금지). 서버 규약은 `rpi/api/router.py`의 `acknowledge_estop`.
library;

/// 해제 확인 결과의 종류.
enum EstopAckOutcome {
  /// 200 · ok=true — 풀렸다. 가전 전원 릴레이는 꺼진 채다(켜기는 별도).
  cleared,

  /// 200 · ok=false · reason=estop_button_pressed — 버튼이 아직 눌려 있다(또는 단선).
  buttonPressed,

  /// 200 · ok=false · reason=outlet_unreachable — 콘센트 모듈이 답하지 않았다.
  outletUnreachable,

  /// 200 · ok=false · reason=estop_retriggered — 해제 직후 다시 걸렸다.
  retriggered,

  /// 200 · ok=false · 사유를 모름.
  stillLatched,

  /// 409 — 실행기가 비상정지 걸림을 보고하지 않는다.
  notLatched,

  /// 504 — 구동 장치(RPi4)가 답하지 않았다.
  noAnswer,

  /// 그 밖의 오류·통신 실패.
  failed,
}

class EstopAckResult {
  const EstopAckResult(this.outcome, {this.detail});

  final EstopAckOutcome outcome;

  /// 서버가 준 문장(있으면). 화면 문장은 [message]가 정한다.
  final String? detail;

  bool get cleared => outcome == EstopAckOutcome.cleared;

  /// 200 응답 본문을 읽는다. ok가 참이 아니면 걸린 채로 본다.
  factory EstopAckResult.fromJson(Map<String, dynamic> json) {
    final detail = json['detail'] is String ? json['detail'] as String : null;
    if (json['ok'] == true && json['latched'] != true) {
      return EstopAckResult(EstopAckOutcome.cleared, detail: detail);
    }
    final outcome = switch (json['reason']) {
      'estop_button_pressed' => EstopAckOutcome.buttonPressed,
      'outlet_unreachable' => EstopAckOutcome.outletUnreachable,
      'estop_retriggered' => EstopAckOutcome.retriggered,
      _ => EstopAckOutcome.stillLatched,
    };
    return EstopAckResult(outcome, detail: detail);
  }

  /// 오류 상태 코드를 결과로 바꾼다.
  factory EstopAckResult.fromStatusCode(int code, {String? detail}) =>
      EstopAckResult(
        switch (code) {
          409 => EstopAckOutcome.notLatched,
          504 => EstopAckOutcome.noAnswer,
          _ => EstopAckOutcome.failed,
        },
        detail: detail,
      );

  /// 사람에게 보일 한 줄(해요체). 실패는 무엇을 하면 되는지까지 말한다.
  String get message => switch (outcome) {
        EstopAckOutcome.cleared => '비상정지를 풀었어요. 가전 전원은 따로 켜야 해요.',
        EstopAckOutcome.buttonPressed =>
          '비상정지 버튼이 아직 눌려 있어요. 버튼을 돌려 푼 뒤 다시 해 주세요.',
        EstopAckOutcome.outletUnreachable =>
          '전기 플러그가 답하지 않아 풀지 못했어요. 연결을 보고 다시 해 주세요.',
        EstopAckOutcome.retriggered =>
          '비상정지가 다시 걸렸어요. 주변을 보고 다시 풀어 주세요.',
        EstopAckOutcome.stillLatched =>
          '아직 풀리지 않았어요. 비상정지 버튼과 주변을 보고 다시 해 주세요.',
        EstopAckOutcome.notLatched =>
          '본체가 비상정지를 찾지 못해 풀지 않았어요. 새로 보고 다시 해 주세요.',
        EstopAckOutcome.noAnswer =>
          '작은 팔이 답하지 않아 풀지 못했어요. 연결을 보고 다시 해 주세요.',
        EstopAckOutcome.failed =>
          '풀어 달라고 보내지 못했어요. 연결을 보고 다시 해 주세요.',
      };
}

/// 해제 확인 대화 문장 — 폰·키오스크가 같은 말을 쓴다.
const kEstopConfirmQuestion = '가전 주변을 봤나요? 비상정지 버튼이 풀려 있어야 풀려요.';
const kEstopTitle = '비상정지가 걸려 있어요';
const kEstopAckLabel = '봤어요, 풀기';
