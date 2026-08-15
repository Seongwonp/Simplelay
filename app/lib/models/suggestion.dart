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
  'BT-08': '우유 버튼',
  'BT-03': '1분',
  'BT-05': '시작',
};

String readableStep(String code) => buttonLabels[code] ?? code;
