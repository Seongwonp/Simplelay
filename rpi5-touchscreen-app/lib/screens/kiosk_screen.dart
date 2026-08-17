import 'dart:async';

import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../services/kiosk_api_service.dart';
import '../theme/kiosk_colors.dart';
import '../widgets/kiosk/done_view.dart';
import '../widgets/kiosk/executing_view.dart';
import '../widgets/kiosk/idle_view.dart';
import '../widgets/kiosk/manual_view.dart';
import '../widgets/kiosk/suggestion_view.dart';

enum _Phase { idle, suggestion, executing, done, manual }

const _pollInterval = Duration(milliseconds: 2000);
const _healthInterval = Duration(seconds: 10);
const _sensorInterval = Duration(seconds: 60);
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

  _Phase _phase = _Phase.idle;
  HealthStatus _health = HealthStatus.disconnected;
  SensorData? _sensorData;
  DateTime _now = DateTime.now();
  bool _showDnd = false;

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

  @override
  void initState() {
    super.initState();
    _checkHealth();
    _fetchSensors();
    _poll();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    _healthTimer = Timer.periodic(_healthInterval, (_) => _checkHealth());
    _sensorTimer = Timer.periodic(_sensorInterval, (_) => _fetchSensors());
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

  Future<void> _poll() async {
    if (_phase == _Phase.idle) {
      try {
        final list = await _api.suggestions();
        if (list.isNotEmpty) _toSuggestion(list.first);
      } catch (_) {}
    } else if (_phase == _Phase.executing) {
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
      _phase = _Phase.idle;
      _currentSuggestion = null;
      _showDnd = false;
    });
    _checkHealth();
  }

  void _toManual() {
    if (_phase != _Phase.idle) return;
    setState(() => _phase = _Phase.manual);
  }

  void _fromManual() => setState(() => _phase = _Phase.idle);

  void _toSuggestion(KioskSuggestion suggestion) {
    setState(() {
      _phase = _Phase.suggestion;
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
      _phase = _Phase.executing;
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
      _phase = _Phase.done;
      _doneSuccess = success;
      _doneLabel = label;
    });
    Future.delayed(_doneReturnDuration, () {
      if (mounted && _phase == _Phase.done) _toIdle();
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
      final result = await _api.executeButtons([button.label]);
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
            child: _TopProgressBar(phase: _phase, execBarValue: _execBarValue),
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
              child: _DndOverlay(
                dndUntil: _health.dndUntil,
                onSet: _onSetDnd,
                onClear: _onClearDnd,
                onDismiss: () => setState(() => _showDnd = false),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildScreen() {
    switch (_phase) {
      case _Phase.idle:
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
        );
      case _Phase.manual:
        return KioskManualView(
          key: const ValueKey('manual'),
          appliance: widget.appliance,
          onExecute: _onManualExecute,
          onCancel: _fromManual,
        );
      case _Phase.suggestion:
        final suggestion = _currentSuggestion!;
        return KioskSuggestionView(
          key: const ValueKey('suggestion'),
          appliance: widget.appliance,
          suggestion: suggestion,
          cdRemaining: _cdRemaining,
          onApprove: _onApprove,
          onReject: _onReject,
        );
      case _Phase.executing:
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
      case _Phase.done:
        return KioskDoneView(
          key: const ValueKey('done'),
          success: _doneSuccess,
          label: _doneLabel,
        );
    }
  }
}

// ── DND 오버레이 ────────────────────────────────────────────────────────────

class _DndOverlay extends StatelessWidget {
  const _DndOverlay({
    required this.dndUntil,
    required this.onSet,
    required this.onClear,
    required this.onDismiss,
  });

  final DateTime? dndUntil;
  final void Function(int minutes) onSet;
  final VoidCallback onClear;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: ColoredBox(
        color: const Color(0xCC0C0E12),
        child: Center(
          child: GestureDetector(
            onTap: () {}, // 카드 탭이 배경으로 전파되지 않게 흡수
            child: Container(
              width: 300,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
              decoration: BoxDecoration(
                color: KioskColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: KioskColors.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '방해 금지',
                    style: TextStyle(
                      fontSize: 17,
                      color: Color(0xFFFAF7F2),
                      fontWeight: FontWeight.w300,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    dndUntil != null
                        ? 'AI 제안이 일시 중단됨'
                        : 'AI 제안을 잠시 멈춥니다',
                    style: const TextStyle(
                      fontSize: 12,
                      color: KioskColors.muted,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (dndUntil == null) ...[
                    _DndOption(label: '30분', onTap: () => onSet(30)),
                    const SizedBox(height: 8),
                    _DndOption(label: '1시간', onTap: () => onSet(60)),
                    const SizedBox(height: 8),
                    _DndOption(label: '2시간', onTap: () => onSet(120)),
                  ] else ...[
                    _DndOption(
                      label: '방해 금지 해제',
                      accent: true,
                      onTap: onClear,
                    ),
                  ],
                  const SizedBox(height: 18),
                  GestureDetector(
                    onTap: onDismiss,
                    child: const Text(
                      '취소',
                      style: TextStyle(fontSize: 13, color: KioskColors.muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DndOption extends StatelessWidget {
  const _DndOption({
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 46,
        decoration: BoxDecoration(
          color: accent
              ? KioskColors.warning.withValues(alpha: 0.12)
              : KioskColors.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: accent
                ? KioskColors.warning.withValues(alpha: 0.35)
                : KioskColors.border,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: accent ? KioskColors.warning : const Color(0xFFFAF7F2),
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

// ── 상단 프로그레스 바 ─────────────────────────────────────────────────────

class _TopProgressBar extends StatelessWidget {
  const _TopProgressBar({required this.phase, required this.execBarValue});

  final _Phase phase;
  final double execBarValue;

  @override
  Widget build(BuildContext context) {
    final value = switch (phase) {
      _Phase.executing => execBarValue * 0.8,
      _Phase.done => 1.0,
      _ => 0.0,
    };
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        children: [
          Container(color: KioskColors.surface),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: constraints.maxWidth * value.clamp(0.0, 1.0),
            decoration: BoxDecoration(
              color: KioskColors.primary,
              boxShadow: [
                BoxShadow(
                  color: KioskColors.primary.withValues(alpha: 0.6),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
