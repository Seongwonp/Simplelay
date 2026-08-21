import 'dart:async';

import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../services/kiosk_api_service.dart';
import '../theme/kiosk_colors.dart';
import '../widgets/kiosk/danger_alert_overlay.dart';
import '../widgets/kiosk/dnd_overlay.dart';
import '../widgets/kiosk/done_view.dart';
import '../widgets/kiosk/executing_view.dart';
import '../widgets/kiosk/idle_view.dart';
import '../widgets/kiosk/kiosk_phase.dart';
import '../widgets/kiosk/kiosk_timings.dart';
import '../widgets/kiosk/manual_view.dart';
import '../widgets/kiosk/suggestion_view.dart';
import '../widgets/kiosk/settings_overlay.dart';
import '../widgets/kiosk/top_progress_bar.dart';

const _pollInterval = Duration(milliseconds: 2000);
const _healthInterval = Duration(seconds: 10);
const _sensorInterval = Duration(seconds: 60);
const _alertInterval = Duration(seconds: 3);
// 타이밍 상수는 KioskTimings(위젯과 공유) 참조 — 여기 별도 정의 금지
const _countdownSeconds = KioskTimings.countdownSeconds;
const _doneReturnDuration = KioskTimings.doneReturn;
const _execBarFillDuration = KioskTimings.execBarFill;
// 실행 중 /status가 이 시간 동안 한 번도 응답하지 않으면 서버 유실로 판정 —
// "실행 중" 화면에 영원히 갇히는 대신 실패 화면으로 탈출한다.
const _statusLostTimeout = Duration(seconds: 30);

class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key, this.appliance = kMicrowaveAppliance, this.api});

  final ApplianceMap appliance;

  /// 테스트에서 fake를 주입하기 위한 지점 — 미지정 시 localhost 기본 서비스.
  final KioskApiService? api;

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  late final KioskApiService _api = widget.api ?? KioskApiService();
  // 주입받은 서비스는 호출자 소유 — 내부 생성분만 dispose한다
  late final bool _ownsApi = widget.api == null;

  late ApplianceMap _currentAppliance;
  bool _showSettings = false;

  KioskPhase _phase = KioskPhase.idle;
  HealthStatus _health = HealthStatus.disconnected;
  SensorData? _sensorData;
  DateTime _now = DateTime.now();
  bool _showDnd = false;
  AlertState _alert = AlertState.inactive;
  bool _alertAcknowledged = false;

  KioskSuggestion? _currentSuggestion;
  int _cdRemaining = _countdownSeconds;
  Timer? _countdownTimer;

  String _execTitle = '';
  double _execBarValue = 0;
  Timer? _execFillTimer;
  List<KioskButtonResult>? _lastButtons;

  // job 모델: 이 화면이 따라가는 실행의 job_id. 내가 시작한 실행은 접수 응답에서,
  // 폰 앱이 시작한 실행은 idle 폴링의 /status.job_id에서 얻는다. 완료 판정은
  // last_job_id 대조 — 이전 실행 결과를 내 것으로 오인하는 레이스가 없다.
  String? _activeJobId;
  DateTime? _lastStatusOk;
  bool _pollInFlight = false;

  String? _currentButton;
  int? _currentAttempt;
  int? _completedSteps;
  double? _verificationConfidence;
  String? _verificationDetail;

  bool _doneSuccess = true;
  String _doneLabel = '';

  Timer? _pollTimer;
  Timer? _healthTimer;
  Timer? _clockTimer;
  Timer? _sensorTimer;
  Timer? _alertTimer;

  @override
  void initState() {
    super.initState();
    _currentAppliance = widget.appliance;
    _checkHealth();
    _fetchSensors();
    _fetchAlert();
    _poll();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    _healthTimer = Timer.periodic(_healthInterval, (_) => _checkHealth());
    _sensorTimer = Timer.periodic(_sensorInterval, (_) => _fetchSensors());
    _alertTimer = Timer.periodic(_alertInterval, (_) => _fetchAlert());
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _now = DateTime.now()),
    );
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _execFillTimer?.cancel();
    _pollTimer?.cancel();
    _healthTimer?.cancel();
    _clockTimer?.cancel();
    _sensorTimer?.cancel();
    _alertTimer?.cancel();
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  Future<void> _checkHealth() async {
    final health = await _api.checkHealth();
    if (mounted) setState(() => _health = health);
  }

  Future<void> _fetchSensors() async {
    final data = await _api.sensors();
    if (mounted) setState(() => _sensorData = data);
  }

  Future<void> _fetchAlert() async {
    final alert = await _api.alerts();
    if (!mounted) return;
    setState(() {
      // 새로 켜지는 순간(엣지)엔 "확인" 눌렀던 기록을 리셋 — 계속 같은
      // 경보가 이어지는 중엔 확인 상태 유지, 한 번 꺼졌다 다시 울리면 재알림.
      if (alert.active && !_alert.active) _alertAcknowledged = false;
      _alert = alert;
    });
  }

  Future<void> _poll() async {
    if (_pollInFlight) return; // 폴링 오버랩 가드 (2초 주기 vs 4초 타임아웃)
    _pollInFlight = true;
    try {
      if (_phase == KioskPhase.idle) {
        await _pollIdle();
      } else if (_phase == KioskPhase.executing) {
        await _pollExecuting();
      }
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _pollIdle() async {
    // 폰 앱이 시작한 실행도 키오스크가 같이 보여준다 — /status에서 진행 중인
    // job을 발견하면 그 job_id를 이어받아 실행 화면으로 전환.
    try {
      final st = await _api.status();
      if (st.running && st.jobId != null) {
        _activeJobId = st.jobId;
        _toExecuting(st.currentButton ?? '실행');
        return;
      }
    } catch (_) {}
    try {
      final list = await _api.suggestions();
      if (list.isNotEmpty && _phase == KioskPhase.idle) {
        _toSuggestion(list.first);
      }
    } catch (_) {}
  }

  Future<void> _pollExecuting() async {
    try {
      final st = await _api.status();
      _lastStatusOk = DateTime.now();
      if (mounted && st.running) {
        setState(() {
          _currentButton = st.currentButton ?? _currentButton;
          _currentAttempt = st.currentAttempt ?? _currentAttempt;
          _completedSteps = st.completedSteps ?? _completedSteps;
          _verificationConfidence =
              st.verificationConfidence ?? _verificationConfidence;
          _verificationDetail = st.verificationDetail ?? _verificationDetail;
          // 실제 진행 데이터가 있으면 9초짜리 가짜 채움 대신 진짜 진행률로
          final total = st.totalSteps;
          if (total != null && total > 0) {
            _execFillTimer?.cancel();
            _execBarValue =
                ((st.completedSteps ?? 0) / total).clamp(0.0, 0.95);
          }
        });
      }
      if (!st.running && st.lastJobId != null && st.lastJobId == _activeJobId) {
        _finishExecuting(
          success: st.lastStatus == 'succeeded',
          buttons: st.lastButtons ?? const [],
        );
      }
    } catch (_) {
      // 연속 실패가 길어지면 서버 유실로 판정하고 실행 화면에서 탈출
      final since = _lastStatusOk;
      if (since != null &&
          DateTime.now().difference(since) > _statusLostTimeout) {
        _execFillTimer?.cancel();
        _toDone(false, '서버 응답 없음');
      }
    }
  }

  void _toIdle() {
    _countdownTimer?.cancel();
    _execFillTimer?.cancel();
    setState(() {
      _phase = KioskPhase.idle;
      _currentSuggestion = null;
      _showDnd = false;
    });
    _checkHealth();
  }

  void _toManual() {
    if (_phase != KioskPhase.idle) return;
    setState(() => _phase = KioskPhase.manual);
  }

  void _fromManual() => setState(() => _phase = KioskPhase.idle);

  void _toSuggestion(KioskSuggestion suggestion) {
    setState(() {
      _phase = KioskPhase.suggestion;
      _currentSuggestion = suggestion;
      _cdRemaining = _countdownSeconds;
    });
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _cdRemaining--);
      if (_cdRemaining <= 0) {
        timer.cancel();
        _toIdle();
      }
    });
  }

  void _toExecuting(String title) {
    _lastStatusOk = DateTime.now();
    setState(() {
      _phase = KioskPhase.executing;
      _execTitle = title;
      _lastButtons = null;
      _execBarValue = 0;
      _currentButton = null;
      _currentAttempt = null;
      _completedSteps = null;
      _verificationConfidence = null;
      _verificationDetail = null;
    });
    _startExecFakeFill();
  }

  void _startExecFakeFill() {
    const stepMs = 150;
    var elapsedMs = 0;
    _execFillTimer?.cancel();
    _execFillTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      elapsedMs += stepMs;
      final frac =
          (elapsedMs / _execBarFillDuration.inMilliseconds).clamp(0.0, 1.0) *
          0.85;
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _execBarValue = frac);
      if (elapsedMs >= _execBarFillDuration.inMilliseconds) timer.cancel();
    });
  }

  void _finishExecuting({
    required bool success,
    required List<KioskButtonResult> buttons,
  }) {
    // 지연 도착한 approve/execute 응답이 이미 끝난(정지·완료된) 실행을
    // 되살려 idle 화면을 완료 화면으로 점프시키는 것을 막는다 —
    // _toDone과 동일한 phase 가드.
    if (_phase != KioskPhase.executing) return;
    _execFillTimer?.cancel();
    setState(() {
      _lastButtons = buttons;
      _execBarValue = 1.0;
    });
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) _toDone(success, _execTitle);
    });
  }

  void _toDone(bool success, String label) {
    setState(() {
      _phase = KioskPhase.done;
      _doneSuccess = success;
      _doneLabel = label;
    });
    Future.delayed(_doneReturnDuration, () {
      if (mounted && _phase == KioskPhase.done) _toIdle();
    });
  }

  Future<void> _onApprove() async {
    final suggestion = _currentSuggestion;
    if (suggestion == null) return;
    _countdownTimer?.cancel();
    setState(() => _currentSuggestion = null);
    _toExecuting(suggestion.purpose);

    try {
      // job 모델: 즉시 접수 — 진행·완료는 _pollExecuting이 job_id 대조로 따라간다
      final accepted = await _api.approveSuggestion(suggestion.id);
      _activeJobId = accepted.jobId;
    } catch (_) {
      // 접수 자체가 실패(서버 다운·409 등) — 올 수 없는 완료를 기다리는 대신
      // 즉시 실패 화면으로 탈출한다.
      _execFillTimer?.cancel();
      if (mounted && _phase == KioskPhase.executing) {
        _toDone(false, suggestion.purpose);
      }
    }
  }

  Future<void> _onReject() async {
    final suggestion = _currentSuggestion;
    _countdownTimer?.cancel();
    _toIdle();
    if (suggestion != null) {
      try {
        await _api.rejectSuggestion(suggestion.id);
      } catch (_) {}
    }
  }

  Future<void> _onManualExecute(ApplianceButton button) async {
    _toExecuting(button.label);
    try {
      final accepted = await _api.executeButtons(
        [button.label],
        applianceId: _currentAppliance.id,
      );
      _activeJobId = accepted.jobId;
    } catch (_) {
      // 접수 실패 — 즉시 실패 화면으로 탈출 (고착 방지)
      _execFillTimer?.cancel();
      if (mounted && _phase == KioskPhase.executing) {
        _toDone(false, button.label);
      }
    }
  }

  Future<void> _onStop() async {
    // 정지 "요청"만 보낸다 — 화면 전환은 폴링이 safety_stopped 완료를 받은 뒤.
    // 하드웨어가 멈추기 전에 '정지됨' 화면부터 띄우면 실제 상태와 어긋난다.
    try {
      await _api.stop();
    } catch (_) {
      // 정지 요청조차 실패 = 통신 문제 — 실행 화면 유지, 30초 탈출 타이머가
      // (_pollExecuting의 _statusLostTimeout) 결국 실패 화면으로 빼낸다.
    }
  }

  Future<void> _onSetDnd(int minutes) async {
    try {
      await _api.setDnd(minutes);
    } catch (_) {}
    await _checkHealth();
    if (mounted) setState(() => _showDnd = false);
  }

  Future<void> _onClearDnd() async {
    try {
      await _api.clearDnd();
    } catch (_) {}
    await _checkHealth();
    if (mounted) setState(() => _showDnd = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KioskColors.bg,
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 4,
            child: TopProgressBar(phase: _phase, execBarValue: _execBarValue),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _buildScreen(),
              ),
            ),
          ),
          if (_showDnd)
            Positioned.fill(
              child: DndOverlay(
                dndUntil: _health.dndUntil,
                onSet: _onSetDnd,
                onClear: _onClearDnd,
                onDismiss: () => setState(() => _showDnd = false),
              ),
            ),
          if (_alert.active && !_alertAcknowledged)
            Positioned.fill(
              child: DangerAlertOverlay(
                onAcknowledge: () => setState(() => _alertAcknowledged = true),
              ),
            ),
          if (_showSettings)
            Positioned.fill(
              child: KioskSettingsOverlay(
                currentAppliance: _currentAppliance,
                api: _api,
                onApplianceChanged: (a) =>
                    setState(() => _currentAppliance = a),
                onDismiss: () => setState(() => _showSettings = false),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScreen() {
    switch (_phase) {
      case KioskPhase.idle:
        return KioskIdleView(
          key: const ValueKey('idle'),
          now: _now,
          connected: _health.ok,
          actuatorReady: _health.actuatorReady,
          dndUntil: _health.dndUntil,
          temperature: _sensorData?.temperature,
          humidity: _sensorData?.humidity,
          onTap: _toManual,
          onLongPress: () => setState(() => _showDnd = true),
          onSettingsGesture: () => setState(() => _showSettings = true),
        );
      case KioskPhase.manual:
        return KioskManualView(
          key: const ValueKey('manual'),
          appliance: _currentAppliance,
          onExecute: _onManualExecute,
          onCancel: _fromManual,
        );
      case KioskPhase.suggestion:
        final suggestion = _currentSuggestion!;
        return KioskSuggestionView(
          key: const ValueKey('suggestion'),
          suggestion: suggestion,
          cdRemaining: _cdRemaining,
          onApprove: _onApprove,
          onReject: _onReject,
        );
      case KioskPhase.executing:
        return KioskExecutingView(
          key: const ValueKey('executing'),
          title: _execTitle,
          lastButtons: _lastButtons,
          currentButton: _currentButton,
          currentAttempt: _currentAttempt,
          completedSteps: _completedSteps,
          verificationConfidence: _verificationConfidence,
          verificationDetail: _verificationDetail,
          onStop: _onStop,
        );
      case KioskPhase.done:
        return KioskDoneView(
          key: const ValueKey('done'),
          success: _doneSuccess,
          label: _doneLabel,
        );
    }
  }
}
