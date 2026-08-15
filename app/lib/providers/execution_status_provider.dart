import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/execution_status.dart';
import '../models/suggestion.dart';
import 'ble_provider.dart';

class ExecutionStatusNotifier extends StateNotifier<ExecutionStatus> {
  ExecutionStatusNotifier(this.ref) : super(const ExecutionStatus()) {
    _subscription = ref.read(bleServiceProvider).messages.listen(_onMessage);
  }

  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  void begin(Suggestion suggestion) {
    state = ExecutionStatus(
      sequenceId: suggestion.sequenceId,
      label: suggestion.label,
      steps: suggestion.steps,
      phase: ExecutionPhase.waiting,
      message: '승인 전송 완료',
    );
  }

  void _onMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'sensor':
        final rawStatus = message['status'] as String?;
        final nextPhase = switch (rawStatus) {
          'retrying' => ExecutionPhase.retrying,
          'failed' => ExecutionPhase.failed,
          _ => ExecutionPhase.running,
        };
        state = state.copyWith(
          currentMa: (message['current_ma'] as num?)?.toDouble(),
          soundDb: (message['sound_db'] as num?)?.toDouble(),
          completedSteps: (message['completed_steps'] as num?)?.toInt(),
          phase: nextPhase,
          message: rawStatus == 'retrying' ? '응답이 없어 다시 시도 중입니다.' : '실행 중',
        );
        return;
      case 'result':
        if (state.sequenceId == null ||
            message['sequence_id'] == state.sequenceId) {
          final success = message['success'] == true;
          state = state.copyWith(
            phase: success ? ExecutionPhase.completed : ExecutionPhase.failed,
            completedSteps: success ? state.steps.length : state.completedSteps,
            message: success ? '실행이 완료되었습니다.' : '실행에 실패했습니다.',
          );
        }
        return;
      default:
        return;
    }
  }

  Future<void> emergencyStop() async {
    await ref.read(bleServiceProvider).emergencyStop();
    state = state.copyWith(
      phase: ExecutionPhase.failed,
      message: '긴급 정지를 전송했습니다.',
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final executionStatusProvider =
    StateNotifierProvider<ExecutionStatusNotifier, ExecutionStatus>(
  ExecutionStatusNotifier.new,
);
