import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/command_result.dart';
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
// 그 job을 받은 본체(정규화한 주소, 검토 10/19) — 이어서 보기·정지는 그 본체로만 한다. 옛 기록(값 없음)은 지금 본체로 본다.
const _kPendingHubKey = 'pending_job_hub';

String _hubIdOf(RpiApiService api) => normalizeRpiUrl(api.baseUrl);

class ExecutionStatusNotifier extends StateNotifier<ExecutionStatus> {
  ExecutionStatusNotifier(this.ref) : super(const ExecutionStatus()) {
    _subscription = ref.read(bleServiceProvider).messages.listen(_onMessage);
    _restorePendingJob();
  }

  final Ref ref;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  ProviderSubscription<RpiApiService?>? _apiWait;

  // 실행을 시작할 때마다 오른다 — 재시작 복원이 기다리는 사이 새 실행이 시작되면 옛 job을 이어붙이지 않는다
  // (검토 10/19: BLE 실행은 _httpJobId를 남기지 않아, 늦게 준비된 주소가 옛 job으로 새 실행 화면을 덮었다).
  int _executionGen = 0;

  // 이 폰이 BLE 실행을 시작했는가([begin]). 아니면 BLE 실행 프레임을 받지 않는다 — 쉬는 화면이나 HTTP job 화면을
  // 늦게 온 다른 실행의 결과·센서가 '끝났어요'·'하는 중'으로 바꿨다(검토 10/19).
  bool _bleTracking = false;

  // 남은 job이 지금 설정과 **다른 본체**에서 받은 것이다(검토 10/19) — 지금 본체로 이어서 보거나 전체 정지를 보내면 그 본체의
  // 상관없는 실행을 멈춘다. 그 본체 주소로 돌아올 때까지 모름으로 두고, 정지는 보내지 않고 이유를 말한다.
  String? _foreignHub;

  /// 새 실행이 시작됐다 — 기다리던 복원을 버린다.
  void _supersedeRestore() {
    _executionGen++;
    _apiWait?.close();
    _apiWait = null;
    _foreignHub = null;
  }

  // ── HTTP job 추적 (비동기 job 모델) ──────────────────────────────────────
  // 서버는 실행 접수 시 즉시 job_id를 돌려주고, 진행·완료는 그 job의 조회(GET /jobs/{job_id}, 옛 본체는 /status) 폴링으로
  // 확인한다. BLE 스트림(_onMessage)은 폴백 경로용으로 그대로 남는다.
  Timer? _pollTimer;
  RpiApiService? _httpApi;
  String? _httpJobId;
  // 따라가는 실행이 루틴이면(본체가 GET /jobs에 routine_run_id를 실었다, 검토 10/19) 그 루틴 실행 번호와 지금 구간의 실행 번호.
  // 정지는 그 루틴만 멈추는 /routines/runs/{id}/stop으로 보낸다(모르면 종전처럼 본체 전체 /stop).
  String? _routineRunId;
  String? _routineSegmentJobId;
  DateTime? _lastPollSuccess;
  bool _pollInFlight = false;
  // 내 job의 흔적(job_id 또는 last_job_id 일치)이 안 보인 연속 폴링 수 —
  // 시작 직후 짧은 창은 정상이지만, 계속되면(서버 재시작·결과 슬롯 추월
  // 유실) 화면 고착 대신 실패로 탈출한다.
  int _missingPolls = 0;

  static const _pollInterval = Duration(seconds: 1);

  // 결과가 먼저 오고 정지 확인 단계가 늦게 오는 경우의 짧은 후속 조회(평가 2026-10-13 M1).
  // 화면 문장만 고치고 음성은 다시 말하지 않는다. 정지 전송과는 무관하다(이미 나갔다).
  Timer? _stopFollowTimer;
  static const _stopFollowInterval = Duration(seconds: 1);
  static const _stopFollowTries = 3;
  // 이 시간 동안 /status가 한 번도 응답하지 않으면 서버 유실로 판정하고
  // "실행 중" 화면에 영원히 갇히는 대신 실패로 탈출한다.
  static const _unreachableAfter = Duration(seconds: 30);

  void begin(Suggestion suggestion) {
    _supersedeRestore();
    _stopHttpTracking();
    _stopFollowTimer?.cancel();
    _endSubmission();
    _bleTracking = true;
    state = ExecutionStatus(
      sequenceId: suggestion.sequenceId,
      // 승인 뒤의 이름 — 질문 문장(purpose)이 아니다(Suggestion.doneLabel).
      label: suggestion.doneLabel(),
      steps: suggestion.steps,
      phase: ExecutionPhase.waiting,
      message: '실행하라고 보냈어요',
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

  /// 접수된 [jobId]를 따라간다. [requestId]는 [beginSubmitting]이 준 번호 — 보내는 사이 정지를 눌렀으면 job_id가 온 지금
  /// 정지를 한 번 더 보낸다(그 정지가 접수보다 먼저 닿아 '하던 일 없음'으로 끝났을 수 있다).
  void beginHttpJob({
    required RpiApiService api,
    required String jobId,
    required String label,
    List<String> steps = const [],
    String? requestId,
  }) {
    // 늦게 온 옛 보냄의 답이다(그사이 다른 보냄·실행이 시작됐다) — 새 실행과 그 정지 대상을 덮지 않는다(검토 10/19).
    if (requestId != null && requestId != _submitRequestId) return;
    final resendStop = requestId != null && _stopWhileSubmitting;
    _supersedeRestore();
    _stopHttpTracking();
    _stopFollowTimer?.cancel();
    _endSubmission();
    _bleTracking = false;
    _httpApi = api;
    _httpJobId = jobId;
    _lastPollSuccess = DateTime.now();
    _missingPolls = 0;
    state = ExecutionStatus(
      sequenceId: jobId,
      label: label,
      steps: steps,
      phase: ExecutionPhase.running,
      message: '하는 중이에요',
      isDemo: _demoNow(),
      requestId: requestId,
    );
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollHttp());
    _rememberPendingJob(jobId, label, _hubIdOf(api));
    if (resendStop) unawaited(emergencyStop());
  }

  // ── 보내는 중(검토 10/19) ────────────────────────────────────────────────
  // 실행 요청(승인·말·버튼)의 접수 답(job_id)을 기다리는 사이에도 본체는 이미 받아 움직이고 있을 수 있다. 예전에는 답이 올
  // 때까지(최대 시간 초과까지) 실행 상태가 없어 정지 띠가 없었다. 보내기 **전에** 이 단계로 들어가 정지를 남기고, 그사이 누른
  // 정지는 바로 본체 전체 정지로 보낸 뒤 job_id가 오거나 복구가 그 실행을 찾으면 한 번 더 보낸다.
  String? _submitRequestId;
  bool _stopWhileSubmitting = false;
  // 답을 모르는 보냄을 요청 번호로 찾는가 — 다시 확인([recheck])도 같은 방식으로 찾는다. 본체가 조회를 모른다고 답했을
  // 때만 꺼진다(그때만 그냥 '돌고 있는 실행'을 따라간다, 검토 10/19).
  bool _recoverByRequest = false;
  _Tracking? _beforeSubmit;
  static const submittingNotice = '보내는 중이에요';
  static const waitAdmissionNotice = '아까 보낸 것의 답을 기다리는 중이에요. 답이 온 뒤 다시 해 주세요.';
  static const stopWhileSubmittingNotice = '멈추라고 보냈어요. 받았다는 답이 오면 한 번 더 보낼게요.';
  static final _random = Random();

  /// 요청 번호 — 보낼 때마다 새로 짓는다. 실행 요청에 `client_request_id`로 싣는다(새 본체는 같은 번호를 한 번만 접수).
  static String newRequestId() =>
      'app-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${_random.nextInt(1 << 32).toRadixString(36)}';

  /// 접수 답을 기다리는 중이다 — 답이 오기 전에는 새 실행을 보내지 않는다(옛 답이 새 실행을 덮거나 두 번 보내진다).
  bool get admissionInFlight =>
      _submitRequestId != null && (state.sequenceId?.startsWith('submit-') ?? false);

  /// 실행 요청을 보내기 **직전에** 부른다. 돌려준 요청 번호로 결과에 따라 [beginHttpJob]·[beginSubmissionUnknown]·
  /// [abandonSubmission] 중 하나를 부른다.
  String beginSubmitting({
    required RpiApiService api,
    required String label,
    List<String> steps = const [],
  }) {
    final before = _Tracking(state, _httpApi, _httpJobId, _foreignHub, _routineRunId, _routineSegmentJobId);
    _supersedeRestore();
    _stopHttpTracking(keepPending: true);
    _stopFollowTimer?.cancel();
    _bleTracking = false;
    _httpApi = api;
    final requestId = newRequestId();
    _submitRequestId = requestId;
    _stopWhileSubmitting = false;
    _beforeSubmit = before;
    state = ExecutionStatus(
      sequenceId: 'submit-$requestId',
      label: label,
      steps: steps,
      phase: ExecutionPhase.waiting,
      message: submittingNotice,
      isDemo: _demoNow(),
      requestId: requestId,
    );
    return requestId;
  }

  /// 본체가 답해 받지 않았다(거절) — 보내기 전 화면으로 되돌린다. 그 사이 다른 실행이 시작됐으면 아무것도 하지 않는다.
  void abandonSubmission(String requestId) {
    if (requestId != _submitRequestId) return;
    final before = _beforeSubmit;
    _endSubmission();
    if (!mounted || before == null) return;
    _httpApi = before.api;
    _httpJobId = before.jobId;
    _foreignHub = before.foreignHub;
    _routineRunId = before.routineRunId;
    _routineSegmentJobId = before.routineSegmentJobId;
    state = before.state;
    final api = before.api;
    final jobId = before.jobId;
    if (api != null && jobId != null && !_finished) {
      // 보내기 전에 따라가던 실행 — 다시 따라간다(정지·확인 대상이 사라지지 않게).
      _lastPollSuccess = DateTime.now();
      _missingPolls = 0;
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(_pollInterval, (_) => _pollHttp());
    } else if (_finished || before.state.phase == ExecutionPhase.idle) {
      _httpApi = null;
      _httpJobId = null;
    }
  }

  void _endSubmission() {
    _submitRequestId = null;
    _stopWhileSubmitting = false;
    _recoverByRequest = false;
    _beforeSubmit = null;
  }

  // ── 보냈는데 접수 답을 못 받은 실행(검토 10/19) ──────────────────────────
  // 시간 초과·연결 끊김으로 접수 응답이 사라졌다 — 본체가 이미 받아 시작했을 수 있다(job_id 모름). '보내지 못했다'로 끝내지
  // 않고 '모름'으로 두어 정지(본체 전체 /stop)를 그 본체로 남기고, 잠깐 /status를 보며 돌고 있는 실행이 보이면 그 실행을
  // 이어서 본다. [recoverJobId]는 같은 요청을 다시 물어 job_id를 받는 길이다(제안 승인 — 이미 승인된 카드면 본체가 같은
  // job_id를 준다). 다시 보내면 두 번 눌리는 요청(버튼 누르기)에는 주지 않는다.
  // [byRequest]면 그 요청에 요청 번호를 실었다 — 새 본체에는 그 번호로 접수한 실행을 묻고(GET /jobs/by-request), 그냥 '돌고
  // 있는 실행'은 따라가지 않는다(자동 실행·다른 단말의 실행일 수 있다 — 엉뚱한 결과를 보이고 정지로 남의 실행을 멈췄다, 검토
  // 10/19). 본체가 그 번호를 모르면 접수하지 않은 것이다. 옛 본체(조회 없음)만 종전처럼 재질의·상태로 찾는다.
  Timer? _recoverTimer;
  static const _recoverTries = 15;
  static const _recoverJobTries = 3;
  static const bleStopSentNotice = '멈추라고 보냈어요. 멈췄다는 답은 아직 없어요. 멈추지 않으면 정지를 다시 눌러 주세요.';
  static const submissionUnknownNotice = '보냈는데 답이 없어 시작됐는지 몰라요. 가전을 보고, 움직이면 정지를 눌러 주세요.';
  static const submissionNotAcceptedNotice = '본체가 이 요청을 받지 않았어요. 가전이 그대로면 다시 해 주세요.';

  /// [requestId]는 [beginSubmitting]이 준 번호 — 보내는 사이 누른 정지는 지금 한 번 더 보내고, 복구가 실행을 찾으면 또 보낸다.
  void beginSubmissionUnknown({
    required RpiApiService api,
    required String label,
    List<String> steps = const [],
    Future<String> Function()? recoverJobId,
    String? requestId,
    bool byRequest = false,
  }) {
    // 늦게 온 옛 보냄의 실패다 — 보낸 적 없는 번호를 지어 새 실행을 덮지 않는다(검토 10/19).
    if (requestId != null && requestId != _submitRequestId) return;
    final continuing = requestId != null;
    final resendStop = continuing && _stopWhileSubmitting;
    _supersedeRestore();
    _stopHttpTracking();
    _stopFollowTimer?.cancel();
    _bleTracking = false;
    _httpApi = api;
    final id = continuing ? requestId : newRequestId();
    // 답을 모르는 동안에도 같은 보냄이다 — 정지를 누르면 기억해 두었다가 복구가 실행을 찾을 때 다시 보낸다. 되돌릴 화면은 없다.
    _submitRequestId = id;
    _stopWhileSubmitting = resendStop;
    _recoverByRequest = byRequest && continuing;
    _beforeSubmit = null;
    final key = 'unsent-${DateTime.now().microsecondsSinceEpoch}';
    state = ExecutionStatus(
      sequenceId: key,
      label: label,
      steps: steps,
      phase: ExecutionPhase.unknown,
      message: submissionUnknownNotice,
      isDemo: _demoNow(),
      requestId: id,
    );
    _announce(submissionUnknownNotice);
    _recoverSubmission(api, key, label, steps, recoverJobId);
    if (resendStop) unawaited(emergencyStop());
  }

  void _recoverSubmission(RpiApiService api, String key, String label, List<String> steps,
      Future<String> Function()? recoverJobId) {
    final requestId = state.requestId;
    _recoverTimer?.cancel();
    var recover = recoverJobId;
    var tries = 0;
    var jobTries = 0;
    var inFlight = false;
    _recoverTimer = Timer.periodic(_pollInterval, (timer) async {
      if (inFlight) return;
      if (!mounted || state.sequenceId != key || _httpJobId != null || tries >= _recoverTries) {
        timer.cancel();
        return;
      }
      tries++;
      inFlight = true;
      try {
        if (_recoverByRequest && requestId != null) {
          final found = await api.jobByRequest(requestId);
          if (!mounted || !timer.isActive || state.sequenceId != key) return;
          switch (found.kind) {
            case RpiRequestLookupKind.found:
              timer.cancel();
              beginHttpJob(api: api, jobId: found.jobId!, label: label, steps: steps, requestId: requestId);
              return;
            case RpiRequestLookupKind.unknown:
              timer.cancel();
              _submissionNotAccepted();
              return;
            case RpiRequestLookupKind.unsupported:
              _recoverByRequest = false; // 옛 본체 — 아래 종전 방식으로(다시 확인도)
          }
        }
        final ask = recover;
        if (ask != null && jobTries < _recoverJobTries) {
          jobTries++;
          try {
            final jobId = await ask();
            if (!mounted || !timer.isActive || state.sequenceId != key) return;
            timer.cancel();
            beginHttpJob(api: api, jobId: jobId, label: label, steps: steps, requestId: requestId);
            return;
          } on RpiApiException {
            recover = null; // 본체가 답했다(이미 승인됨·거절) — 다시 묻지 않고 상태로만 찾는다.
          } catch (_) {
            // 또 답이 없다 — 다음 차례에 다시 묻는다.
          }
        }
        final status = await api.status();
        if (!mounted || !timer.isActive || state.sequenceId != key) return;
        // 루틴이 도는 중이면(구간 사이 기다림 포함, 새 본체) 지금 구간이 아니라 루틴 첫 번호를 따라간다 — 구간 하나의 끝을
        // 루틴의 끝으로 말하지 않고, 정지는 그 루틴만 멈추는 경로로 간다(검토 10/19). 옛 본체(필드 없음)는 종전대로.
        final running = status.routineRunId ?? (status.running ? status.jobId : null);
        if (running != null) {
          timer.cancel();
          beginHttpJob(api: api, jobId: running, label: label, steps: steps, requestId: requestId);
        }
      } catch (_) {
        // 통신 실패 — 남은 횟수 안에서 다시 본다. 정지는 그대로 남는다.
      } finally {
        inFlight = false;
      }
    });
  }

  /// 새 본체가 이 요청 번호를 모른다 — 접수하지 않았다(실행 없음). 모름을 거두고 못 함으로 알린다.
  void _submissionNotAccepted() {
    _endSubmission();
    _httpApi = null;
    state = state.copyWith(phase: ExecutionPhase.failed, message: submissionNotAcceptedNotice);
    _announce(submissionNotAcceptedNotice);
  }

  // ── 진행 중 job 보존 ────────────────────────────────────────────────────
  //
  // 실행은 수 초~수십 초 걸리고, 그 사이 앱이 내려갈 수 있다(사용자가 홈으로
  // 나가거나 OS가 정리). 그때 job_id를 잃으면 물리 조작은 계속되는데 화면은
  // "실행한 적 없음"으로 돌아온다 -- 가전 앞에 있는 사람에게 가장 나쁜 상태다.

  Future<void> _rememberPendingJob(String jobId, String label, String hub) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPendingJobKey, jobId);
      await prefs.setString(_kPendingLabelKey, label);
      await prefs.setString(_kPendingHubKey, hub);
    } catch (_) {
      // 보존은 보조 장치 -- 실패해도 이번 실행 추적은 그대로 간다.
    }
  }

  Future<void> _forgetPendingJob() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kPendingJobKey);
      await prefs.remove(_kPendingLabelKey);
      await prefs.remove(_kPendingHubKey);
    } catch (_) {}
  }

  Future<void> _restorePendingJob() async {
    final gen = _executionGen;
    String? jobId;
    String label = '';
    String? hub;
    try {
      final prefs = await SharedPreferences.getInstance();
      jobId = prefs.getString(_kPendingJobKey);
      label = prefs.getString(_kPendingLabelKey) ?? '';
      hub = prefs.getString(_kPendingHubKey);
    } catch (_) {
      return;
    }
    if (jobId == null || !mounted) return;
    // 이미 새 실행이 시작됐으면(HTTP든 BLE든) 옛 job으로 덮지 않는다.
    if (gen != _executionGen || _httpJobId != null) return;

    bool sameHub(RpiApiService api) => hub == null || _hubIdOf(api) == hub;
    final api = ref.read(rpiApiServiceProvider);
    if (api != null && sameHub(api)) {
      _resumeJob(api, jobId, label);
      return;
    }
    final pendingId = jobId;
    if (api != null) _showForeignHubJob(pendingId, label, hub!);
    // 서버 주소는 기기에서 비동기로 읽힌다 -- 준비되면(다른 본체면 그 본체로 돌아오면) 그때 이어붙인다.
    _apiWait = ref.listen<RpiApiService?>(rpiApiServiceProvider, (_, next) {
      if (next == null || !mounted) return;
      if (gen != _executionGen || _httpJobId != null) {
        _apiWait?.close();
        _apiWait = null;
        return;
      }
      if (!sameHub(next)) {
        _showForeignHubJob(pendingId, label, hub!);
        return;
      }
      _apiWait?.close();
      _apiWait = null;
      final waitingForeign = _foreignHub != null && state.sequenceId == pendingId;
      if (state.phase != ExecutionPhase.idle && !waitingForeign) return;
      _resumeJob(next, pendingId, label);
    });
  }

  /// 남은 job이 다른 본체의 것이다 — 이어서 보지도, 지금 본체로 멈추지도 않는다(기록은 남겨 그 본체로 돌아오면 이어서 본다).
  void _showForeignHubJob(String jobId, String label, String hub) {
    _foreignHub = hub;
    state = ExecutionStatus(
      sequenceId: jobId,
      label: label.isEmpty ? null : label,
      phase: ExecutionPhase.unknown,
      message: foreignHubNotice,
    );
  }

  static const routineStopSentNotice = '루틴을 멈추라고 보냈어요. 남은 차례는 보내지 않아요.';

  static const foreignHubNotice = '아까 맡긴 일은 지금과 다른 본체에 보냈어요. 그 본체 주소로 바꾸면 이어서 확인할게요. '
      '가전이 움직이면 가전에서 직접 멈춰 주세요.';
  static const foreignHubStopNotice = '아까 일은 다른 본체에 맡겨서 여기서는 멈출 수 없어요. '
      '그 본체 주소로 바꾸거나 가전에서 직접 멈춰 주세요.';

  /// 재시작 후 이어붙이기. 이미 끝난 job이면 첫 폴링이 완료/실패로 정리하고,
  /// 서버가 응답하지 않으면 기존 규칙대로 '확인 불가'로 빠진다.
  void _resumeJob(RpiApiService api, String jobId, String label) {
    _endSubmission();
    _foreignHub = null;
    _bleTracking = false;
    _httpApi = api;
    _httpJobId = jobId;
    _routineRunId = null;
    _routineSegmentJobId = null;
    _lastPollSuccess = DateTime.now();
    _missingPolls = 0;
    state = ExecutionStatus(
      sequenceId: jobId,
      label: label.isEmpty ? null : label,
      phase: ExecutionPhase.running,
      message: '아까 맡긴 일을 다시 보는 중이에요…',
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
      // 내 job만 묻는다 — /status의 마지막 결과 한 칸은 그 사이 다른 실행이 끝나면 덮인다(검토 10/19). 옛 본체는 /status.
      final status = await api.jobStatus(jobId);
      if (!mounted || _httpJobId != jobId) return;
      _lastPollSuccess = DateTime.now();

      // ⓪ 따라가던 번호가 루틴의 2번째 이후 구간이다(새 본체가 routine_run_id를 실었다, 검토 10/19) — 그 구간의 끝은 루틴의
      // 끝이 아니다. 루틴 첫 번호로 갈아타 루틴이 다 끝날 때까지 하는 중으로 보이고 정지는 그 루틴만 멈춘다.
      final root = status.routineRunId;
      if (root != null && root != jobId) {
        _followRoutineRoot(api, root, status);
        return;
      }

      // ① 완료 판정을 최우선 — 내 job(J1) 완료 직후 다른 클라이언트의
      // J2가 시작되면 running=true여도 last_job_id는 여전히 J1이다.
      // running을 먼저 보고 return하면 그 완료를 영영 놓친다(추월 레이스).
      // 끝남은 본체가 끝났다고 할 때만 — 루틴은 구간 사이 기다림도 끝나지 않은 것이다(finished=false). /status·옛 본체는 null.
      final routine = status.routineRunId != null;
      if (status.lastJobId == jobId && status.finished != false) {
        final kind = resultKindOf(
            outcome: status.lastOutcome, status: status.lastStatus);
        final success = kind == ResultKind.success;
        final message = finishedMessage(
          kind: kind,
          executionMode: status.lastExecutionMode,
          route: status.lastRoute,
          receipt: status.lastReceipt,
          confirmation: status.lastConfirmation,
          detail: status.lastDetail,
          // 이 job의 정지 단계만(평가 H1 — 다른 실행의 정지 보고를 싣지 않는다).
          stopLevel: status.stopLevelOf(jobId),
          stopAckMs: status.stopAckMsOf(jobId),
          abortReason: status.lastAbortReason,
        );
        state = state.copyWith(
          executionMode: status.lastExecutionMode,
          phase: switch (kind) {
            ResultKind.success => ExecutionPhase.completed,
            ResultKind.unconfirmed => ExecutionPhase.unconfirmed,
            _ => ExecutionPhase.failed,
          },
          completedSteps: success
              ? (state.totalSteps ?? state.steps.length)
              : state.completedSteps,
          // 끝난 실행의 누른 순서 이름(서버 last_buttons) — 실행 중 못 본 칸도 이름이 생긴다. 루틴의 last_buttons는 마지막
          // 구간의 것뿐이라 루틴 전체 칸에 싣지 않는다.
          stepNames: !routine && (status.lastButtons?.isNotEmpty ?? false)
              ? [for (final b in status.lastButtons!) b.button]
              : null,
          message: message,
          outcome: status.lastOutcome,
          route: status.lastRoute,
          receipt: status.lastReceipt,
          confirmation: status.lastConfirmation,
          detail: status.lastDetail,
          retryCount: status.lastRetryCount,
          operationConfirmed: status.lastOperationConfirmed,
          operationSource: status.lastOperationSource,
          operationDetail: status.lastOperationDetail,
          abortReason: status.lastAbortReason,
        );
        _announce(message);
        _stopHttpTracking();
        if (kind == ResultKind.stopped && status.stopLevelOf(jobId) == null) {
          _followStopReport(api, jobId);
        }
        return;
      }

      // ② 내 job이 실행 중 — 진행 갱신
      if (status.running && status.jobId == jobId && routine) {
        // 루틴(검토 10/19) — 구간 사이 기다림도 하는 중이다. 구간 하나의 칸 수·번호는 루틴 전체 칸과 맞지 않아 싣지 않고,
        // 지금 구간 순번과 그 구간의 폐루프 증거만 싣는다.
        _missingPolls = 0;
        _routineRunId = status.routineRunId;
        _routineSegmentJobId = status.routineSegmentJobId;
        final retrying = (status.currentAttempt ?? 1) > 1;
        final segment = status.routineSegment;
        state = state.copyWith(
          executionMode: status.executionMode,
          currentButton: status.currentButton,
          applianceId: status.applianceId,
          currentAttempt: status.currentAttempt,
          verificationConfidence: status.verificationConfidence,
          verificationDetail: status.verificationDetail,
          phase: retrying ? ExecutionPhase.retrying : ExecutionPhase.running,
          message: retrying
              ? '답이 없어 다시 해 보는 중이에요.'
              : segment == null
                  ? '루틴을 하는 중이에요'
                  : '루틴 $segment번째 차례를 하는 중이에요',
        );
        return;
      }
      if (status.running && status.jobId == jobId) {
        _missingPolls = 0;
        final retrying = (status.currentAttempt ?? 1) > 1;
        final index = status.completedSteps ?? state.completedSteps;
        state = state.copyWith(
          executionMode: status.executionMode,
          completedSteps: status.completedSteps ?? state.completedSteps,
          // 서버는 끝낸 칸 이름을 주지 않는다 — 본 '지금 버튼'을 그 칸 번호에 묶어 둔다(키오스크와 같은 뜻, 10/19).
          stepNames: _withStepName(state.stepNames, index, status.currentButton),
          // 폐루프 증거를 그대로 흘려보낸다 -- 여기서 버리면 화면은
          // "빙글빙글 돌다 완료되는 앱"이 된다(차별점이 안 보임).
          currentButton: status.currentButton,
          totalSteps: status.totalSteps,
          applianceId: status.applianceId,
          currentAttempt: status.currentAttempt,
          verificationConfidence: status.verificationConfidence,
          verificationDetail: status.verificationDetail,
          phase: retrying ? ExecutionPhase.retrying : ExecutionPhase.running,
          message: retrying ? '답이 없어 다시 해 보는 중이에요.' : '하는 중이에요',
        );
        return;
      }

      // ③ 내 job의 흔적이 없다 — 시작 전 창(정상, 짧음)이거나 서버
      // 재시작·결과 슬롯 추월 유실. 몇 번은 기다리고, 계속되면 탈출.
      _missingPolls++;
      if (_missingPolls >= 10) {
        // 실패가 아니라 '모름'이다. 가전은 계속 움직이고 있을 수 있으므로
        // 정지·재확인 수단을 남긴 채 사용자에게 직접 확인을 청한다.
        const notice = '연결이 끊겨 어떻게 됐는지 몰라요. 집에서 가전을 확인해야 해요.';
        state = state.copyWith(
          phase: ExecutionPhase.unknown,
          message: notice,
        );
        _announce(notice);
        _stopHttpTracking(keepTarget: true);
      }
    } catch (_) {
      if (!mounted || _httpJobId != jobId) return;
      final since = _lastPollSuccess;
      if (since != null &&
          DateTime.now().difference(since) > _unreachableAfter) {
        if (mounted) {
          const notice = '연결이 끊겨 어떻게 됐는지 몰라요. 집에서 가전을 확인해야 해요.';
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

  /// 구간 번호를 따라가다 그 구간이 속한 루틴의 첫 번호 [root]로 갈아탄다. 결과는 다음 조회(루틴 전체)가 정한다.
  void _followRoutineRoot(RpiApiService api, String root, RpiStatusResult status) {
    _httpJobId = root;
    _routineRunId = root;
    _routineSegmentJobId = status.routineSegmentJobId;
    _missingPolls = 0;
    final segment = status.routineSegment;
    state = state.copyWith(
      sequenceId: root,
      phase: ExecutionPhase.running,
      message: segment == null ? '루틴을 하는 중이에요' : '루틴 $segment번째 차례를 하는 중이에요',
    );
    _rememberPendingJob(root, state.label ?? '', _hubIdOf(api));
  }

  /// 정지로 끝난 [jobId]의 정지 확인 단계가 결과보다 늦게 서버에 닿을 때(M1) — 짧은 횟수만 /status를
  /// 다시 물어, 같은 job의 단계가 오면 결과 문장만 고친다. 다른 단말이 멈춘 실행도 이 경로로 보인다.
  /// 옛 RPi4(보고 없음)·로컬 모의는 몇 번 뒤 그만두고 종전 문장을 둔다. 새 실행이 시작되면 그만둔다.
  void _followStopReport(RpiApiService api, String jobId) {
    _stopFollowTimer?.cancel();
    var tries = 0;
    var inFlight = false;
    _stopFollowTimer = Timer.periodic(_stopFollowInterval, (timer) async {
      if (inFlight) return;
      if (!mounted || state.sequenceId != jobId || tries >= _stopFollowTries) {
        timer.cancel();
        return;
      }
      tries++;
      inFlight = true;
      try {
        final status = await api.jobStatus(jobId);
        if (!mounted || !timer.isActive || state.sequenceId != jobId) return;
        if (status.lastJobId != jobId) {
          timer.cancel(); // 그사이 다른 실행이 끝났다
          return;
        }
        final level = status.stopLevelOf(jobId);
        if (level != null) {
          timer.cancel();
          _applyLateStopLevel(level, status.stopAckMsOf(jobId));
        }
      } catch (_) {
        // 통신 실패 — 남은 횟수 안에서 다시 묻는다.
      } finally {
        inFlight = false;
      }
    });
  }

  /// 이미 끝난(정지로 멈춘) 실행의 결과 문장에 늦게 온 정지 단계를 싣는다. 음성은 다시 말하지 않는다.
  void _applyLateStopLevel(String? level, int? ackMs) {
    if (state.outcome != 'stopped') return;
    if (stopLevelSentence(level, ackMs: ackMs) == null) return;
    _stopFollowTimer?.cancel();
    state = state.copyWith(
      message: finishedMessage(
        kind: ResultKind.stopped,
        executionMode: state.executionMode,
        route: state.route,
        receipt: state.receipt,
        stopLevel: level,
        stopAckMs: ackMs,
      ),
    );
  }

  bool get _finished =>
      state.phase == ExecutionPhase.completed ||
      state.phase == ExecutionPhase.failed ||
      state.phase == ExecutionPhase.unconfirmed;

  /// 폴링을 멈춘다.
  ///
  /// [keepTarget]이면 대상(api·job_id)은 남긴다 -- '확인 불가' 상태에서
  /// 정지 요청과 재확인이 계속 가능해야 하기 때문. 여기서 대상을 지우면
  /// emergencyStop이 HTTP 경로를 잃고 BLE로 빠져 실제로 멈추지 못한다.
  /// [keepPending]이면 대상은 지우되 기기에 남긴 job은 둔다 — 보내는 중([beginSubmitting])이 거절로 끝나면 전 실행으로 돌아간다.
  void _stopHttpTracking({bool keepTarget = false, bool keepPending = false}) {
    _pollTimer?.cancel();
    _pollTimer = null;
    _recoverTimer?.cancel();
    _recoverTimer = null;
    if (keepTarget) return;
    _httpApi = null;
    _httpJobId = null;
    _routineRunId = null;
    _routineSegmentJobId = null;
    if (keepPending) return;
    // 결말이 난 job은 더 이상 이어붙일 것이 없다. '확인 불가'(keepTarget)는
    // 아직 결말이 아니므로 남겨둔다 -- 앱을 다시 열면 또 확인해야 한다.
    _forgetPendingJob();
  }

  /// '확인 불가'에서 사용자가 직접 다시 확인한다.
  void recheck() {
    final api = _httpApi;
    final key = state.sequenceId;
    if (api != null && _httpJobId == null && key != null && key.startsWith('unsent-')) {
      // 접수 답을 못 받은 실행 — 처음과 같은 방식(요청 번호 조회, 옛 본체만 상태)으로 다시 찾는다(다시 보내지는 않는다).
      state = state.copyWith(message: '새로 보는 중이에요…');
      _recoverSubmission(api, key, state.label ?? '', state.steps, null);
      return;
    }
    if (_httpApi == null || _httpJobId == null) return;
    _missingPolls = 0;
    _lastPollSuccess = DateTime.now();
    state = state.copyWith(message: '새로 보는 중이에요…');
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
    if (!_bleTracking) return;
    switch (message['type']) {
      case 'sensor':
        // 이미 끝난(또는 확인 불가로 넘어간) 실행을 늦게 도착한 센서
        // 메시지가 '실행 중'으로 되살리면 안 된다 -- 정지 직후 다른
        // 작업의 메시지가 섞이는 경우가 실제로 있다.
        if (state.phase == ExecutionPhase.completed ||
            state.phase == ExecutionPhase.failed ||
            state.phase == ExecutionPhase.unknown ||
            state.phase == ExecutionPhase.unconfirmed) {
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
          message: rawStatus == 'retrying' ? '답이 없어 다시 해 보는 중이에요.' : '하는 중이에요',
        );
        return;
      case 'result':
        // 내가 시작한 그 실행의 결과만 — 번호가 없거나 다른 결과는 받지 않는다.
        if (state.sequenceId != null &&
            message['sequence_id'] == state.sequenceId) {
          final success = message['success'] == true;
          // BLE 프레임은 success 하나뿐이다 -- 경로·확인 근거·실행 환경을
          // 말해주지 않는다. 그런데도 "버튼 조작을 마쳤어요"라고 하면,
          // 아무것도 확인하지 않은 실행을 확인했다고 말하게 된다.
          // HTTP 경로와 같은 규칙(finishedMessage)으로 출처까지 말한다.
          final resultMessage = finishedMessage(
            kind: success ? ResultKind.success : ResultKind.failed,
            // 모의 실행은 시작할 때 이 job에 새겨졌다(전역 토글이 아니다).
            executionMode: state.isDemo ? 'mock' : state.executionMode,
          );
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

  /// 정지 요청. 화면 정지 버튼은 결과를 보지 않고(문구로 알린다), 음성 '멈춰'는
  /// 반환값으로 보냈는지 안다 — **false면 보냈다고 확인하지 못했다**(HTTP 실패, 응답 시간 초과면 전달 여부 모름 —
  /// 다시 보내도 안전하다). 같은 실행의 결과가 이미 왔으면 늦은 실패가 그 문장을 덮지 않고 true(4차 평가 M-N3). 예외로
  /// 바꾸지 않은 것은 화면 버튼의 동작·문구를 그대로 두기 위해서다(10/8 인계 5차 §1).
  Future<bool> emergencyStop() async {
    final api = _httpApi;
    if (api == null && _foreignHub != null) {
      // 다른 본체의 job — 지금 본체(블루투스가 넘겨줄 곳 포함)에 전체 정지를 보내면 상관없는 실행을 멈춘다.
      state = state.copyWith(message: foreignHubStopNotice);
      return false;
    }
    if (api != null) {
      // HTTP 추적 중 — 서버에 정지를 요청하고, 종료 판정은 폴링이
      // safety_stopped 결과를 받아서 처리한다(성급한 '정지됨' 표시 방지).
      // 요청 때의 실행을 기억한다 — 응답을 기다리는 사이 새 실행이 시작되면 그 화면을 덮지 않는다(평가 H1).
      final jobId = _httpJobId;
      final sequenceId = state.sequenceId;
      // 접수 답(job_id)을 아직 모른다(보내는 중·답 없음) — 이 정지가 접수보다 먼저 닿았을 수 있어, 실행을 찾으면 다시 보낸다.
      final submitting = jobId == null && _submitRequestId != null;
      if (submitting) _stopWhileSubmitting = true;
      final routineRunId = jobId == null ? null : _routineRunId;
      if (routineRunId != null) {
        // 루틴이면 그 루틴만 멈춘다(남은 구간을 보내지 않고, 누르는 중이면 본체가 긴급 정지도 보낸다). 본체가 받지 않으면
        // (진행 중인 루틴이 아님·옛 본체) 아래 본체 전체 정지로 갈음한다 — 멈추라는 뜻은 그대로 전한다.
        try {
          await api.stopRoutineRun(routineRunId);
          if (!mounted || state.sequenceId != sequenceId) return true;
          if (!_finished) state = state.copyWith(message: routineStopSentNotice);
          return true;
        } on RpiApiException {
          if (!mounted || state.sequenceId != sequenceId) return false;
        } catch (error) {
          if (!mounted || state.sequenceId != sequenceId) return false;
          if (_finished) return true;
          state = state.copyWith(
              message: error is TimeoutException
                  ? '멈추라고 보냈는데 답이 없어요. 멈추지 않으면 정지를 다시 눌러 주세요.'
                  : '멈추라고 보내지 못했어요. 정지를 다시 눌러 주세요.');
          return false;
        }
      }
      try {
        final outcome = await api.stop();
        if (!mounted || state.sequenceId != sequenceId) return true;
        if (submitting && state.phase == ExecutionPhase.waiting) {
          state = state.copyWith(message: stopWhileSubmittingNotice);
          return true;
        }
        // 서버가 다른 실행을 멈췄다고 하거나(다른 job) 실행 중이 아니었다고 하면(명시적 null) 그 단계는
        // 이 화면의 것이 아니다. 필드가 없는 옛 서버만 종전처럼 싣는다(2차 평가 M-N1). 루틴이면 지금 구간을 멈춘 것도 이 화면의 것.
        final segmentJobId = _routineSegmentJobId;
        final mine = outcome.belongsTo(jobId) ||
            (segmentJobId != null && outcome.reportsJobId && outcome.belongsTo(segmentJobId));
        if (_finished) {
          // 결과가 먼저 왔다(M1) — 결과 문장을 덮지 않고, 같은 job의 정지 결과면 단계만 싣는다.
          if (mine) _applyLateStopLevel(outcome.stopLevel, outcome.ackMs);
          return true;
        }
        // 서버가 알린 정지 확인 단계까지만 말한다(2026-10-13). 없으면 종전 문장.
        state = state.copyWith(
            message: (mine
                    ? stopLevelSentence(outcome.stopLevel, ackMs: outcome.ackMs)
                    : null) ??
                '멈추라고 보냈어요.');
        return true;
      } catch (error) {
        if (!mounted || state.sequenceId != sequenceId) return false;
        // 4차 평가 M-N3: 같은 job의 결과(정지 완료 등)를 이미 받았으면 그 문장을 덮지 않는다 — 늦게 실패한 것은
        // /stop의 HTTP 응답이지, 이미 확인한 정지가 아니다. 끝난 실행에는 더 멈출 것이 없다.
        if (_finished) return true;
        // 응답 시간 초과는 '보내지 못함'이 아니라 '전달 여부 모름'이다(서버가 받았을 수 있다). 상태 조회가 계속 확인한다.
        state = state.copyWith(
            message: error is TimeoutException
                ? '멈추라고 보냈는데 답이 없어요. 멈추지 않으면 정지를 다시 눌러 주세요.'
                : '멈추라고 보내지 못했어요. 정지를 다시 눌러 주세요.');
        return false;
      }
    }
    // 모의 BLE는 아무것도 보내지 않는다 — 실행 화면은 끝내되 보낸 것으로 치지 않고(음성 '멈춰'가 다시 들을 수 있게,
    // 10/8 리뷰) 보냈다고 말하지도 않는다(검토 10/19).
    final sequenceId = state.sequenceId;
    final bool sent;
    try {
      sent = await ref.read(bleServiceProvider).emergencyStop();
    } catch (_) {
      // 블루투스가 끊겨 못 보냈다(검토 10/19 — 예외가 새어 나가 아무 문구 없이 실행이 계속됐다).
      return _stopViaHub(sequenceId);
    }
    if (!mounted || state.sequenceId != sequenceId) return sent;
    // 블루투스로 보낸 것은 정지 프레임이 건너갔다는 뜻일 뿐, 실행이 멈췄다는 확인이 아니다(검토 10/19). 끝난 단계로 바꾸면
    // 정지 띠·음성 정지가 사라져 다시 멈출 길이 없었다. 같은 실행의 결과 프레임이 올 때까지 '모름'으로 두고 정지를 남긴다.
    state = state.copyWith(
      phase: sent ? ExecutionPhase.unknown : ExecutionPhase.failed,
      message: sent ? bleStopSentNotice : '연습 연결이라 실제로는 정지를 보내지 않았어요.',
    );
    return sent;
  }

  /// BLE 정지를 못 보냈을 때 — 설정된 본체가 있으면 본체에 정지를 보낸다. 보낸 것을 확인했을 때만 보냈다고 하고,
  /// 못 보냈으면 실행 화면(정지 버튼)을 그대로 두고 못 보냈다고 말한다.
  Future<bool> _stopViaHub(String? sequenceId) async {
    RpiApiService? api;
    try {
      api = ref.read(rpiApiServiceProvider);
    } catch (_) {}
    if (api != null) {
      try {
        await api.stop();
        if (!mounted || state.sequenceId != sequenceId) return true;
        state = state.copyWith(
          phase: ExecutionPhase.unknown,
          message: '블루투스가 끊겨 본체에 멈추라고 보냈어요. 멈췄는지는 가전 앞에서 확인해 주세요.',
        );
        return true;
      } catch (error) {
        if (!mounted || state.sequenceId != sequenceId) return false;
        state = state.copyWith(
            message: error is TimeoutException
                ? '블루투스가 끊겨 본체에 멈추라고 보냈는데 답이 없어요. 멈추지 않으면 정지를 다시 눌러 주세요.'
                : '멈추라고 보내지 못했어요. 블루투스와 본체 연결을 보고 정지를 다시 눌러 주세요.');
        return false;
      }
    }
    if (!mounted || state.sequenceId != sequenceId) return false;
    state = state.copyWith(message: '멈추라고 보내지 못했어요. 블루투스 연결을 보고 정지를 다시 눌러 주세요.');
    return false;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _pollTimer?.cancel();
    _stopFollowTimer?.cancel();
    _recoverTimer?.cancel();
    _apiWait?.close();
    super.dispose();
  }
}

/// 칸 [index]에 본 버튼 이름을 적은 새 목록. 이름이 없으면 null(그대로 둔다). 사이 칸은 null로 채운다.
List<String?>? _withStepName(List<String?> names, int index, String? button) {
  if (button == null || index < 0 || index > 63) return null;
  if (index < names.length && names[index] == button) return null;
  final next = [...names];
  while (next.length <= index) {
    next.add(null);
  }
  next[index] = button;
  return next;
}

final executionStatusProvider =
    StateNotifierProvider<ExecutionStatusNotifier, ExecutionStatus>(
  ExecutionStatusNotifier.new,
);

/// 보내기 전에 따라가던 것 — 보내는 중이 거절로 끝나면 그대로 되돌린다([ExecutionStatusNotifier.abandonSubmission]).
class _Tracking {
  const _Tracking(this.state, this.api, this.jobId, this.foreignHub, this.routineRunId, this.routineSegmentJobId);
  final ExecutionStatus state;
  final RpiApiService? api;
  final String? jobId;
  final String? foreignHub;
  final String? routineRunId;
  final String? routineSegmentJobId;
}
