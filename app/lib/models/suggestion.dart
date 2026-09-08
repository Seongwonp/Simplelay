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
