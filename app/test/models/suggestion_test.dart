import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/suggestion.dart';

void main() {
  group('Suggestion.fromJson', () {
    test('parses all required fields correctly', () {
      final json = {
        'sequence_id': 'seq-42',
        'label': '우유 데우기',
        'steps': ['BT-08', 'BT-03', 'BT-05'],
      };
      final s = Suggestion.fromJson(json);
      expect(s.sequenceId, 'seq-42');
      expect(s.label, '우유 데우기');
      expect(s.steps, ['BT-08', 'BT-03', 'BT-05']);
      expect(s.receivedAt, isNotNull);
    });

    test('steps can be empty list', () {
      final s = Suggestion.fromJson({
        'sequence_id': 's1',
        'label': '빈 시퀀스',
        'steps': <String>[],
      });
      expect(s.steps, isEmpty);
    });
  });

  group('readableStep', () {
    test('returns Korean label for all BT-01 ~ BT-09', () {
      expect(readableStep('BT-01'), '10초 추가');
      expect(readableStep('BT-02'), '30초 추가');
      expect(readableStep('BT-03'), '1분 추가');
      expect(readableStep('BT-04'), '5분 추가');
      expect(readableStep('BT-05'), '시작');
      expect(readableStep('BT-06'), '취소/정지');
      expect(readableStep('BT-07'), '해동');
      expect(readableStep('BT-08'), '우유');
      expect(readableStep('BT-09'), '자동조리');
    });

    test('returns code itself for unknown button', () {
      expect(readableStep('BT-99'), 'BT-99');
      expect(readableStep('UNKNOWN'), 'UNKNOWN');
    });
  });
}
