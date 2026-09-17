import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/services/ble_service.dart';

void main() {
  late BleService ble;

  setUp(() => ble = BleService());
  tearDown(() async => ble.dispose());

  group('simulateConnected / simulateDisconnected', () {
    test('simulateConnected emits connected state', () async {
      final expectation = expectLater(
        ble.connectionState,
        emits(BleConnectionState.connected),
      );
      ble.simulateConnected();
      await expectation;
    });

    test('simulateDisconnected emits disconnected state', () async {
      final expectation = expectLater(
        ble.connectionState,
        emitsInOrder([
          BleConnectionState.connected,
          BleConnectionState.disconnected,
        ]),
      );
      ble.simulateConnected();
      ble.simulateDisconnected();
      await expectation;
    });
  });

  group('injectMessage', () {
    test('injected message appears on messages stream', () async {
      final msg = {
        'type': 'suggestion',
        'sequence_id': 's1',
        'label': 'test',
        'steps': <String>[]
      };
      final expectation = expectLater(ble.messages, emits(msg));
      ble.injectMessage(msg);
      await expectation;
    });

    test('multiple injected messages arrive in order', () async {
      final m1 = {'type': 'sensor', 'current_ma': 300.0};
      final m2 = {'type': 'result', 'success': true};
      final expectation = expectLater(ble.messages, emitsInOrder([m1, m2]));
      ble.injectMessage(m1);
      ble.injectMessage(m2);
      await expectation;
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
        ble.sendCommand('즉석밥 데워줘', source: 'voice'),
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

  group('message stream replacement for private packet decoder', () {
    test('injected complete packet is emitted once', () async {
      final messages = <Map<String, dynamic>>[];
      ble.messages.listen(messages.add);

      ble.injectMessage({'type': 'test'});
      await Future<void>.delayed(Duration.zero);
      expect(messages.length, 1);
      expect(messages.first['type'], 'test');
    });

    test('multiple valid injected packets preserve order', () async {
      final messages = <Map<String, dynamic>>[];
      ble.messages.listen(messages.add);

      ble.injectMessage({'type': 'first'});
      ble.injectMessage({'type': 'ok'});
      await Future<void>.delayed(Duration.zero);
      expect(messages.map((message) => message['type']), ['first', 'ok']);
    });
  });
}
