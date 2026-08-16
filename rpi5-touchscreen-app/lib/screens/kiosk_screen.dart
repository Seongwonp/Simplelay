import 'dart:async';

import 'package:flutter/material.dart';

import '../models/appliance.dart';
import '../services/kiosk_api_service.dart';
import '../theme/kiosk_colors.dart';

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

  // ── 헬스체크 ──────────────────────────────────────────────────────────
  Future<void> _checkHealth() async {
    final ok = await _api.checkHealth();
    if (mounted) setState(() => _connected = ok);
  }

  // ── 폴링 ──────────────────────────────────────────────────────────────
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

  // ── 화면 전환 ─────────────────────────────────────────────────────────
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
    _execFillTimer = Timer.periodic(const Duration(milliseconds: stepMs), (
      timer,
    ) {
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

  // ── 버튼 이벤트 ───────────────────────────────────────────────────────
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

  // ── 빌드 ──────────────────────────────────────────────────────────────
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
        return _IdleView(
          key: const ValueKey('idle'),
          appliance: widget.appliance,
          connected: _connected,
          now: _now,
        );
      case _Phase.suggestion:
        final suggestion = _currentSuggestion!;
        return _SuggestionView(
          key: const ValueKey('suggestion'),
          appliance: widget.appliance,
          suggestion: suggestion,
          cdRemaining: _cdRemaining,
          onApprove: _onApprove,
          onReject: _onReject,
        );
      case _Phase.executing:
        return _ExecutingView(
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
        return _DoneView(
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

// ── 1. 대기 화면 ────────────────────────────────────────────────────────

class _IdleView extends StatelessWidget {
  const _IdleView({
    super.key,
    required this.appliance,
    required this.connected,
    required this.now,
  });

  final ApplianceMap appliance;
  final bool connected;
  final DateTime now;

  String get _clock =>
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 0.7,
          colors: [Color(0x16D9A356), KioskColors.bg],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 이중 링 아이콘
            Container(
              width: 136,
              height: 136,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: KioskColors.primary.withValues(alpha: 0.04),
                border: Border.all(
                  color: KioskColors.primary.withValues(alpha: 0.12),
                  width: 1,
                ),
              ),
              child: Center(
                child: Container(
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: KioskColors.primary.withValues(alpha: 0.10),
                    border: Border.all(
                      color: KioskColors.primary.withValues(alpha: 0.30),
                      width: 1.5,
                    ),
                  ),
                  child: Icon(appliance.icon, color: KioskColors.primary, size: 54),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              appliance.name,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'AI가 패턴을 학습하고 자동으로 제안합니다',
              style: TextStyle(fontSize: 14, color: KioskColors.muted),
            ),
            const SizedBox(height: 36),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: KioskColors.surface,
                border: Border.all(color: KioskColors.border),
                borderRadius: BorderRadius.circular(100),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: connected
                          ? KioskColors.success
                          : const Color(0xFF444444),
                      boxShadow: connected
                          ? [
                              BoxShadow(
                                color: KioskColors.success.withValues(alpha: 0.6),
                                blurRadius: 6,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    connected ? 'RPi 연결됨' : '연결 안 됨',
                    style: const TextStyle(fontSize: 13, color: KioskColors.muted),
                  ),
                  const SizedBox(width: 18),
                  Container(width: 1, height: 15, color: KioskColors.border),
                  const SizedBox(width: 18),
                  Text(
                    _clock,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 2. 제안 화면 ────────────────────────────────────────────────────────

class _SuggestionView extends StatelessWidget {
  const _SuggestionView({
    super.key,
    required this.appliance,
    required this.suggestion,
    required this.cdRemaining,
    required this.onApprove,
    required this.onReject,
  });

  final ApplianceMap appliance;
  final KioskSuggestion suggestion;
  final int cdRemaining;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 400,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                  decoration: BoxDecoration(
                    color: KioskColors.primary.withValues(alpha: 0.1),
                    border: Border.all(
                      color: KioskColors.primary.withValues(alpha: 0.28),
                    ),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: const Text(
                    '✦  AI 제안',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.06,
                      color: KioskColors.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  suggestion.purpose,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 14, color: KioskColors.muted),
                    children: [
                      const TextSpan(text: '최근 '),
                      TextSpan(
                        text: '${suggestion.occurrences}',
                        style: const TextStyle(
                          color: KioskColors.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const TextSpan(text: '회 같은 시간대에 반복 감지'),
                    ],
                  ),
                ),
                const Spacer(),
                // 승인 버튼 — glow 효과로 더 눈에 띄게
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: KioskColors.success.withValues(alpha: 0.28),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: SizedBox(
                    width: double.infinity,
                    height: 68,
                    child: ElevatedButton.icon(
                      onPressed: onApprove,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KioskColors.success,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.check, size: 22),
                      label: const Text(
                        '승인하고 실행',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: OutlinedButton(
                    onPressed: onReject,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: KioskColors.muted,
                      side: const BorderSide(color: KioskColors.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('거부'),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      '$cdRemaining초',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: KioskColors.warning,
                      ),
                    ),
                    const Text(
                      ' 후 자동 닫힘',
                      style: TextStyle(fontSize: 13, color: KioskColors.muted),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: cdRemaining / _countdownSeconds,
                          minHeight: 4,
                          backgroundColor: KioskColors.border,
                          valueColor: const AlwaysStoppedAnimation(KioskColors.warning),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 28, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${appliance.name} 버튼 배치',
                  style: const TextStyle(fontSize: 12, color: KioskColors.muted),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: _ButtonGrid(
                    appliance: appliance,
                    highlightLabels: suggestion.steps,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ButtonGrid extends StatelessWidget {
  const _ButtonGrid({required this.appliance, required this.highlightLabels});

  final ApplianceMap appliance;
  final List<String> highlightLabels;

  @override
  Widget build(BuildContext context) {
    final orderMap = <String, int>{};
    for (var i = 0; i < highlightLabels.length; i++) {
      orderMap.putIfAbsent(highlightLabels[i], () => i + 1);
    }

    return Column(
      children: List.generate(appliance.rows, (row) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: row < appliance.rows - 1 ? 7 : 0),
            child: Row(
              children: List.generate(appliance.cols, (col) {
                final btn = appliance.buttonAt(col, row);
                final order = btn != null ? orderMap[btn.label] : null;
                final isHighlighted = order != null;
                return Expanded(
                  child: Padding(
                    padding:
                        EdgeInsets.only(right: col < appliance.cols - 1 ? 7 : 0),
                    child: btn == null
                        ? const SizedBox.shrink()
                        : Container(
                            decoration: BoxDecoration(
                              color: isHighlighted
                                  ? KioskColors.primary.withValues(alpha: 0.14)
                                  : KioskColors.surface,
                              border: Border.all(
                                color: isHighlighted
                                    ? KioskColors.primary
                                    : KioskColors.border,
                                width: isHighlighted ? 1.5 : 1,
                              ),
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Text(
                                  btn.label,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: isHighlighted
                                        ? FontWeight.w700
                                        : FontWeight.normal,
                                    color: isHighlighted
                                        ? KioskColors.primary
                                        : Colors.white.withValues(alpha: 0.45),
                                  ),
                                ),
                                if (isHighlighted)
                                  Positioned(
                                    top: 4,
                                    right: 5,
                                    child: Container(
                                      width: 16,
                                      height: 16,
                                      alignment: Alignment.center,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: KioskColors.primary,
                                      ),
                                      child: Text(
                                        '$order',
                                        style: const TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.black,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                );
              }),
            ),
          ),
        );
      }),
    );
  }
}

// ── 3. 실행 중 화면 ─────────────────────────────────────────────────────

class _ExecutingView extends StatelessWidget {
  const _ExecutingView({
    super.key,
    required this.title,
    required this.lastButtons,
    required this.currentButton,
    required this.currentAttempt,
    required this.completedSteps,
    required this.verificationConfidence,
    required this.verificationDetail,
    required this.onStop,
  });

  final String title;
  final List<KioskButtonResult>? lastButtons;
  final String? currentButton;
  final int? currentAttempt;
  final int? completedSteps;
  final double? verificationConfidence;
  final String? verificationDetail;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final isDone = lastButtons != null;

    return Row(
      children: [
        // ── 왼쪽: 메인 콘텐츠 ──────────────────────────────────────
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 22, 12, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 제목 행 + 단계 배지
                Row(
                  children: [
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: isDone ? KioskColors.success : KioskColors.primary,
                        backgroundColor: isDone
                            ? KioskColors.success.withValues(alpha: 0.18)
                            : KioskColors.primary.withValues(alpha: 0.18),
                        value: isDone ? 1.0 : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    _StepBadge(
                      completedSteps: isDone ? lastButtons!.length : completedSteps,
                      isDone: isDone,
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // 실행 중: 현재 버튼 hero / 완료: 결과 목록
                if (!isDone) ...[
                  _CurrentActionHero(
                    button: currentButton,
                    attempt: currentAttempt,
                  ),
                  const Spacer(),
                ] else
                  Expanded(
                    child: ListView(
                      children: lastButtons!
                          .map(
                            (b) => _StepRow(
                              label: b.button,
                              state:
                                  b.success ? _StepState.done : _StepState.failed,
                            ),
                          )
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // ── 오른쪽: 지표 + 긴급 정지 ─────────────────────────────
        Container(
          width: 220,
          padding: const EdgeInsets.fromLTRB(4, 22, 24, 22),
          child: Column(
            children: [
              _BigConfidenceCard(
                confidence: verificationConfidence,
                detail: verificationDetail,
              ),
              const SizedBox(height: 10),
              _AttemptCard(attempt: currentAttempt),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 72,
                child: ElevatedButton.icon(
                  onPressed: onStop,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KioskColors.danger.withValues(alpha: 0.10),
                    foregroundColor: KioskColors.danger,
                    elevation: 0,
                    side: const BorderSide(color: KioskColors.danger, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.stop_circle_outlined, size: 22),
                  label: const Text(
                    '긴급 정지',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// 단계 완료 배지 — 우상단에 표시
class _StepBadge extends StatelessWidget {
  const _StepBadge({required this.completedSteps, required this.isDone});
  final int? completedSteps;
  final bool isDone;

  @override
  Widget build(BuildContext context) {
    if (completedSteps == null && !isDone) return const SizedBox.shrink();
    final color = isDone ? KioskColors.success : KioskColors.primary;
    final label = isDone
        ? '${completedSteps}단계 완료'
        : '${completedSteps}단계 완료';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.40)),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// 현재 누르고 있는 버튼을 대형 타이포로 표시 — 심사석에서 보이는 핵심 지표
class _CurrentActionHero extends StatelessWidget {
  const _CurrentActionHero({required this.button, required this.attempt});
  final String? button;
  final int? attempt;

  @override
  Widget build(BuildContext context) {
    final isRetrying = attempt != null && attempt! > 1;
    final color = isRetrying ? KioskColors.warning : KioskColors.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            button ?? '준비 중…',
            style: TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isRetrying
                ? '$attempt번째 재시도 — 폐루프 좌표 재보정 중'
                : button != null
                    ? '버튼 누르는 중 · 센서 검증 대기'
                    : '버튼 시퀀스 초기화 중…',
            style: TextStyle(
              fontSize: 13,
              color: isRetrying
                  ? KioskColors.warning.withValues(alpha: 0.75)
                  : KioskColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

enum _StepState { done, current, failed, pending }

class _StepRow extends StatelessWidget {
  const _StepRow({required this.label, required this.state});
  final String label;
  final _StepState state;

  @override
  Widget build(BuildContext context) {
    final (Color color, IconData icon) = switch (state) {
      _StepState.done => (KioskColors.success, Icons.check),
      _StepState.current => (KioskColors.primary, Icons.play_arrow),
      _StepState.failed => (KioskColors.danger, Icons.close),
      _StepState.pending => (Colors.white24, Icons.circle_outlined),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: state == _StepState.pending ? Colors.white30 : Colors.white,
                fontWeight: state == _StepState.current
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 검증 신뢰도 — 큰 숫자(52px)로 심사석에서도 한눈에 읽힌다
class _BigConfidenceCard extends StatelessWidget {
  const _BigConfidenceCard({required this.confidence, required this.detail});

  final double? confidence;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final pct = (confidence ?? 0.0).clamp(0.0, 1.0);
    final low = confidence != null && confidence! < 0.7;
    final barColor = low ? KioskColors.warning : KioskColors.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        border: Border.all(
          color: confidence == null
              ? KioskColors.border
              : barColor.withValues(alpha: 0.40),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '검증 신뢰도',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.06,
                  color: KioskColors.muted,
                ),
              ),
              Icon(
                Icons.verified_outlined,
                size: 15,
                color: confidence == null ? KioskColors.muted : barColor,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                confidence == null ? '–' : (pct * 100).toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 52,
                  fontWeight: FontWeight.w300,
                  color: confidence == null ? Colors.white38 : Colors.white,
                  height: 1.0,
                ),
              ),
              if (confidence != null) ...[
                const SizedBox(width: 3),
                Text(
                  '%',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w300,
                    color: barColor.withValues(alpha: 0.80),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: KioskColors.border,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              style: const TextStyle(fontSize: 10, color: KioskColors.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// 재시도 횟수 — 1회 초과 시 경고 색상으로 전환
class _AttemptCard extends StatelessWidget {
  const _AttemptCard({required this.attempt});

  final int? attempt;

  @override
  Widget build(BuildContext context) {
    final warn = attempt != null && attempt! > 1;
    final color = warn ? KioskColors.warning : KioskColors.muted;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        border: Border.all(
          color: warn
              ? KioskColors.warning.withValues(alpha: 0.40)
              : KioskColors.border,
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '시도 횟수',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.06,
                  color: KioskColors.muted,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                attempt == null ? '–' : '$attempt회',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  color: warn ? KioskColors.warning : Colors.white,
                  height: 1.0,
                ),
              ),
            ],
          ),
          Icon(
            Icons.replay_circle_filled_outlined,
            size: 26,
            color: color,
          ),
        ],
      ),
    );
  }
}

// ── 4. 완료 화면 ────────────────────────────────────────────────────────

class _DoneView extends StatelessWidget {
  const _DoneView({super.key, required this.success, required this.label});
  final bool success;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = success ? KioskColors.success : KioskColors.danger;
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 0.65,
          colors: [color.withValues(alpha: 0.08), KioskColors.bg],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 이중 링 아이콘
            Container(
              width: 144,
              height: 144,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.05),
                border: Border.all(
                  color: color.withValues(alpha: 0.15),
                  width: 1,
                ),
              ),
              child: Center(
                child: Container(
                  width: 116,
                  height: 116,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color.withValues(alpha: 0.14),
                    border: Border.all(color: color.withValues(alpha: 0.45), width: 2),
                  ),
                  child: Icon(
                    success ? Icons.check : Icons.close,
                    size: 54,
                    color: color,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              success ? '완료' : '실패',
              style: TextStyle(
                fontSize: 38,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              success
                  ? '$label — 모든 버튼 동작 확인됨'
                  : '$label — 실행 중 문제가 발생했습니다',
              style: const TextStyle(fontSize: 16, color: KioskColors.muted),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 200,
              height: 4,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 1.0, end: 0.0),
                duration: _doneReturnDuration,
                builder: (context, value, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: value,
                    minHeight: 4,
                    backgroundColor: KioskColors.border,
                    valueColor:
                        AlwaysStoppedAnimation(Colors.white.withValues(alpha: 0.3)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
