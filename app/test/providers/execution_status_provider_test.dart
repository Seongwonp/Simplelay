import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/execution_status_provider.dart';

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
      expect(status.message, contains('실제 조작 여부는 확인하지 못했어요'));
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
      // 이걸로 '실행 중'이 되살아나면 사용자는 끝난 일을 진행 중으로 본다.
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
      expect(c.read(executionStatusProvider).message, '실행하지 못했어요.');
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

    test('emergencyStop sets failed phase', () async {
      final c = makeContainer();
      c.read(bleServiceProvider).simulateConnected();
      c.read(executionStatusProvider.notifier).begin(_suggestion);

      await c.read(executionStatusProvider.notifier).emergencyStop();

      expect(c.read(executionStatusProvider).phase, ExecutionPhase.failed);
      expect(c.read(executionStatusProvider).message, contains('긴급 정지'));
    });
  });
}
