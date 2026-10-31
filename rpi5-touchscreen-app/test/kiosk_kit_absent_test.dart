// 세트가 맡지 않은 가전: 타일은 '세트 없음', 처음 화면의 대표 동작으로 내걸지 않고, 조작판은 실행하지 못한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_featured.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

ApplianceMap _appliance(String id, {List<String> reasons = const []}) => applianceFromServerJson({
      'id': id,
      'name': id,
      'category': 'microwave',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'p', 'label': '시작', 'x': 0, 'y': 0},
      ],
      'control_path': 'physical',
      'can_execute': reasons.isEmpty,
      'readiness': reasons.isEmpty ? 'operable' : 'needs_setup',
      'readiness_reasons': reasons,
    });

KioskRoutine _routine(String id, String appliance) => KioskRoutine.fromJson({
      'id': id,
      'name': id,
      'mode': 'approve',
      'enabled': true,
      'trigger': {'kind': 'manual'},
      'steps': [
        {'kind': 'press_sequence', 'appliance_id': appliance, 'buttons': ['시작']},
      ],
    });

void main() {
  final released = _appliance('microwave', reasons: const [kGantryAbsentReason]);

  test('타일은 세트 없음이고 누름 장치 가전으로 세지 않는다', () {
    expect(released.kitAbsent, isTrue);
    expect(released.usesPressDevice, isFalse);
    expect(released.canExecute, isFalse);
    expect(kioskTileIssue(released), const KioskTileIssue(KioskTileMark.unusable, kTileKitAbsent));
    expect(kTileKitAbsent, startsWith('세트 없음'));
  });

  test('평소 가전은 세트 표시가 없다', () {
    expect(_appliance('custom_fan').kitAbsent, isFalse);
    expect(kioskTileIssue(_appliance('custom_fan')), isNull);
  });

  test('대표 동작은 세트 없는 가전의 루틴을 고르지 않는다 — 막힌 카드로도 내걸지 않는다', () {
    final fan = _appliance('custom_fan');
    final only = KioskFeaturedAction.pick([_routine('warm', 'microwave')], [released, fan],
        issueOf: (a) => kioskTileIssue(a));
    expect(only, isNull);
    final other = KioskFeaturedAction.pick([_routine('warm', 'microwave'), _routine('wind', 'custom_fan')], [released, fan],
        issueOf: (a) => kioskTileIssue(a));
    expect(other!.$1.id, 'wind');
    expect(other.$3, isNull);
  });

  test('할 일 안내 — 세트 없음과 자리 확인 전을 가른다', () {
    expect(readinessTodo(released), contains('세트'));
    expect(readinessTodo(_appliance('custom_fan', reasons: const ['자리 확인 전이에요. 휴대폰 앱에서 자리 확인을 마쳐 주세요.'])),
        contains('자리 확인'));
  });
}
