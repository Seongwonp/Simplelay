// 제안이 어느 경로로 왔는지 — 승인/거부 시 어느 채널로 응답을 보내야
// 하는지 판단하는 데 쓴다(HTTP로 온 제안을 BLE로 응답하면 안 됨, 반대도 마찬가지).
enum SuggestionSource { ble, http }

class Suggestion {
  const Suggestion({
    required this.sequenceId,
    required this.label,
    required this.steps,
    this.receivedAt,
    this.source = SuggestionSource.ble,
    this.reason = '',
    this.applianceId,
    this.timeBand = '',
    this.occurrences = 0,
  });

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
    return '최근 $timeBand 시간에 $occurrences번 하셨어요.';
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
