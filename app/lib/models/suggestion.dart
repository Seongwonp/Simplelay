class Suggestion {
  const Suggestion({
    required this.sequenceId,
    required this.label,
    required this.steps,
    this.receivedAt,
  });

  final String sequenceId;
  final String label;
  final List<String> steps;
  final DateTime? receivedAt;

  factory Suggestion.fromJson(Map<String, dynamic> json) => Suggestion(
        sequenceId: json['sequence_id'] as String,
        label: json['label'] as String,
        steps: (json['steps'] as List<dynamic>).cast<String>(),
        receivedAt: DateTime.now(),
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
