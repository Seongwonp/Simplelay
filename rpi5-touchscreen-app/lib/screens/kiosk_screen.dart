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

  double? _currentMa;
  double? _soundDb;

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
            _currentMa = st.currentMa ?? _currentMa;
            _soundDb = st.soundDb ?? _soundDb;
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
            height: 3,
            child: _TopProgressBar(phase: _phase, execBarValue: _execBarValue),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _buildScreen(),
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
          currentMa: _currentMa,
          soundDb: _soundDb,
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.0, 1.0),
        alignment: Alignment.centerLeft,
        child: Container(color: KioskColors.primary, height: 3),
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
      color: KioskColors.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: KioskColors.primary.withValues(alpha: 0.08),
                border: Border.all(
                  color: KioskColors.primary.withValues(alpha: 0.2),
                  width: 1.5,
                ),
              ),
              child: Icon(appliance.icon, color: KioskColors.primary, size: 52),
            ),
            const SizedBox(height: 20),
            Text(
              appliance.name,
              style: const TextStyle(
                fontSize: 26,
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
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
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
                      color: connected ? KioskColors.success : const Color(0xFF444444),
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
                  const SizedBox(width: 7),
                  Text(
                    connected ? 'RPi 연결됨' : '연결 안 됨',
                    style: const TextStyle(fontSize: 13, color: KioskColors.muted),
                  ),
                  const SizedBox(width: 16),
                  Container(width: 1, height: 14, color: KioskColors.border),
                  const SizedBox(width: 16),
                  Text(
                    _clock,
                    style: const TextStyle(fontSize: 13, color: KioskColors.muted),
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
                    border: Border.all(color: KioskColors.primary.withValues(alpha: 0.28)),
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
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 10),
                RichText(
                  text: TextSpan(
                    style: const TextStyle(fontSize: 13, color: KioskColors.muted),
                    children: [
                      const TextSpan(text: '최근 '),
                      TextSpan(
                        text: '${suggestion.occurrences}',
                        style: const TextStyle(
                          color: KioskColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const TextSpan(text: '회 같은 시간대에 반복 감지'),
                    ],
                  ),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 68,
                  child: ElevatedButton.icon(
                    onPressed: onApprove,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KioskColors.success,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.check),
                    label: const Text(
                      '승인하고 실행',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '$cdRemaining',
                      style: const TextStyle(fontSize: 12, color: KioskColors.muted),
                    ),
                    const Text(
                      '초 후 자동 닫힘',
                      style: TextStyle(fontSize: 12, color: KioskColors.muted),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: cdRemaining / _countdownSeconds,
                          minHeight: 3,
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
                // 승인 전에는 어떤 시퀀스가 실행될지 서버가 아직 확정하지 않으므로
                // 하이라이트 없이 배치만 보여준다(승인 후 실행 화면에서 실제 순서가 나온다).
                Expanded(
                  child: _ButtonGrid(
                    appliance: appliance,
                    highlightIds: const [],
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
  const _ButtonGrid({required this.appliance, required this.highlightIds});

  final ApplianceMap appliance;
  final List<String> highlightIds;

  @override
  Widget build(BuildContext context) {
    final orderMap = <String, int>{};
    for (var i = 0; i < highlightIds.length; i++) {
      orderMap.putIfAbsent(highlightIds[i], () => i + 1);
    }

    return Column(
      children: List.generate(appliance.rows, (row) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: row < appliance.rows - 1 ? 7 : 0),
            child: Row(
              children: List.generate(appliance.cols, (col) {
                final btn = appliance.buttonAt(col, row);
                final order = btn != null ? orderMap[btn.id] : null;
                final isHighlighted = order != null;
                return Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: col < appliance.cols - 1 ? 7 : 0),
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
    required this.currentMa,
    required this.soundDb,
    required this.onStop,
  });

  final String title;
  final List<KioskButtonResult>? lastButtons;
  final double? currentMa;
  final double? soundDb;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 26, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: KioskColors.primary,
                        backgroundColor: KioskColors.primary.withValues(alpha: 0.18),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          lastButtons == null ? '실행 중…' : '완료',
                          style: const TextStyle(fontSize: 13, color: KioskColors.primary),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Expanded(
                  child: lastButtons == null
                      ? const _StepRow(label: '버튼 시퀀스 실행 중…', state: _StepState.current)
                      : ListView(
                          children: lastButtons!
                              .map(
                                (b) => _StepRow(
                                  label: b.button,
                                  state: b.success ? _StepState.done : _StepState.failed,
                                ),
                              )
                              .toList(),
                        ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          width: 236,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 24, 28, 24),
            child: Column(
              children: [
                _SensorCard(label: '전류', icon: Icons.bolt, value: currentMa, unit: 'mA', maxValue: 2000),
                const SizedBox(height: 12),
                _SensorCard(label: '음향', icon: Icons.volume_up, value: soundDb, unit: 'dB', maxValue: 100),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  height: 76,
                  child: ElevatedButton.icon(
                    onPressed: onStop,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KioskColors.danger.withValues(alpha: 0.1),
                      foregroundColor: KioskColors.danger,
                      side: const BorderSide(color: KioskColors.danger, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('긴급 정지', style: TextStyle(fontWeight: FontWeight.w700)),
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
            decoration: BoxDecoration(color: color.withValues(alpha: 0.18), shape: BoxShape.circle),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: state == _StepState.pending ? Colors.white30 : Colors.white,
                fontWeight: state == _StepState.current ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SensorCard extends StatelessWidget {
  const _SensorCard({
    required this.label,
    required this.icon,
    required this.value,
    required this.unit,
    required this.maxValue,
  });

  final String label;
  final IconData icon;
  final double? value;
  final String unit;
  final double maxValue;

  @override
  Widget build(BuildContext context) {
    final pct = value == null ? 0.0 : (value! / maxValue).clamp(0.0, 1.0);
    final warn = value != null && (value! / maxValue) > 0.75;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: KioskColors.surface,
        border: Border.all(color: KioskColors.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.07,
                  color: KioskColors.muted,
                ),
              ),
              Icon(icon, size: 14, color: KioskColors.muted),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value == null ? '–' : value!.toStringAsFixed(0),
                style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w300, color: Colors.white),
              ),
              Text(' $unit', style: const TextStyle(fontSize: 14, color: KioskColors.muted)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 4,
              backgroundColor: KioskColors.border,
              valueColor: AlwaysStoppedAnimation(
                warn ? KioskColors.warning : KioskColors.primary,
              ),
            ),
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
      color: KioskColors.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 104,
              height: 104,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color.withValues(alpha: 0.4), width: 2),
              ),
              child: Icon(
                success ? Icons.check : Icons.close,
                size: 48,
                color: color,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              success ? '완료' : '실패',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: color),
            ),
            const SizedBox(height: 6),
            Text(
              success ? '$label — 모든 버튼 동작 확인됨' : '$label — 실행 중 문제가 발생했습니다',
              style: const TextStyle(fontSize: 15, color: KioskColors.muted),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 180,
              height: 3,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 1.0, end: 0.0),
                duration: _doneReturnDuration,
                builder: (context, value, _) => ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: value,
                    backgroundColor: KioskColors.border,
                    valueColor: AlwaysStoppedAnimation(Colors.white.withValues(alpha: 0.3)),
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
