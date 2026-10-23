// 처음 화면 '무엇을 할까요?'(2026-10-24 실패널) — 폰 홈과 같은 후보만 세운다. 시각 예약 루틴('저녁 공기청정기 켜기')이
// 맨 앞이라 대표 동작으로 나왔다. 꺼진 루틴·알림만 루틴도 세우지 않는다.
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_featured.dart';

KioskRoutine _r(String id, {String trigger = 'manual', bool enabled = true, String mode = 'approve'}) =>
    KioskRoutine.fromJson({
      'id': id,
      'name': id,
      'mode': mode,
      'enabled': enabled,
      'trigger': {'kind': trigger},
      'steps': [
        {'kind': 'press_sequence', 'appliance_id': 'microwave', 'buttons': ['30초', '시작']},
      ],
    });

void main() {
  test('시각 예약·꺼짐·알림만 루틴은 건너뛰고 직접 실행하는 루틴을 고른다', () {
    final picked = KioskFeaturedAction.pick([
      _r('evening', trigger: 'time'),
      _r('off', enabled: false),
      _r('notify', mode: 'notify'),
      _r('warm'),
    ], [kMicrowaveAppliance]);
    expect(picked?.$1.id, 'warm');
  });

  test('후보가 없으면 카드를 세우지 않는다', () {
    expect(KioskFeaturedAction.pick([_r('evening', trigger: 'time')], [kMicrowaveAppliance]), isNull);
  });
}
