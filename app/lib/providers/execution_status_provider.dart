import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/execution_status.dart';
import '../models/suggestion.dart';
import '../services/rpi_api_service.dart';
import 'ble_provider.dart';
import 'demo_provider.dart';
import 'rpi_api_provider.dart';
import 'tts_provider.dart';

// 진행 중이던 job을 기기에 남겨 앱 재시작 후에도 이어서 확인한다.
const _kPendingJobKey = 'pending_job_id';
const _kPendingLabelKey = 'pending_job_label';

class ExecutionStatusNotifier extends StateNotifier<ExecutionStatus> {
  ExecutionStatusNotifier(this.ref) : super(const ExecutionStatus()) {
    _subscription = ref.read(bleServiceProvider).messages.listen(_onMessage);
    _restorePendingJob();
  }

  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  ProviderSubscription<RpiApiService?>? _apiWait;

  // ── HTTP job 추적 (비동기 job 모델) ──────────────────────────────────────
  // 서버는 실행 접수 시 즉시 job_id를 돌려주고, 진행·완료는 /status 폴링으로
  // 확인한다. BLE 스트림(_onMessage)은 폴백 경로용으로 그대로 남는다.
  Timer? _pollTimer;
  RpiApiService? _httpApi;
  String? _httpJobId;
  DateTime? _lastPollSuccess;
  bool _pollInFlight = false;
  // 내 job의 흔적(job_id 또는 last_job_id 일치)이 안 보인 연속 폴링 수 —
  // 시작 직후 짧은 창은 정상이지만, 계속되면(서버 재시작·결과 슬롯 추월
  // 유실) 화면 고착 대신 실패로 탈출한다.
  int _missingPolls = 0;

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
      message: '실행 요청을 보냈어요',
      isDemo: _demoNow(),
    );
  }

  /// 실행 모드를 **시작하는 순간에** 읽는다. 화면이 매번 전역 토글을
  /// 보면, 진행 중에 토글을 건드린 것만으로 이미 시작한 작업의 표시가
  /// 뒤집힌다 -- 실제로 움직이는 작업이 "실제 조작이 아닙니다"가 된다.
  bool _demoNow() {
    try {
      return ref.read(demoModeProvider);
    } catch (_) {
      return false; // provider 정리 직후 등 — 실제로 취급하는 쪽이 안전하다
    }
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
    _missingPolls = 0;
    state = ExecutionStatus(
      sequenceId: jobId,
      label: label,
      steps: steps,
      phase: ExecutionPhase.running,
      message: '실행 중',
      isDemo: _demoNow(),
    );
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollHttp());
    _rememberPendingJob(jobId, label);
  }

  // ── 진행 중 job 보존 ────────────────────────────────────────────────────
  //
  // 실행은 수 초~수십 초 걸리고, 그 사이 앱이 내려갈 수 있다(사용자가 홈으로
  // 나가거나 OS가 정리). 그때 job_id를 잃으면 물리 조작은 계속되는데 화면은
  // "실행한 적 없음"으로 돌아온다 -- 가전 앞에 있는 사람에게 가장 나쁜 상태다.

  Future<void> _rememberPendingJob(String jobId, String label) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPendingJobKey, jobId);
      await prefs.setString(_kPendingLabelKey, label);
    } catch (_) {
      // 보존은 보조 장치 -- 실패해도 이번 실행 추적은 그대로 간다.
    }
  }

  Future<void> _forgetPendingJob() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPendingJobKey);
      await prefs.remove(_kPendingLabelKey);
    } catch (_) {}
  }

  Future<void> _restorePendingJob() async {
    String? jobId;
    String label = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      jobId = prefs.getString(_kPendingJobKey);
      label = prefs.getString(_kPendingLabelKey) ?? '';
    } catch (_) {
      return;
    }
    if (jobId == null || !mounted) return;
    // 이미 새 실행이 시작됐으면 옛 job으로 덮지 않는다.
    if (_httpJobId != null) return;

    final api = ref.read(rpiApiServiceProvider);
    if (api != null) {
      _resumeJob(api, jobId, label);
      return;
    }
    // 서버 주소는 기기에서 비동기로 읽힌다 -- 준비되면 그때 이어붙인다.
    final pendingId = jobId;
    _apiWait = ref.listen<RpiApiService?>(rpiApiServiceProvider, (_, next) {
      if (next == null || !mounted || _httpJobId != null) return;
      _apiWait?.close();
      _apiWait = null;
      _resumeJob(next, pendingId, label);
    });
  }

  /// 재시작 후 이어붙이기. 이미 끝난 job이면 첫 폴링이 완료/실패로 정리하고,
  /// 서버가 응답하지 않으면 기존 규칙대로 '확인 불가'로 빠진다.
  void _resumeJob(RpiApiService api, String jobId, String label) {
    _httpApi = api;
    _httpJobId = jobId;
    _lastPollSuccess = DateTime.now();
    _missingPolls = 0;
    state = ExecutionStatus(
      sequenceId: jobId,
      label: label.isEmpty ? null : label,
      phase: ExecutionPhase.running,
      message: '아까 맡긴 작업을 다시 확인하고 있어요…',
      // 재시작 복원은 실제 서버의 job만 대상으로 한다 -- 모의 실행은
      // 앱 안에서만 살아 있어 남길 것도 이어붙일 것도 없다.
    );
    _pollTimer?.cancel();
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

      // ① 완료 판정을 최우선 — 내 job(J1) 완료 직후 다른 클라이언트의
      // J2가 시작되면 running=true여도 last_job_id는 여전히 J1이다.
      // running을 먼저 보고 return하면 그 완료를 영영 놓친다(추월 레이스).
      if (status.lastJobId == jobId) {
        final success = status.lastStatus == 'succeeded';
        final stopped = status.lastStatus == 'safety_stopped';
        // "실행 완료"는 조리가 끝난 뜻으로 읽힐 수 있다.
        // 우리가 보장하는 것은 버튼 조작까지다.
        final message = success
            ? '버튼 조작을 마쳤어요.'
            : stopped
                ? '실행을 멈췄어요.'
                : '실행하지 못했어요.';
        state = state.copyWith(
          phase: success ? ExecutionPhase.completed : ExecutionPhase.failed,
          completedSteps: success
              ? (state.totalSteps ?? state.steps.length)
              : state.completedSteps,
          message: message,
        );
        _announce(message);
        _stopHttpTracking();
        return;
      }

      // ② 내 job이 실행 중 — 진행 갱신
      if (status.running && status.jobId == jobId) {
        _missingPolls = 0;
        final retrying = (status.currentAttempt ?? 1) > 1;
        state = state.copyWith(
          completedSteps: status.completedSteps ?? state.completedSteps,
          // 폐루프 증거를 그대로 흘려보낸다 -- 여기서 버리면 화면은
          // "빙글빙글 돌다 완료되는 앱"이 된다(차별점이 안 보임).
          currentButton: status.currentButton,
          totalSteps: status.totalSteps,
          applianceId: status.applianceId,
          currentAttempt: status.currentAttempt,
          verificationConfidence: status.verificationConfidence,
          verificationDetail: status.verificationDetail,
          phase: retrying ? ExecutionPhase.retrying : ExecutionPhase.running,
          message: retrying ? '응답이 없어 다시 시도하고 있어요.' : '실행 중',
        );
        return;
      }

      // ③ 내 job의 흔적이 없다 — 시작 전 창(정상, 짧음)이거나 서버
      // 재시작·결과 슬롯 추월 유실. 몇 번은 기다리고, 계속되면 탈출.
      _missingPolls++;
      if (_missingPolls >= 10) {
        // 실패가 아니라 '모름'이다. 가전은 계속 움직이고 있을 수 있으므로
        // 정지·재확인 수단을 남긴 채 사용자에게 직접 확인을 청한다.
        const notice = '연결이 끊겨 동작을 확인할 수 없어요. 가전을 직접 확인해주세요.';
        state = state.copyWith(
          phase: ExecutionPhase.unknown,
          message: notice,
        );
        _announce(notice);
        _stopHttpTracking(keepTarget: true);
      }
    } catch (_) {
      final since = _lastPollSuccess;
      if (since != null &&
          DateTime.now().difference(since) > _unreachableAfter) {
        if (mounted) {
          const notice = '연결이 끊겨 동작을 확인할 수 없어요. 가전을 직접 확인해주세요.';
          state = state.copyWith(
            phase: ExecutionPhase.unknown,
            message: notice,
          );
          _announce(notice);
        }
        _stopHttpTracking(keepTarget: true);
      }
    } finally {
      _pollInFlight = false;
    }
  }

  /// 폴링을 멈춘다.
  ///
  /// [keepTarget]이면 대상(api·job_id)은 남긴다 -- '확인 불가' 상태에서
  /// 정지 요청과 재확인이 계속 가능해야 하기 때문. 여기서 대상을 지우면
  /// emergencyStop이 HTTP 경로를 잃고 BLE로 빠져 실제로 멈추지 못한다.
  void _stopHttpTracking({bool keepTarget = false}) {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (keepTarget) return;
    _httpApi = null;
    _httpJobId = null;
    // 결말이 난 job은 더 이상 이어붙일 것이 없다. '확인 불가'(keepTarget)는
    // 아직 결말이 아니므로 남겨둔다 -- 앱을 다시 열면 또 확인해야 한다.
    _forgetPendingJob();
  }

  /// '확인 불가'에서 사용자가 직접 다시 확인한다.
  void recheck() {
    if (_httpApi == null || _httpJobId == null) return;
    _missingPolls = 0;
    _lastPollSuccess = DateTime.now();
    state = state.copyWith(message: '상태를 다시 확인하고 있어요…');
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollHttp());
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
        // 이미 끝난(또는 확인 불가로 넘어간) 실행을 늦게 도착한 센서
        // 메시지가 '실행 중'으로 되살리면 안 된다 -- 정지 직후 다른
        // 작업의 메시지가 섞이는 경우가 실제로 있다.
        if (state.phase == ExecutionPhase.completed ||
            state.phase == ExecutionPhase.failed ||
            state.phase == ExecutionPhase.unknown) {
          return;
        }
        // 실행을 식별할 수 있으면 내 것인지도 확인한다.
        final sensorSeq = message['sequence_id'];
        if (sensorSeq != null &&
            state.sequenceId != null &&
            sensorSeq != state.sequenceId) {
          return;
        }
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
          message: rawStatus == 'retrying' ? '응답이 없어 다시 시도하고 있어요.' : '실행 중',
        );
        return;
      case 'result':
        if (state.sequenceId == null ||
            message['sequence_id'] == state.sequenceId) {
          final success = message['success'] == true;
          final resultMessage =
              success ? '버튼 조작을 마쳤어요.' : '실행하지 못했어요.';
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
        state = state.copyWith(message: '정지 요청을 보냈어요.');
      } catch (_) {
        state = state.copyWith(message: '정지 요청을 보내지 못했어요. 다시 시도해주세요.');
      }
      return;
    }
    await ref.read(bleServiceProvider).emergencyStop();
    state = state.copyWith(
      phase: ExecutionPhase.failed,
      message: '긴급 정지를 보냈어요.',
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _pollTimer?.cancel();
    _apiWait?.close();
    super.dispose();
  }
}

final executionStatusProvider =
    StateNotifierProvider<ExecutionStatusNotifier, ExecutionStatus>(
  ExecutionStatusNotifier.new,
);
