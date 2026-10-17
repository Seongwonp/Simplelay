// UI 평가 7차 10/17: '제안 잠시 쉬기'는 새 제안과 아직 시작하지 않은 자동 실행을 쉬는데, 고르는 창에서 어느 자동 실행이
// 겹치는지 말하지 않았다 — 길이마다 그 안에 시각이 드는 켜진 시각 규칙을 이름·시각으로.
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/auto_rule.dart';
import 'package:simplelay/models/quiet_hours.dart';

AutoRule _rule(String name, String? time, {bool enabled = true}) => AutoRule.fromJson({
      'id': 'ar-$name', 'name': name, 'condition_kind': time == null ? 'appliance_done' : 'time',
      'condition_time': time, 'condition_text': '', 'action_text': '', 'enabled': enabled,
    });

void main() {
  final rules = [
    _rule('저녁 공기청정기 켜기', '22:00'),
    _rule('아침 공기청정기 끄기', '07:00'),
    _rule('꺼진 규칙', '21:40', enabled: false),
    _rule('가열 종료', null),
  ];

  test('쉬는 동안(지금부터 길이 안)에 시각이 드는 켜진 시각 규칙만', () {
    final now = DateTime(2026, 10, 17, 21, 30);
    expect(pauseSkippedRules(now, 30, rules), isEmpty);
    expect(pauseSkippedRules(now, 60, rules), ['저녁 공기청정기 켜기(22:00)']);
    expect(pauseSkippedRules(now, 120, rules), ['저녁 공기청정기 켜기(22:00)']);
  });

  test('자정을 넘는 쉬기도 다음 날 시각을 센다', () {
    final now = DateTime(2026, 10, 17, 6, 10);
    expect(pauseSkippedRules(now, 60, rules), ['아침 공기청정기 끄기(07:00)']);
    // 지금 시각과 같은 규칙은 아직 시작 전이라 센다.
    expect(pauseSkippedRules(DateTime(2026, 10, 17, 22, 0), 30, rules), ['저녁 공기청정기 켜기(22:00)']);
  });
}
