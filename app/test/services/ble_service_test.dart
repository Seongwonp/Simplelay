import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/services/ble_service.dart';

void main() {
  late BleService ble;

  setUp(() => ble = BleService());
  tearDown(() => ble.dispose());

  group('simulateConnected / simulateDisconnected', () {
    test('simulateConnected emits connected state', () async {
      ble.simulateConnected();
      await expectLater(
        ble.connectionState,
        emits(BleConnectionState.connected),
      );
    });

    test('simulateDisconnected emits disconnected state', () async {
      ble.simulateConnected();
      ble.simulateDisconnected();
      await expectLater(
        ble.connectionState,
        emitsInOrder([
          BleConnectionState.connected,
          BleConnectionState.disconnected,
        ]),
      );
    });
  });

  group('injectMessage', () {
    test('injected message appears on messages stream', () async {
      final msg = {'type': 'suggestion', 'sequence_id': 's1', 'label': 'test', 'steps': <String>[]};
      ble.injectMessage(msg);
      await expectLater(ble.messages, emits(msg));
    });

    test('multiple injected messages arrive in order', () async {
      final m1 = {'type': 'sensor', 'current_ma': 300.0};
      final m2 = {'type': 'result', 'success': true};
      ble.injectMessage(m1);
      ble.injectMessage(m2);
      await expectLater(ble.messages, emitsInOrder([m1, m2]));
    });
  });

  group('send in demo mode', () {
    test('send is no-op when simulated — no exception', () async {
      ble.simulateConnected();
      await expectLater(
        ble.send({'type': 'confirm', 'sequence_id': 's1', 'approved': true}),
        completes,
      );
    });

    test('sendConfirmation is no-op when simulated', () async {
      ble.simulateConnected();
      await expectLater(ble.sendConfirmation('s1', true), completes);
    });

    test('emergencyStop is no-op when simulated', () async {
      ble.simulateConnected();
      await expectLater(ble.emergencyStop(), completes);
    });

    test('sendCommand is no-op when simulated', () async {
      ble.simulateConnected();
      await expectLater(
        ble.sendCommand('우유 데워줘', source: 'voice'),
        completes,
      );
    });
  });

  group('scan', () {
    test('scan emits empty list immediately when BT is off', () async {
      // scan()은 async* 이므로 첫 번째 이벤트가 빈 리스트여야 함
      final first = await ble.scan().first;
      expect(first, isEmpty);
    });
  });

  group('packet buffer (_decode)', () {
    test('partial packet buffered until newline arrives', () async {
      // _decode를 직접 호출해 개행 기반 프레이밍을 검증
      final messages = <Map<String, dynamic>>[];
      ble.messages.listen(messages.add);

      // ignore: invalid_use_of_protected_member
      ble._decode([123, 34, 116, 121, 112, 101, 34, 58]); // '{"type":'
      await Future<void>.delayed(Duration.zero);
      expect(messages, isEmpty, reason: '개행 없으면 파싱 안 함');

      // ignore: invalid_use_of_protected_member
      ble._decode([34, 116, 101, 115, 116, 34, 125, 10]); // '"test"}\n'
      await Future<void>.delayed(Duration.zero);
      expect(messages.length, 1);
      expect(messages.first['type'], 'test');
    });

    test('malformed JSON is silently skipped', () async {
      final messages = <Map<String, dynamic>>[];
      ble.messages.listen(messages.add);

      // ignore: invalid_use_of_protected_member
      ble._decode('not json\n{"type":"ok"}\n'.codeUnits);
      await Future<void>.delayed(Duration.zero);
      expect(messages.length, 1);
      expect(messages.first['type'], 'ok');
    });
  });
}
