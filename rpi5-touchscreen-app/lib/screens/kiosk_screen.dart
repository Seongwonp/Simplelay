import 'dart:async';

import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../services/kiosk_api_service.dart';
import '../theme/kiosk_colors.dart';
import '../widgets/kiosk/done_view.dart';
import '../widgets/kiosk/executing_view.dart';
import '../widgets/kiosk/idle_view.dart';
import '../widgets/kiosk/suggestion_view.dart';

enum _Phase { idle, suggestion, executing, done }

const _pollInterval = Duration(milliseconds: 2000);
const _healthInterval = Duration(seconds: 10);
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
  bool _connected = false;
  DateTime _now = DateTime.now();

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

  @override
  void initState() {
    super.initState();
    _checkHealth();
    _poll();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
    _healthTimer = Timer.periodic(_healthInterval, (_) => _checkHealth());
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
    _api.dispose();
    super.dispose();
  }

  Future<void> _checkHealth() async {
    final ok = await _api.checkHealth();
    if (mounted) setState(() => _connected = ok);
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
    });
    _checkHealth();
  }

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

  Future<void> _onStop() async {
    try {
      await _api.stop();
    } catch (_) {}
    _toDone(false, _execTitle.isEmpty ? '실행' : _execTitle);
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
        ],
      ),
    );
  }

  Widget _buildScreen() {
    switch (_phase) {
      case _Phase.idle:
        return KioskIdleView(
          key: const ValueKey('idle'),
          appliance: widget.appliance,
          connected: _connected,
          now: _now,
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
