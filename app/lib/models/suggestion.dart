// 제안이 어느 경로로 왔는지 — 승인/거부 시 어느 채널로 응답을 보내야
// 하는지 판단하는 데 쓴다(HTTP로 온 제안을 BLE로 응답하면 안 됨, 반대도 마찬가지).
enum SuggestionSource { ble, http }

class Suggestion {
  const Suggestion({
    this.isDemo = false,
    required this.sequenceId,
    required this.label,
    required this.steps,
    this.receivedAt,
    this.source = SuggestionSource.ble,
    this.reason = '',
    this.applianceId,
    this.timeBand = '',
    this.occurrences = 0,
    this.scenarioId,
    this.commands = const [],
  });

  /// 시나리오 제안이면 그 ID(서버 `scenario_id`). 없으면 종전 제안.
  final String? scenarioId;

  /// 승인에 **고정되는** 명령들. 비어 있지 않으면 시나리오 카드다 -- 폰의 버튼맵이
  /// 아니라 서버가 확정한 대상·경로·동작을 그대로 보여 주고 승인한다.
  final List<SuggestionCommand> commands;

  bool get isScenario => commands.isNotEmpty;

  final bool isDemo;
  final String sequenceId;
  final String label;
  final List<String> steps;
  final DateTime? receivedAt;
  final SuggestionSource source;

  // 환경 기반 제안 등의 "왜 지금" 근거. 없으면 빈 문자열.
  final String reason;

  /// 이 제안이 조작할 가전. 화면이 그리는 버튼 지도와 실제 실행 대상을
  /// 묶는 값이다. 서버가 모르면 null(현재 선택 가전으로 폴백).
  final String? applianceId;

  /// 이 루틴을 되풀이하던 시간대('아침'·'저녁'). 환경/데모 제안이거나
  /// BLE로 온 제안이면 빈 문자열.
  final String timeBand;

  /// 그 시간대에 실제로 실행한 횟수. 패턴 제안에서만 의미가 있다.
  final int occurrences;

  /// "왜 지금 이걸 제안하는가"를 한 문장으로.
  ///
  /// 서버가 근거를 준 제안(환경)은 그 문장을 그대로 쓰고, 패턴 제안은
  /// 시간대·횟수로 만든다. 지금까지는 이 둘을 앱으로 옮기며 버려서,
  /// 사용자는 왜 이게 떴는지 알 수 없었다.
  ///
  /// **데모 제안은 일부러 비운다.** 데모 트리거는 패턴 감지를 우회하려고
  /// 횟수를 지어내는데, 그 숫자를 '이만큼 하셨어요'로 보여주면 화면이
  /// 사실이 아닌 말을 하게 된다.
  String get whyNow {
    if (reason.isNotEmpty) return reason;
    if (occurrences <= 0 || timeBand.isEmpty) return '';
    if (timeBand == '데모' || timeBand == '환경') return '';
    // '최근'이라고 하지 않는다. 서버의 패턴 감지에는 기간 창이 없고
    // 그 시간대의 **전체 이력**을 센다 -- "최근 4번"이라고 말하면
    // 화면이 집계 범위를 실제보다 좁게 말하는 것이 된다.
    // 기간 창이 제품 규칙으로 필요해지면 서버 집계에 넣고 응답에
    // 기간을 실어 보낸 뒤 문구를 되살린다.
    return '$timeBand 시간에 $occurrences번 하셨어요.';
  }

  /// '다시 받지 않기'를 약속할 수 있는 제안인지.
  ///
  /// 영구 억제는 서버(HTTP)의 억제 목록에만 남는다. BLE로 온 제안은
  /// '이번만 넘기기'와 똑같은 거절 메시지가 되므로, 지키지 못할 약속을
  /// 버튼으로 내걸지 않는다.
  bool get canMute => source == SuggestionSource.http;

  factory Suggestion.fromJson(Map<String, dynamic> json) => Suggestion(
        sequenceId: json['sequence_id'] as String,
        label: json['label'] as String,
        steps: (json['steps'] as List<dynamic>).cast<String>(),
        receivedAt: DateTime.now(),
        source: SuggestionSource.ble,
      );
}

/// 시나리오 카드의 확정 명령 하나(서버 `commands[]`).
class SuggestionCommand {
  const SuggestionCommand({
    required this.targetId,
    required this.route,
    this.action,
    this.buttons = const [],
    this.summary = '',
  });

  final String targetId;

  /// physical | thinq
  final String route;
  final String? action;
  final List<String> buttons;

  /// 서버가 만든 한 줄 — 어느 가전의 무엇을 어떻게(승인에 묶이는 문장).
  final String summary;
}

const buttonLabels = <String, String>{
  'BT-01': '10초 추가',
  'BT-02': '30초 추가',
  'BT-03': '1분 추가',
  'BT-04': '5분 추가',
  'BT-05': '시작',
  'BT-06': '취소/정지',
  'BT-07': '해동',
  'BT-08': '즉석밥',
  'BT-09': '냉동식품',
  'BT-10': '라면',
  'AC-01': '전원',
  'AC-02': '온도 낮추기',
  'AC-03': '온도 올리기',
  'AC-04': '냉방',
  'AC-05': '제습',
  'AC-06': '송풍',
  'AC-07': '바람세기',
  'AC-08': '예약',
  'AC-09': '취소',
};

String readableStep(String code) => buttonLabels[code] ?? code;
