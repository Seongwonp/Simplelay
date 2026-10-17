// 루틴 탭 '다음 실행' 카드가 큰 22:00 옆에 '아침 공기청정기 끄기 · 매일 07:00'을 썼다(2차 평가 10/18).
// 본체는 자기 시간대(+09:00)로 at을 주는데 폰(에뮬레이터 UTC)이 toLocal로 바꿔 그렸다 — 시각은 본체 벽시계로 읽는다.
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/routine.dart';

void main() {
  test('다음 실행 시각은 본체가 준 시각 그대로(폰 시간대로 바꾸지 않는다)', () {
    // 폰 시간대와 다를 오프셋을 일부러 쓴다 — 같은 시간대면 옛 코드도 맞게 보인다.
    for (final offset in ['-03:00', '+09:00', 'Z']) {
      final run = RoutineNextRun.fromJson({
        'routine_id': 'r',
        'name': '아침 공기청정기 끄기',
        'at': '2026-10-18T07:00:00$offset',
        'when': '매일 07:00',
        'mode_label': '자동 실행',
      });
      expect(run.clock, '07:00', reason: offset);
    }
  });

  test('시각을 못 읽으면 --:--', () {
    final run = RoutineNextRun.fromJson({'routine_id': 'r', 'name': 'x', 'at': 'nope'});
    expect(run.clock, '--:--');
  });
}
