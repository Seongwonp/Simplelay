/// 가전 콘센트 장치(콘센트 모듈)의 비상 버튼 걸림(2026-10-05) — `/status.estop_latched`와
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
  String get message => messageFor();

  /// [powerRestore]: 가전 콘센트 장치가 다시 켜져 전원이 꺼진 걸림(서버 `estop_detail`에 '다시 켜져')이었다 —
  /// 그때는 해제 확인 뒤 서버가 콘센트 전원을 다시 켠다(`rpi/verifier/outlet.py` acknowledge_and_restore).
  /// 비상 버튼 걸림은 해제해도 전원을 켜지 않고, 멈췄던 작업도 다시 시작하지 않는다(서버에 작업 큐가 없다).
  /// 자동 실행 허용 규칙은 꺼지지 않으므로 그렇다고 말하지 않는다(2026-10-15 문구 개선 원칙 0-6).
  String messageFor({bool powerRestore = false}) => switch (outcome) {
        EstopAckOutcome.cleared => powerRestore
            ? '해제했어요. 가전 콘센트 전원을 다시 켰어요.'
            : '해제했어요. 멈췄던 작업은 다시 시작하지 않아요. 가전 전원은 따로 켜야 해요.',
        EstopAckOutcome.buttonPressed =>
          '빨간 비상 버튼이 아직 눌려 있어요. 돌려서 푼 뒤 다시 해제해 주세요.',
        EstopAckOutcome.outletUnreachable =>
          '가전 콘센트 장치가 답하지 않아 해제하지 못했어요. 연결을 확인하고 다시 해 주세요.',
        EstopAckOutcome.retriggered =>
          '해제하는 사이 다시 걸렸어요. 주변을 확인하고 다시 해제해 주세요.',
        EstopAckOutcome.stillLatched =>
          '아직 풀리지 않았어요. 빨간 비상 버튼과 주변을 확인하고 다시 해제해 주세요.',
        EstopAckOutcome.notLatched =>
          'SimpleLay 본체가 걸림을 확인하지 못해 해제하지 않았어요. 상태를 다시 확인해 주세요.',
        EstopAckOutcome.noAnswer =>
          '작은 팔 장치가 답하지 않아 해제하지 못했어요. 연결을 확인하고 다시 해 주세요.',
        EstopAckOutcome.failed =>
          '해제 요청을 보내지 못했어요. 연결을 확인하고 다시 해 주세요.',
      };
}

/// 가전 콘센트 장치가 다시 켜져(재부팅) 전원이 꺼진 걸림인가 — 서버 문장의 '다시 켜져'로 가른다
/// (서버 `rpi/api/service.py` estop_block_reason과 같은 기준). 이때는 비상 버튼이 눌린 것이 아니다.
bool estopIsPowerLoss(String? detail) =>
    detail != null && detail.contains('다시 켜져');

/// 서버 문장(`estop_detail`)이 띠 제목과 같은 말로 시작하면 그 머리를 떼고 나머지만 보인다
/// (2026-10-15 — RPi4 문장 "비상 버튼이 눌려 있어요 — 풀고 …"가 제목을 되풀이했다). 남는 말이 없으면 null.
String? estopDetailLine(String? detail) {
  final d = detail?.trim() ?? '';
  if (d.isEmpty) return null;
  final title = estopTitleFor(detail);
  if (!d.startsWith(title)) return d;
  var rest = d.substring(title.length).trim();
  if (rest.startsWith('—')) rest = rest.substring(1).trim();
  return rest.isEmpty ? null : rest;
}

/// 걸림 띠 제목(2026-10-15 문구 개선 §2-3) — '비상정지' 대신 손에 보이는 물건 이름으로.
const kEstopTitle = '비상 버튼이 눌려 있어요';
const kEstopPowerTitle = '가전 콘센트 전원이 꺼져 있어요';
String estopTitleFor(String? detail) =>
    estopIsPowerLoss(detail) ? kEstopPowerTitle : kEstopTitle;

/// 해제 확인 문장 — 무엇을 하고, 해제하면 무엇이 되는지(되지 않는지)까지.
const kEstopConfirmQuestion =
    '① 빨간 비상 버튼을 돌려서 풀어 주세요\n'
    '② 가전 주변이 안전한지 봐 주세요\n'
    '해제해도 멈췄던 작업은 다시 시작하지 않아요.\n'
    '가전 전원은 따로 켜야 해요.';
const kEstopPowerConfirmQuestion =
    '가전 주변이 안전한지 봐 주세요.\n해제하면 가전 콘센트 전원이 다시 켜져요.';
String estopConfirmFor(String? detail) => estopIsPowerLoss(detail)
    ? kEstopPowerConfirmQuestion
    : kEstopConfirmQuestion;

/// 띠의 단추 — 바로 해제가 아니라 안내를 먼저 연다. 해제는 안내 안의 '해제하기'로만.
const kEstopAckLabel = '풀기 안내';
const kEstopConfirmLabel = '해제하기';

/// 걸림이 새로 생길 때 한 번 말하는 안내(키오스크 음성).
const kEstopSpoken = '비상 버튼이 눌렸어요. 주변을 확인한 뒤 화면에서 해제해 주세요.';
const kEstopPowerSpoken = '가전 콘센트 전원이 꺼졌어요. 주변을 확인한 뒤 화면에서 해제해 주세요.';
String estopSpokenFor(String? detail) =>
    estopIsPowerLoss(detail) ? kEstopPowerSpoken : kEstopSpoken;
