/// F1 마감 감사 — readiness 필드가 없는 응답을 어떻게 볼 것인가.
///
/// 클라이언트 기본값은 `canExecute = true`(fail-open)다. 그게 안전한지는
/// **서버 게이트가 반드시 걸리는 경로인가**로 갈린다:
///
/// - **HTTP 실행**: 서버가 준비 안 된 대상을 412로 거절한다. 화면 기본값이
///   느슨해도 물리 조작은 서버가 막는다 — 이중 방어이고, 여기서 fail-open은
///   "모르는 것을 안 됨으로 단정하지 않는다"는 오프라인 우선 원칙과 맞는다.
/// - **BLE 폴백**: 서버를 **거치지 않는다.** ESP32 릴레이로 바로 나가므로
///   게이트가 아예 없다. 여기서 fail-open은 준비 안 된 기기를 실제로
///   움직일 수 있다.
///
/// 그래서 규칙을 갈랐다: 서버가 "안 된다"고 말한 적 있는 가전은 **BLE로도
/// 내보내지 않는다.** 서버 얘기를 들은 적이 없으면(하드코딩 폴백) 막지
/// 않는다 — 막으면 서버가 죽었을 때 조작 수단이 통째로 사라진다.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/appliance.dart';

ApplianceMap _fromServer(Map<String, dynamic> json) =>
    ApplianceMap.fromJson(json);

Map<String, dynamic> _payload({Map<String, dynamic> extra = const {}}) => {
      'id': 'fan',
      'name': '선풍기',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'F-01', 'label': '전원', 'x': 0, 'y': 0},
      ],
      ...extra,
    };

void main() {
  group('서버가 준비 상태를 말해줄 때', () {
    test('안 된다고 하면 실행을 막는다', () {
      final fan = _fromServer(_payload(extra: {
        'can_execute': false,
        'readiness': 'needs_setup',
        'readiness_reasons': ['센서가 아직 준비되지 않았어요'],
      }));

      expect(fan.canExecute, isFalse);
      expect(fan.readinessKnown, isTrue);
      expect(fan.readinessReasons, isNotEmpty);
    });

    test('된다고 하면 그대로 통과시킨다', () {
      final fan = _fromServer(_payload(extra: {
        'can_execute': true,
        'readiness': 'operable',
      }));

      expect(fan.canExecute, isTrue);
      expect(fan.readinessKnown, isTrue);
    });
  });

  group('준비 상태를 말해주지 않을 때 (구버전 서버·오프라인 폴백)', () {
    test('막지 않는다 — 모르는 것을 안 됨으로 단정하지 않는다', () {
      // 서버가 죽었을 때 조작 수단이 통째로 사라지면 안 된다. HTTP 실행은
      // 서버가 어차피 412로 막으므로 여기서 느슨해도 물리 조작은 못 나간다.
      final fan = _fromServer(_payload());

      expect(fan.canExecute, isTrue);
    });

    test('하지만 "눌렸어요"이라고 말하지도 않는다', () {
      // 이 구분이 없으면 BLE처럼 서버를 안 거치는 경로에서 "확인된 operable"과
      // "그냥 모름"을 같은 값으로 보게 된다.
      final fan = _fromServer(_payload());

      expect(fan.readinessKnown, isFalse);
      expect(fan.readiness, 'unknown');
    });

    test('기기에 저장된 정의도 모름이다', () {
      // 준비 상태는 저장하지 않는다(살아 있는 값이라 재확인 전까지 사실이
      // 아니다). 저장분을 다시 읽으면 항상 '모름'으로 돌아와야 한다.
      final saved = _fromServer(_payload(extra: {
        'can_execute': true,
        'readiness': 'operable',
      })).toJson();

      expect(_fromServer(saved).readinessKnown, isFalse);
    });
  });

  group('서버를 거치지 않는 경로(BLE)에서 내보내도 되는가', () {
    test('서버가 안 된다고 한 가전은 BLE로도 내보내지 않는다', () {
      // BLE 폴백은 ESP32로 바로 나간다 — 게이트가 없다. 여기서까지
      // 느슨하면 준비 안 된 기기가 실제로 움직인다.
      final fan = _fromServer(_payload(extra: {'can_execute': false}));

      expect(fan.mayDispatchWithoutServer, isFalse);
    });

    test('서버 얘기를 들은 적 없으면 내보낸다 — 오프라인 우선', () {
      final fan = _fromServer(_payload());

      expect(fan.mayDispatchWithoutServer, isTrue);
    });

    test('서버가 된다고 한 가전도 물론 내보낸다', () {
      final fan = _fromServer(_payload(extra: {'can_execute': true}));

      expect(fan.mayDispatchWithoutServer, isTrue);
    });
  });

  test('코드에 적힌 예시 템플릿은 준비 상태를 모른다', () {
    // 템플릿에는 서버 정보가 없다 — 그래도 조작은 가능해야 한다.
    final microwave = kApplianceTemplates.first;

    expect(microwave.readinessKnown, isFalse);
    expect(microwave.canExecute, isTrue);
    expect(microwave.mayDispatchWithoutServer, isTrue);
  });
}
