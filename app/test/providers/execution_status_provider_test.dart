import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/services/ble_service.dart';
import 'package:simplelay/services/rpi_api_service.dart';

/// 정지 프레임을 실제로 보낸 것처럼 답하는 블루투스(실기기 없이).
class _SentBle extends BleService {
  int stops = 0;
  @override
  Future<bool> emergencyStop() async {
    stops++;
    return true;
  }
}

ProviderContainer makeContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

const _suggestion = Suggestion(
  sequenceId: 'exec-001',
  label: '즉석밥 데우기',
  steps: ['BT-08', 'BT-03', 'BT-05'],
);

void main() {
  // 실행 시작이 설정(데모 모드)을 읽게 되면서 플랫폼 채널을 탄다.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExecutionStatusNotifier', () {
    test('initially idle with no data', () {
      final c = makeContainer();
      final status = c.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.idle);
      expect(status.label, isNull);
      expect(status.steps, isEmpty);
    });

    test('begin sets waiting phase with suggestion data', () {
      final c = makeContainer();
      c.read(executionStatusProvider.notifier).begin(_suggestion);
      final status = c.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.waiting);
      expect(status.label, '즉석밥 데우기');
      expect(status.steps, ['BT-08', 'BT-03', 'BT-05']);
      expect(status.sequenceId, 'exec-001');
    });

    test('sensor message updates current_ma, sound_db, completedSteps', () async {
      final c = makeContainer();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      c.read(bleServiceProvider).injectMessage({
        'type': 'sensor',
        'current_ma': 320.0,
        'sound_db': 45.0,
        'status': 'running',
        'completed_steps': 1,
      });
      await Future<void>.delayed(Duration.zero);

      final status = c.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.running);
      expect(status.currentMa, 320.0);
      expect(status.soundDb, 45.0);
      expect(status.completedSteps, 1);
    });

    test('sensor with retrying status sets retrying phase', () async {
      final c = makeContainer();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      c.read(bleServiceProvider).injectMessage({
        'type': 'sensor',
        'current_ma': 0.0,
        'sound_db': 0.0,
        'status': 'retrying',
        'completed_steps': 0,
      });
      await Future<void>.delayed(Duration.zero);

      expect(c.read(executionStatusProvider).phase, ExecutionPhase.retrying);
    });

    test('result success sets completed phase and all steps done', () async {
      final c = makeContainer();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      c.read(bleServiceProvider).injectMessage({
        'type': 'result',
        'sequence_id': 'exec-001',
        'success': true,
      });
      await Future<void>.delayed(Duration.zero);

      final status = c.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.completed);
      expect(status.completedSteps, 3);
      // BLE 경로는 실행 환경(real/mock)을 말해주지 않는다 -- 모르는 것을
      // 아는 척하지 않고 HTTP 경로와 같은 규칙(finishedMessage)으로 말한다.
      expect(status.message, contains('움직이는지는 집에서 확인이 필요해요'));
      expect(status.message, isNot(contains('마쳤어요')));
      expect(status.message, isNot(contains('켜졌는지')));
    });

    test('BLE 결과는 success만 보고 버튼 조작 완료라고 단정하지 않는다', () async {
      final c = makeContainer();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      c.read(bleServiceProvider).injectMessage({
        'type': 'result',
        'sequence_id': 'exec-001',
        'success': true,
      });
      await Future<void>.delayed(Duration.zero);

      final status = c.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.completed);
      expect(status.message, isNot(contains('버튼 조작을 마쳤어요')));
      // 확인 근거를 모르므로 경로·확인 수준 칩도 지어내지 않는다.
      expect(status.outcome, isNull);
      expect(status.route, isNull);
    });

    test('종료된 실행은 늦게 온 센서 메시지로 되살아나지 않는다', () async {
      final c = makeContainer();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      c.read(bleServiceProvider).injectMessage({
        'type': 'result',
        'sequence_id': 'exec-001',
        'success': false,
      });
      await Future<void>.delayed(Duration.zero);
      expect(c.read(executionStatusProvider).phase, ExecutionPhase.failed);

      // 정지·완료 뒤 다른 작업의 센서 메시지가 늦게 도착하는 상황.
      // 이걸로 '하는 중이에요'이 되살아나면 사용자는 끝난 일을 진행 중으로 본다.
      c.read(bleServiceProvider).injectMessage({
        'type': 'sensor',
        'status': 'running',
        'current_ma': 300,
      });
      await Future<void>.delayed(Duration.zero);

      expect(c.read(executionStatusProvider).phase, ExecutionPhase.failed);
    });

    test('result failure sets failed phase', () async {
      final c = makeContainer();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      c.read(bleServiceProvider).injectMessage({
        'type': 'result',
        'sequence_id': 'exec-001',
        'success': false,
      });
      await Future<void>.delayed(Duration.zero);

      expect(c.read(executionStatusProvider).phase, ExecutionPhase.failed);
      // BLE 결과는 접수·전송 여부를 말하지 않는다 — 시작 못 함으로 단정하지 않는다(평가 M4).
      expect(c.read(executionStatusProvider).message, '끝까지 하지 못했어요. 집에서 가전을 확인해야 해요.');
    });

    test('result for different sequenceId is ignored', () async {
      final c = makeContainer();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      c.read(bleServiceProvider).injectMessage({
        'type': 'result',
        'sequence_id': 'other-seq',
        'success': true,
      });
      await Future<void>.delayed(Duration.zero);

      expect(c.read(executionStatusProvider).phase, ExecutionPhase.waiting);
    });

    // 검토 10/19(10): 이 폰이 BLE 실행을 시작하지 않았는데 늦게 온(다른 실행·다른 단말의) 결과·센서 프레임이
    // 쉬는 화면을 '끝났어요'·'하는 중'으로 바꿨다.
    test('이 폰이 시작하지 않은 BLE 결과·센서는 쉬는 화면을 바꾸지 않는다', () async {
      final c = makeContainer();
      c.read(executionStatusProvider);

      c.read(bleServiceProvider).injectMessage({
        'type': 'result',
        'sequence_id': 'someone-else',
        'success': true,
      });
      c.read(bleServiceProvider).injectMessage({
        'type': 'sensor',
        'status': 'running',
        'current_ma': 300,
      });
      await Future<void>.delayed(Duration.zero);

      expect(c.read(executionStatusProvider).phase, ExecutionPhase.idle);
    });

    test('emergencyStop sets failed phase', () async {
      final c = makeContainer();
      c.read(bleServiceProvider).simulateConnected();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      await c.read(executionStatusProvider.notifier).emergencyStop();

      expect(c.read(executionStatusProvider).phase, ExecutionPhase.failed);
      expect(c.read(executionStatusProvider).message, contains('정지'));
    });

    // 10/8 리뷰 LOW: 모의 BLE는 아무것도 보내지 않는다 — 음성 '멈춰'가 이것을
    // 보낸 것으로 치면 다시 듣지 않는다. 화면 표시는 그대로 둔다.
    test('모의 BLE에서는 정지를 보낸 것으로 치지 않는다(화면 표시는 그대로)', () async {
      final c = makeContainer();
      c.read(bleServiceProvider).simulateConnected();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      final sent =
          await c.read(executionStatusProvider.notifier).emergencyStop();

      expect(sent, isFalse);
      expect(c.read(executionStatusProvider).phase, ExecutionPhase.failed);
      // 보낸 것이 없으니 '멈추라고 했어요'라고 하지 않는다(검토 10/19).
      expect(c.read(executionStatusProvider).message, '연습 연결이라 실제로는 정지를 보내지 않았어요.');
    });

    // 검토 10/19(4): 블루투스가 끊겨 정지 프레임을 못 보내면 예외가 그대로 새어 나가 아무 문구도 없이
    // 실제 실행이 계속됐다.
    test('블루투스가 끊겨 정지를 못 보내면 못 보냈다고 말하고 실행 화면을 남긴다', () async {
      final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(null)]);
      addTearDown(c.dispose);
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      final sent = await c.read(executionStatusProvider.notifier).emergencyStop();

      expect(sent, isFalse);
      final status = c.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.waiting);
      expect(status.message, contains('멈추라고 보내지 못했어요'));
    });

    test('블루투스가 끊기면 설정된 본체로 정지를 보내고, 보낸 뒤에만 보냈다고 한다', () async {
      var stops = 0;
      final api = RpiApiService('http://rpi5.local:8000', client: MockClient((request) async {
        if (request.url.path == '/stop') stops++;
        return http.Response('{"ok": true}', 200);
      }));
      final c = ProviderContainer(overrides: [rpiApiServiceProvider.overrideWithValue(api)]);
      addTearDown(c.dispose);
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      final sent = await c.read(executionStatusProvider.notifier).emergencyStop();

      expect(sent, isTrue);
      expect(stops, 1);
      expect(c.read(executionStatusProvider).message, contains('본체에 멈추라고 보냈어요'));
    });

    // 검토 10/19(4): 블루투스로 정지를 보낸 것만으로 끝난 단계(failed)가 돼, 정지 띠·음성 정지가 사라졌다 — 본체까지 정지가
    // 닿지 않았어도 다시 멈출 길이 없었다.
    test('블루투스 정지를 보내도 결과가 올 때까지 끝나지 않은 단계로 정지를 남긴다', () async {
      final ble = _SentBle();
      final c = ProviderContainer(overrides: [
        bleServiceProvider.overrideWithValue(ble),
        rpiApiServiceProvider.overrideWithValue(null),
      ]);
      addTearDown(c.dispose);
      final n = c.read(executionStatusProvider.notifier);
      n.begin(_suggestion);

      expect(await n.emergencyStop(), isTrue);
      var status = c.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.unknown, reason: '정지 띠·음성 정지가 남는 단계');
      expect(status.message, ExecutionStatusNotifier.bleStopSentNotice);

      // 다시 누를 수 있다.
      await n.emergencyStop();
      expect(ble.stops, 2);

      // 다른 실행의 결과는 받지 않고, 같은 실행의 결과가 오면 끝난다.
      ble.injectMessage({'type': 'result', 'sequence_id': 'other', 'success': false});
      await Future<void>.delayed(Duration.zero);
      expect(c.read(executionStatusProvider).phase, ExecutionPhase.unknown);
      ble.injectMessage({'type': 'result', 'sequence_id': 'exec-001', 'success': false});
      await Future<void>.delayed(Duration.zero);
      status = c.read(executionStatusProvider);
      expect(status.phase, ExecutionPhase.failed);
    });
  });
}
