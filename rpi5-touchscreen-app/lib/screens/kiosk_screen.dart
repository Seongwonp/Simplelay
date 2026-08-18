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
import '../widgets/kiosk/manual_view.dart';
import '../widgets/kiosk/suggestion_view.dart';
import '../widgets/kiosk/settings_overlay.dart';
import '../widgets/kiosk/top_progress_bar.dart';

const _pollInterval = Duration(milliseconds: 2000);
const _healthInterval = Duration(seconds: 10);
const _sensorInterval = Duration(seconds: 60);
const _alertInterval = Duration(seconds: 3);
const _countdownSeconds = 10;
const _doneReturnDuration = Duration(seconds: 3);
const _execBarFillDuration = Duration(seconds: 9);

class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key, this.appliance = kMicrowaveAppliance});

  final ApplianceMap appliance;

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  final _api = KioskApiService();

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
    _api.dispose();
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
    if (_phase == KioskPhase.idle) {
      try {
        final list = await _api.suggestions();
        if (list.isNotEmpty) _toSuggestion(list.first);
      } catch (_) {}
    } else if (_phase == KioskPhase.executing) {
      try {
        final st = await _api.status();
        if (mounted) {
          setState(() {
            _currentButton = st.currentButton ?? _currentButton;
            _currentAttempt = st.currentAttempt ?? _currentAttempt;
            _completedSteps = st.completedSteps ?? _completedSteps;
            _verificationConfidence =
                st.verificationConfidence ?? _verificationConfidence;
            _verificationDetail = st.verificationDetail ?? _verificationDetail;
          });
        }
        if (!st.running && st.lastButtons != null) {
          _finishExecuting(
            success: st.lastStatus == 'succeeded',
            buttons: st.lastButtons!,
          );
        }
      } catch (_) {}
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
      final result = await _api.approveSuggestion(suggestion.id);
      _finishExecuting(
        success: result.status == 'succeeded',
        buttons: result.buttons,
      );
    } catch (_) {
      // 폴링이 완료를 감지할 때까지 실행 화면을 유지한다.
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
      final result = await _api.executeButtons(
        [button.label],
        applianceId: _currentAppliance.id,
      );
      _finishExecuting(
        success: result.status == 'succeeded',
        buttons: result.buttons,
      );
    } catch (_) {
      // 폴링이 완료를 감지할 때까지 실행 화면을 유지한다.
    }
  }

  Future<void> _onStop() async {
    try {
      await _api.stop();
    } catch (_) {}
    _toDone(false, _execTitle.isEmpty ? '실행' : _execTitle);
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
