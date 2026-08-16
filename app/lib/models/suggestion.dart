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
  });

  final String sequenceId;
  final String label;
  final List<String> steps;
  final DateTime? receivedAt;
  final SuggestionSource source;

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
  'BT-08': '우유',
  'BT-09': '자동조리',
};

String readableStep(String code) => buttonLabels[code] ?? code;
