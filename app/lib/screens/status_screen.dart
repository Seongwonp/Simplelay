import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/execution_status.dart';
import '../models/suggestion.dart';
import '../providers/appliance_provider.dart';
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
    // 이 실행이 대상으로 삼은 가전. 서버가 말해준 id로 설치 목록에서 찾는다 --
    // 지금 고른 가전이 아니다. 못 찾으면(지웠거나 구버전 서버) null이고,
    // 단계 이름은 전역 표로 떨어진다.
    final targetId = status.applianceId;
    final target = targetId == null
        ? null
        : ref
            .watch(installedAppliancesProvider)
            .where((a) => a.id == targetId)
            .firstOrNull;
    final active = status.phase == ExecutionPhase.running ||
        status.phase == ExecutionPhase.retrying ||
        status.phase == ExecutionPhase.waiting;

    // '확인 불가'에서도 정지·재확인을 남긴다. 통신이 끊긴 것이지 가전이
    // 멈춘 게 아니다 -- 가장 불안한 순간에 조작 수단이 사라지면 안 된다.
    final unknown = status.phase == ExecutionPhase.unknown;
    final canStop = active || unknown;

    // 음성 실행은 steps 미리보기가 비어 있다. 그래도 서버가 total_steps를
    // 주므로 진행을 보여줄 수 있다 -- steps.length에만 기대면 화면이 빈다.
    final totalSteps = status.totalSteps ?? status.steps.length;

    // 폐루프 검증 근거. 아직 결과가 없으면 '확인 중'임을 말해준다.
    // 숫자 자체보다 '눌림을 확인하고 있다'는 사실이 사용자에게 중요하다.
    final vDetail = status.verificationDetail;
    final vConf = status.verificationConfidence;
    final hasVerification =
        vConf != null || (vDetail != null && vDetail.isNotEmpty);
    final verification = !active
        ? null
        : !hasVerification
            ? '버튼 눌림을 확인하고 있어요.'
            : [
                if (vDetail != null && vDetail.isNotEmpty) vDetail,
                if (vConf != null) '센서 ${(vConf * 100).toStringAsFixed(0)}%',
                if ((status.currentAttempt ?? 1) > 1)
                  '${status.currentAttempt}번째 시도',
              ].join(' · ');

    // HTTP 경로엔 원시 mA/dB가 없다. 값이 없는데 차트를 띄우면 '--'만 남아
    // 개발 도구처럼 보인다 -- 실제 측정값이 있을 때만 센서 카드를 보여준다.
    final hasRawSensor = status.currentMa != null ||
        status.soundDb != null ||
        _maHistory.any((v) => v > 0) ||
        _dbHistory.any((v) => v > 0);

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

          // **지금 보고 있는 실행이** 모의일 때만 말한다. 전역 토글을
          // 보면 진짜로 움직이고 있는 작업 위에도 이 배너가 떠서, 화면이
          // 정반대의 말을 하게 된다 -- 폐루프의 존재 이유가 "눌림을
          // 확인했는가"인데 그 확인을 화면이 뒤집는 셈이다.
          if (status.isDemo)
            Semantics(
              liveRegion: true,
              label: '데모 모드입니다. 실제 조작이 아닙니다.',
              child: ExcludeSemantics(
                child: Container(
                  width: double.infinity,
                  color: context.appWarning.withValues(alpha: 0.16),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.science_outlined,
                          size: 18, color: context.appWarning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '데모 모드 — 실제 조작이 아닙니다',
                          style: TextStyle(
                            color: context.appWarning,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
                    status.message ?? '실행을 시작하면 진행 상황이 여기에 표시돼요.',
                    if (status.phase == ExecutionPhase.retrying) '자동 보정 중입니다',
                    if (active && status.currentButton != null)
                      '${status.currentButton} 버튼을 누르고 있어요',
                    if (active && verification != null) verification,
                    if (totalSteps > 0 && active)
                      '$totalSteps단계 중 ${status.completedSteps}단계 완료',
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
                          status.message ?? '실행을 시작하면 진행 상황이 여기에 표시돼요.',
                          style: TextStyle(color: context.appMuted),
                        ),
                      ],
                    ),
                  ),
                ),

                // ── 진행도 ───────────────────────────────────────────────
                // 예전에는 여기 KPI 3칸(진행·전류·음향)이 있었는데, 전류·음향은
                // 아래 '센서 모니터'와 같은 값을 두 번 보여주는 것이었다.
                // 센서는 한 곳에만 두고, 위에는 "지금 몇 단계인지"만 남긴다.
                // 지금 어떤 버튼을 누르고 있고, 눌림을 어떻게 확인하는지.
                // 이 제품의 차별점(실제 버튼을 누르고 센서로 확인)이 화면에
                // 도착하는 지점이다. 없으면 '빙글빙글 돌다 완료되는 앱'이 된다.
                if (active && status.currentButton != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    "'${status.currentButton}' 버튼을 누르고 있어요.",
                    style: AppText.title,
                  ),
                  if (verification != null) ...[
                    const SizedBox(height: 4),
                    Text(verification,
                        style: TextStyle(color: context.appMuted)),
                  ],
                ],

                if (status.phase != ExecutionPhase.idle && totalSteps > 0) ...[
                  const SizedBox(height: 16),
                  Text(
                    '$totalSteps단계 중 ${status.completedSteps}단계',
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
                      // **이 실행이 대상으로 삼은 가전**의 버튼 이름. 지금
                      // 고른 가전으로 읽으면 실행 중에 가전을 바꾼 순간
                      // 화면이 틀린 버튼 이름을 말한다.
                      label: target?.labelFor(status.steps[i]),
                      done: done,
                      current: current,
                      isLast: i == status.steps.length - 1,
                    );
                  }),
                ],

                // ── 센서 기록 (접힘) ───────────────────────────────────────
                //
                // 실행 중에 사용자가 판단해야 하는 것은 mA·dB 값이 아니라
                // **눌림을 확인했는가**다. 차트를 위에 크게 두면 화면이 기술
                // 데모 대시보드가 되고, 이 제품의 논지(실제로 누르고 센서로
                // 확인한다)가 숫자 뒤로 밀린다. 근거가 필요한 사람은 펼친다.
                if (hasRawSensor) ...[
                  const SizedBox(height: 20),
                  _SensorRecord(
                    stacked: MediaQuery.textScalerOf(context).scale(1) > 1.3,
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
                ],
              ],
            ),
          ),

          // ── 하단 고정 조작 영역 ──────────────────────────────────────
          // 정지는 스크롤 안에 두면 안 된다. 큰 글씨에서는 화면 밖으로
          // 밀리고, 정작 급한 순간(동작을 확인할 수 없을 때)에 손이 닿지
          // 않는다. 센서 카드 아래가 아니라 항상 같은 자리에 둔다.
          if (canStop)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (unknown) ...[
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => ref
                              .read(executionStatusProvider.notifier)
                              .recheck(),
                          icon: const Icon(Icons.refresh),
                          label: const Text('다시 확인'),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
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
                    ),
                  ],
                ),
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
            // 글씨를 키우면 한 줄에 안 들어간다 -- 줄바꿈할 공간을 준다.
            Expanded(
              child: Text('버튼 동작 재시도 중…',
                  style: TextStyle(color: context.appWarning)),
            ),
          ],
        ),
      );
}

// ── 실행 단계 타일 ────────────────────────────────────────────────────────

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.index,
    required this.code,
    this.label,
    required this.done,
    required this.current,
    required this.isLast,
  });
  final int index;
  final String code;

  /// 대상 가전이 알려준 이름. 대상을 모르면 null이고, 그때만 전역 표로
  /// 떨어진다 -- 그 표는 내장 가전 코드만 알고 있어서, 커스텀 가전의
  /// 버튼은 코드 그대로 나온다.
  final String? label;
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
                    Text(label ?? readableStep(code), style: AppText.body),
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

/// 센서 카드 두 장을 가로로 두거나(보통) 위아래로 쌓는다(확대).
///
/// 가로일 때는 Expanded가 필요하고 세로일 때는 오히려 방해가 되므로, 세로로 쌓을
/// 때는 Expanded 껍데기를 벗겨서 넣는다.
Widget _sensorPair({required bool stacked, required List<Widget> children}) {
  if (!stacked) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
  final unwrapped = <Widget>[];
  for (final child in children) {
    if (child is Expanded) {
      if (unwrapped.isNotEmpty) unwrapped.add(const SizedBox(height: 12));
      unwrapped.add(child.child);
    }
  }
  return Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: unwrapped);
}

// ── 센서 바차트 카드 ──────────────────────────────────────────────────────

/// 센서 기록 — 평상시 접혀 있고, 근거가 필요할 때만 편다.
class _SensorRecord extends StatefulWidget {
  const _SensorRecord({required this.stacked, required this.children});

  /// 확대 배율이 크면 두 카드를 위아래로 놓는다 -- 나란히 두면 각자 화면
  /// 절반밖에 못 써서 라벨과 수치가 함께 눌린다.
  final bool stacked;
  final List<Widget> children;

  @override
  State<_SensorRecord> createState() => _SensorRecordState();
}

class _SensorRecordState extends State<_SensorRecord> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              // 고령 사용자 기준 최소 터치 대상.
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Row(
                children: [
                  Icon(Icons.show_chart, size: 20, color: context.appMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '센서 기록 보기',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: context.appMuted,
                      ),
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    color: context.appMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 4),
          _sensorPair(stacked: widget.stacked, children: widget.children),
        ],
      ],
    );
  }
}

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
                // 확대하면 '전류 (mA)'가 반쪽 카드 폭을 넘는다 -- 줄바꿈할 자리를 준다
                Expanded(child: Text(label, style: context.appCaption)),
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
