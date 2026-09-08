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
  label: '우유 데우기',
  steps: ['BT-08', 'BT-03', 'BT-05'],
);

void main() {
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
      expect(status.label, '우유 데우기');
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
      expect(status.message, '버튼 조작을 마쳤어요.');
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
      expect(c.read(executionStatusProvider).message, '실행에 실패했습니다.');
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
