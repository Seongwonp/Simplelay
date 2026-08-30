import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/execution_status.dart';
import '../models/suggestion.dart';
import '../providers/execution_status_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key});

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  // 슬라이딩 윈도우 20샘플 — 새 값이 들어올 때마다 맨 앞을 제거하고 추가
  // growable: true 필수 — List.filled 기본값(growable: false)은 removeAt에서 예외를 던진다.
  final List<double> _maHistory = List.filled(20, 0.0, growable: true);
  final List<double> _dbHistory = List.filled(20, 0.0, growable: true);

  @override
  Widget build(BuildContext context) {
    // ref.listen은 build 안에서만 호출 가능 (Riverpod 규칙)
    ref.listen(executionStatusProvider, (_, next) {
      setState(() {
        if (next.currentMa != null) {
          _maHistory.removeAt(0);
          _maHistory.add(next.currentMa!);
        }
        if (next.soundDb != null) {
          _dbHistory.removeAt(0);
          _dbHistory.add(next.soundDb!);
        }
      });
    });

    final status = ref.watch(executionStatusProvider);
    final active = status.phase == ExecutionPhase.running ||
        status.phase == ExecutionPhase.retrying ||
        status.phase == ExecutionPhase.waiting;

    return Scaffold(
      appBar: AppBar(title: const Text('실행 상태')),
      body: Column(
        children: [
          // ── 진행 바 (실행 중일 때만) ────────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: active ? 6 : 0,
            child: active
                ? LinearProgressIndicator(
                    borderRadius: BorderRadius.zero,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHigh,
                    color: status.phase == ExecutionPhase.retrying
                        ? context.appWarning
                        : Theme.of(context).colorScheme.primary,
                  )
                : null,
          ),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── 제목·상태 ──────────────────────────────────────────────
                // liveRegion: 실행 상태는 사용자가 화면을 다시 훑지 않아도
                // 스크린리더가 바뀔 때마다 읽어줘야 하는 정보다. 눈으로
                // 진행바를 볼 수 없는 사용자에게는 이것이 유일한 진행 채널.
                Semantics(
                  liveRegion: true,
                  label: [
                    status.label ?? '실행 중인 작업 없음',
                    status.message ?? '승인한 동작의 진행 상황이 여기에 표시됩니다.',
                    if (status.phase == ExecutionPhase.retrying) '자동 보정 중입니다',
                    if (status.steps.isNotEmpty && active)
                      '${status.steps.length}단계 중 ${status.completedSteps}단계 완료',
                  ].join('. '),
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status.label ?? '실행 중인 작업 없음',
                          style: AppText.heading,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          status.message ?? '승인한 동작의 진행 상황이 여기에 표시됩니다.',
                          style:
                              TextStyle(color: context.appMuted),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── 진행도 ───────────────────────────────────────────────
                // 예전에는 여기 KPI 3칸(진행·전류·음향)이 있었는데, 전류·음향은
                // 아래 '센서 모니터'와 같은 값을 두 번 보여주는 것이었다.
                // 센서는 한 곳에만 두고, 위에는 "지금 몇 단계인지"만 남긴다.
                if (status.phase != ExecutionPhase.idle &&
                    status.steps.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '${status.steps.length}단계 중 ${status.completedSteps}단계',
                    style: AppText.title,
                  ),
                ],

                // ── 재시도 배너 ────────────────────────────────────────────
                if (status.phase == ExecutionPhase.retrying) ...[
                  const SizedBox(height: 16),
                  _RetryBanner(),
                ],

                // ── 단계 목록 ─────────────────────────────────────────────
                if (status.steps.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('실행 단계', style: AppText.title),
                  const SizedBox(height: 12),
                  ...List.generate(status.steps.length, (i) {
                    final done = i < status.completedSteps;
                    final current = i == status.completedSteps && active;
                    return _StepTile(
                      index: i,
                      code: status.steps[i],
                      done: done,
                      current: current,
                      isLast: i == status.steps.length - 1,
                    );
                  }),
                ],

                // ── 센서 바차트 ────────────────────────────────────────────
                const SizedBox(height: 28),
                Text('센서 모니터', style: AppText.title),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _SensorChart(
                        label: '전류 (mA)',
                        icon: Icons.electric_bolt,
                        history: _maHistory,
                        maxY: 2000,
                        warningThreshold: 1500,
                        current: status.currentMa,
                        unit: 'mA',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _SensorChart(
                        label: '음향 (dB)',
                        icon: Icons.graphic_eq,
                        history: _dbHistory,
                        maxY: 100,
                        warningThreshold: 80,
                        current: status.soundDb,
                        unit: 'dB',
                      ),
                    ),
                  ],
                ),

                // ── 긴급 정지 ─────────────────────────────────────────────
                if (active) ...[
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                      foregroundColor: AppColors.onAccent,
                    ),
                    onPressed: () => ref
                        .read(executionStatusProvider.notifier)
                        .emergencyStop(),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('긴급 정지'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── 재시도 배너 ───────────────────────────────────────────────────────────

class _RetryBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: context.appWarning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.appWarning.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(Icons.refresh, color: context.appWarning, size: 20),
            const SizedBox(width: 10),
            Text('버튼 동작 재시도 중…',
                style: TextStyle(color: context.appWarning)),
          ],
        ),
      );
}

// ── 실행 단계 타일 ────────────────────────────────────────────────────────

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.index,
    required this.code,
    required this.done,
    required this.current,
    required this.isLast,
  });
  final int index;
  final String code;
  final bool done;
  final bool current;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final Color iconColor;
    final IconData iconData;
    if (done) {
      iconColor = context.appSuccess;
      iconData = Icons.check_circle;
    } else if (current) {
      iconColor = Theme.of(context).colorScheme.primary;
      iconData = Icons.pending;
    } else {
      iconColor = context.appBorderSubtle;
      iconData = Icons.radio_button_unchecked;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Icon(iconData,
                    key: ValueKey(iconData), color: iconColor, size: 22),
              ),
              if (!isLast) // 마지막 단계 뒤에는 연결선을 그리지 않는다
                Container(
                  width: 2,
                  height: 24,
                  color: done
                      ? context.appSuccess.withValues(alpha: 0.4)
                      : context.appBorderSubtle,
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Card(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(readableStep(code), style: AppText.body),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 센서 바차트 카드 ──────────────────────────────────────────────────────

class _SensorChart extends StatelessWidget {
  const _SensorChart({
    required this.label,
    required this.icon,
    required this.history,
    required this.maxY,
    required this.warningThreshold,
    required this.current,
    required this.unit,
  });

  final String label;
  final IconData icon;
  final List<double> history;
  final double maxY;
  final double warningThreshold;
  final double? current;
  final String unit;

  // context를 인자로 받는다 — 라이트/다크에 따라 강조색이 달라지므로
  // 테마 없이 색을 결정할 수 없다.
  Color _barColor(BuildContext context, double v) =>
      v >= warningThreshold ? context.appWarning : context.appPrimary;

  @override
  Widget build(BuildContext context) {
    final displayValue =
        current == null ? '--' : '${current!.toStringAsFixed(0)} $unit';

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: context.appPrimary, size: 18),
                const SizedBox(width: 6),
                Text(label, style: context.appCaption),
              ],
            ),
            const SizedBox(height: 6),
            Text(displayValue, style: AppText.sensor),
            const SizedBox(height: 12),
            SizedBox(
              height: 64,
              child: BarChart(
                BarChartData(
                  maxY: maxY,
                  minY: 0,
                  barGroups: history
                      .asMap()
                      .entries
                      .map(
                        (e) => BarChartGroupData(
                          x: e.key,
                          barRods: [
                            BarChartRodData(
                              toY: e.value.clamp(0, maxY),
                              color: _barColor(context, e.value),
                              width: 7,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ],
                        ),
                      )
                      .toList(),
                  titlesData: const FlTitlesData(show: false),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  barTouchData: BarTouchData(enabled: false),
                ),
                swapAnimationDuration: const Duration(milliseconds: 150),
                swapAnimationCurve: Curves.easeOut,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
