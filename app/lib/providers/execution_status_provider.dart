import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/execution_status.dart';
import '../models/suggestion.dart';
import '../services/rpi_api_service.dart';
import 'ble_provider.dart';
import 'tts_provider.dart';

class ExecutionStatusNotifier extends StateNotifier<ExecutionStatus> {
  ExecutionStatusNotifier(this.ref) : super(const ExecutionStatus()) {
    _subscription = ref.read(bleServiceProvider).messages.listen(_onMessage);
  }

  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _subscription;

  // ── HTTP job 추적 (비동기 job 모델) ──────────────────────────────────────
  // 서버는 실행 접수 시 즉시 job_id를 돌려주고, 진행·완료는 /status 폴링으로
  // 확인한다. BLE 스트림(_onMessage)은 폴백 경로용으로 그대로 남는다.
  Timer? _pollTimer;
  RpiApiService? _httpApi;
  String? _httpJobId;
  DateTime? _lastPollSuccess;
  bool _pollInFlight = false;

  static const _pollInterval = Duration(seconds: 1);
  // 이 시간 동안 /status가 한 번도 응답하지 않으면 서버 유실로 판정하고
  // "실행 중" 화면에 영원히 갇히는 대신 실패로 탈출한다.
  static const _unreachableAfter = Duration(seconds: 30);

  void begin(Suggestion suggestion) {
    _stopHttpTracking();
    state = ExecutionStatus(
      sequenceId: suggestion.sequenceId,
      label: suggestion.label,
      steps: suggestion.steps,
      phase: ExecutionPhase.waiting,
      message: '승인 전송 완료',
    );
  }

  void beginHttpJob({
    required RpiApiService api,
    required String jobId,
    required String label,
    List<String> steps = const [],
  }) {
    _stopHttpTracking();
    _httpApi = api;
    _httpJobId = jobId;
    _lastPollSuccess = DateTime.now();
    state = ExecutionStatus(
      sequenceId: jobId,
      label: label,
      steps: steps,
      phase: ExecutionPhase.running,
      message: '실행 중',
    );
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollHttp());
  }

  Future<void> _pollHttp() async {
    final api = _httpApi;
    final jobId = _httpJobId;
    if (api == null || jobId == null) return;
    if (_pollInFlight) return; // 느린 응답에 요청이 겹겹이 쌓이는 것 방지
    _pollInFlight = true;
    try {
      final status = await api.status();
      _lastPollSuccess = DateTime.now();
      if (!mounted || _httpJobId != jobId) return;

      if (status.running) {
        final retrying = (status.currentAttempt ?? 1) > 1;
        state = state.copyWith(
          completedSteps: status.completedSteps ?? state.completedSteps,
          phase: retrying ? ExecutionPhase.retrying : ExecutionPhase.running,
          message: retrying ? '응답이 없어 다시 시도 중입니다.' : '실행 중',
        );
        return;
      }
      if (status.lastJobId == jobId) {
        // 내 job의 완료 — job_id 대조로 이전 실행 결과를 오인하지 않는다
        final success = status.lastStatus == 'succeeded';
        final stopped = status.lastStatus == 'safety_stopped';
        final message = success
            ? '실행이 완료되었습니다.'
            : stopped
                ? '실행이 중단되었습니다.'
                : '실행에 실패했습니다.';
        state = state.copyWith(
          phase: success ? ExecutionPhase.completed : ExecutionPhase.failed,
          completedSteps: success ? state.steps.length : state.completedSteps,
          message: message,
        );
        _announce(message);
        _stopHttpTracking();
      }
      // running=false인데 lastJobId != jobId → 백그라운드 스레드 시작 전의
      // 짧은 창 — 다음 폴링에서 판정한다.
    } catch (_) {
      final since = _lastPollSuccess;
      if (since != null &&
          DateTime.now().difference(since) > _unreachableAfter) {
        if (mounted) {
          state = state.copyWith(
            phase: ExecutionPhase.failed,
            message: '서버 응답이 없습니다. 연결을 확인해주세요.',
          );
          _announce('서버 응답이 없습니다. 연결을 확인해주세요.');
        }
        _stopHttpTracking();
      }
    } finally {
      _pollInFlight = false;
    }
  }

  void _stopHttpTracking() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _httpApi = null;
    _httpJobId = null;
  }

  /// 실행 결과 음성 안내 — 화면을 보지 않아도 결과를 알 수 있게.
  /// 설정(음성 안내)이 꺼져 있으면 침묵. 실패해도 상태 표시는 그대로 간다.
  void _announce(String message) {
    try {
      if (!ref.read(voiceGuideProvider)) return;
      ref.read(ttsServiceProvider).speak(message);
    } catch (_) {
      // provider dispose 직후 등 — 안내는 보조 채널, 조용히 무시
    }
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
          final resultMessage =
              success ? '실행이 완료되었습니다.' : '실행에 실패했습니다.';
          state = state.copyWith(
            phase: success ? ExecutionPhase.completed : ExecutionPhase.failed,
            completedSteps: success ? state.steps.length : state.completedSteps,
            message: resultMessage,
          );
          _announce(resultMessage);
        }
        return;
      default:
        return;
    }
  }

  Future<void> emergencyStop() async {
    final api = _httpApi;
    if (api != null) {
      // HTTP 추적 중 — 서버에 정지를 요청하고, 종료 판정은 폴링이
      // safety_stopped 결과를 받아서 처리한다(성급한 '정지됨' 표시 방지).
      try {
        await api.stop();
        state = state.copyWith(message: '정지 요청을 보냈습니다.');
      } catch (_) {
        state = state.copyWith(message: '정지 요청을 보내지 못했어요. 다시 시도해주세요.');
      }
      return;
    }
    await ref.read(bleServiceProvider).emergencyStop();
    state = state.copyWith(
      phase: ExecutionPhase.failed,
      message: '긴급 정지를 전송했습니다.',
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }
}

final executionStatusProvider =
    StateNotifierProvider<ExecutionStatusNotifier, ExecutionStatus>(
  ExecutionStatusNotifier.new,
);
