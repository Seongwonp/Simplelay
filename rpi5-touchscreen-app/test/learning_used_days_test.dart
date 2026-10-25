import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/learning_status.dart';

// '왜 습관인지' 근거(2026-10-25) — 실제로 쓴 날을 한 줄로. 달이 바뀔 때만 달을 다시 쓴다.
void main() {
  test('쓴 날 한 줄', () {
    expect(usedDaysLine([DateTime(2026, 10, 30), DateTime(2026, 10, 31), DateTime(2026, 11, 1)]),
        '쓴 날: 10월 30일 · 31일 · 11월 1일');
    expect(usedDaysLine(const []), isNull);
  });

  test('옛 서버 응답(recent_days 없음)도 읽는다', () {
    final r = LearningRoutine.fromJson({
      'purpose': '공기청정기 켜기', 'appliance_id': 'air_purifier', 'time_band': '저녁',
      'occurrences': 3, 'distinct_days': 3, 'established': true, 'muted': false,
    });
    expect(r.recentDays, isEmpty);
  });
}
