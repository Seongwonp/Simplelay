import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/appliance.dart';
import '../models/execution_status.dart';
import '../models/suggestion.dart';
import '../providers/appliance_provider.dart';
import '../providers/execution_status_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/button_map_grid.dart';

/// 실행 상태 -- 센서 대시보드가 아니라 **물리 폐루프의 진행과 회복**을 보여준다.
///
/// 읽는 순서: 지금 무슨 버튼을 어떻게 하고 있는가(가장 크게) → 몇 단계 중
/// 몇 번째인가(구간형) → 전체 순서 → (펼쳐야 보이는) 센서 기록. 정지는
/// 스크롤 밖 고정 자리에, 색뿐 아니라 모양으로도 다른 버튼과 구분한다.
///
/// 화면은 조리·세탁이 끝났다고 말하지 않는다. 우리가 보장하는 것은
/// **버튼 조작**까지다.
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

    final now = _NowState.of(status);

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
          // **지금 보고 있는 실행이** 모의일 때만 말한다. 전역 토글을
          // 보면 진짜로 움직이고 있는 작업 위에도 이 배너가 떠서, 화면이
          // 정반대의 말을 하게 된다 -- 폐루프의 존재 이유가 "눌림을
          // 확인했는가"인데 그 확인을 화면이 뒤집는 셈이다.
          if (status.isDemo)
            Semantics(
              liveRegion: true,
              label: '데모 모드예요. 실제로 조작하지 않아요.',
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
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                // ── 어느 가전, 무슨 일 ─────────────────────────────────────
                // liveRegion: 실행 상태는 사용자가 화면을 다시 훑지 않아도
                // 스크린리더가 바뀔 때마다 읽어줘야 하는 정보다. 눈으로
                // 진행 표시를 볼 수 없는 사용자에게는 이것이 유일한 채널.
                Semantics(
                  liveRegion: true,
                  label: [
                    if (target != null) target.displayName,
                    status.label ?? '실행 중인 작업 없음',
                    if (now.button != null) "${now.button} 버튼",
                    now.headline,
                    if (now.detail != null) now.detail!,
                    if (totalSteps > 0 && status.phase != ExecutionPhase.idle)
                      '총 $totalSteps단계 중 ${status.completedSteps}단계 완료',
                  ].join('. '),
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (target != null) ...[
                          _TargetLine(appliance: target),
                          const SizedBox(height: 6),
                        ],
                        Text(
                          status.label ?? '실행 중인 작업 없음',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: status.phase == ExecutionPhase.idle
                                ? null
                                : context.appMuted,
                          ),
                        ),
                        const SizedBox(height: 16),

                        // ── 지금 무엇을 하고 있는가 — 가장 크게 ────────────
                        // 이 제품의 차별점(실제 버튼을 누르고 센서로 확인)이
                        // 화면에 도착하는 지점이다. 없으면 '빙글빙글 돌다
                        // 완료되는 앱'이 된다.
                        _NowBlock(now: now),
                      ],
                    ),
                  ),
                ),

                // ── 진행 — 구간형 ─────────────────────────────────────────
                // 연속 퍼센트가 아니다. 버튼 5개 중 2개를 눌렀다는 사실은
                // 40%가 아니라 '5개 중 2개'다. 퍼센트는 마치 남은 시간을
                // 아는 것처럼 보이게 하는데, 우리는 모른다.
                if (status.phase != ExecutionPhase.idle && totalSteps > 0) ...[
                  const SizedBox(height: 24),
                  _SegmentedProgress(
                    total: totalSteps,
                    completed: status.completedSteps,
                    phase: status.phase,
                  ),
                ],

                // ── 실제 버튼판에서 지금 어디인가 ──────────────────────────
                // 이 제품이 하는 일은 실제 버튼을 누르는 것이다. 이름 목록만
                // 있으면 '앱이 돌다 끝나는 화면'과 구별되지 않는다 -- 가전의
                // 버튼판 위에 지금 누르는 자리를 보여준다. 대상 가전을 모르면
                // (지웠거나 구버전 서버) 배치를 지어내지 않고 목록만 둔다.
                // 스크린리더에는 위의 실시간 안내와 아래 목록이 같은 말을
                // 이미 하므로, 그림은 읽지 않는다.
                if (target != null &&
                    status.steps.isNotEmpty &&
                    status.phase != ExecutionPhase.idle) ...[
                  const SizedBox(height: 28),
                  Text('${target.displayName} 버튼판', style: AppText.title),
                  const SizedBox(height: 10),
                  ExcludeSemantics(
                    child: ButtonMapGrid(
                      appliance: target,
                      steps: status.steps,
                      completed: status.completedSteps,
                      active: active,
                      caution: status.phase == ExecutionPhase.retrying,
                    ),
                  ),
                ],

                // ── 단계 목록 ─────────────────────────────────────────────
                if (status.steps.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  Text('누르는 순서', style: AppText.title),
                  const SizedBox(height: 6),
                  for (var i = 0; i < status.steps.length; i++)
                    _StepRow(
                      index: i,
                      // **이 실행이 대상으로 삼은 가전**의 버튼 이름. 지금
                      // 고른 가전으로 읽으면 실행 중에 가전을 바꾼 순간
                      // 화면이 틀린 버튼 이름을 말한다.
                      label: _stepLabel(target, status.steps[i]),
                      state: i < status.completedSteps
                          ? _StepState.done
                          : (i == status.completedSteps && active)
                              ? _StepState.current
                              : _StepState.pending,
                      isLast: i == status.steps.length - 1,
                    ),
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
            _StopArea(
              showRecheck: unknown,
              onRecheck: () =>
                  ref.read(executionStatusProvider.notifier).recheck(),
              onStop: () =>
                  ref.read(executionStatusProvider.notifier).emergencyStop(),
            ),
        ],
      ),
    );
  }

  /// 대상 가전에 등록된 이름 그대로. 대상을 모르면 전역 표(내장 코드만
  /// 안다) -- 커스텀 가전의 버튼은 코드 그대로 나온다. 지어내지 않는다.
  static String _stepLabel(ApplianceMap? target, String code) =>
      target != null && target.buttons.any((b) => b.id == code)
          ? target.labelFor(code)
          : readableStep(code);
}

// ── 지금 상태 ─────────────────────────────────────────────────────────────

/// 화면이 가장 크게 말할 한 줄과 그 근거.
///
/// 서버가 구분해 주는 것만 말한다. 지금 서버는 '어느 버튼을 몇 번째로
/// 시도 중이고 검증 결과가 있는가'를 주지, '이동 중'과 '누르는 중'을
/// 나눠 주지 않는다. 그래서 그 둘을 화면이 나눠 말하지 않는다 -- 모르는
/// 것을 아는 척하면 실제 축이 멈춰 있는데 '이동 중'이라고 쓰게 된다.
class _NowState {
  const _NowState({
    required this.headline,
    this.button,
    this.detail,
    this.tone = _Tone.neutral,
    this.retryNote,
    this.idle = false,
  });

  /// 아무것도 하고 있지 않다. 그때만 안내 문구를 작게 쓴다 -- 실행 중의
  /// '실행 중'은 지금 상태이므로 다른 국면과 같은 크기로 말한다.
  final bool idle;

  /// 가장 큰 글자. 버튼이 있으면 그 아래 상태 구절이다.
  final String headline;

  /// 지금 다루는 버튼 이름. 있으면 headline보다 위에 더 크게 쓴다.
  final String? button;

  /// 근거 한 줄(검증 결과·시도 횟수).
  final String? detail;
  final _Tone tone;

  /// 재시도 중일 때, 그것이 실패가 아니라 보정이라는 설명.
  final String? retryNote;

  static _NowState of(ExecutionStatus s) {
    final vDetail = s.verificationDetail;
    final vConf = s.verificationConfidence;
    final hasVerification =
        vConf != null || (vDetail != null && vDetail.isNotEmpty);
    final attempt = s.currentAttempt ?? 1;
    final evidence = [
      if (vDetail != null && vDetail.isNotEmpty) vDetail,
      if (vConf != null) '센서 ${(vConf * 100).toStringAsFixed(0)}%',
      if (attempt > 1) '$attempt번째 시도',
    ].join(' · ');

    switch (s.phase) {
      case ExecutionPhase.idle:
        return const _NowState(
          headline: '실행을 시작하면 진행 상황이 여기에 표시돼요.',
          idle: true,
        );
      case ExecutionPhase.waiting:
        return _NowState(headline: s.message ?? '실행 요청을 보냈어요');
      case ExecutionPhase.running:
        if (s.currentButton == null) {
          return const _NowState(headline: '실행 중');
        }
        return _NowState(
          button: s.currentButton,
          headline: hasVerification ? '눌림 확인 중' : '누르는 중',
          // 근거가 아직 없어도 확인하고 있다는 사실은 말한다 -- 숫자보다
          // '눌림을 확인한다'는 것이 사용자에게 중요하다.
          detail: hasVerification ? evidence : '버튼 눌림을 확인하고 있어요.',
        );
      case ExecutionPhase.retrying:
        return _NowState(
          button: s.currentButton,
          headline: '보정 후 다시 시도 중',
          detail: evidence.isEmpty ? null : evidence,
          tone: _Tone.caution,
          // '재시도'는 실패로 읽힌다. 눌림이 확인되지 않아 자리를 다시
          // 맞추고 누르는 것은 이 제품이 하기로 한 일이다.
          retryNote: '눌림이 확인되지 않아 자리를 맞추고 다시 눌러요.',
        );
      case ExecutionPhase.completed:
        return _NowState(
          headline: s.message ?? '버튼 조작을 마쳤어요.',
          tone: _Tone.done,
        );
      case ExecutionPhase.failed:
        return _NowState(
          headline: s.message ?? '실행하지 못했어요.',
          tone: _Tone.failed,
        );
      case ExecutionPhase.unknown:
        return _NowState(
          headline: s.message ?? '동작을 확인할 수 없어요.',
          tone: _Tone.caution,
        );
    }
  }
}

enum _Tone { neutral, caution, done, failed }

class _NowBlock extends StatelessWidget {
  const _NowBlock({required this.now});

  final _NowState now;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (now.tone) {
      _Tone.neutral => (null, null),
      _Tone.caution => (Icons.error_outline, context.appWarning),
      _Tone.done => (Icons.check_circle_outline, context.appSuccess),
      _Tone.failed => (Icons.cancel_outlined, context.appDanger),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (now.button != null)
          Text("'${now.button}'", style: AppText.heading),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 상태를 색으로만 말하지 않는다 -- 모양이 같이 간다.
            if (icon != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Icon(icon, size: 24, color: color),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                now.headline,
                style: now.button != null
                    ? TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w600, color: color)
                    : TextStyle(
                        fontSize: now.idle ? 16 : 22,
                        fontWeight:
                            now.idle ? FontWeight.w400 : FontWeight.w600,
                        color: color ?? (now.idle ? context.appMuted : null),
                      ),
              ),
            ),
          ],
        ),
        if (now.detail != null) ...[
          const SizedBox(height: 4),
          Text(now.detail!, style: TextStyle(color: context.appMuted)),
        ],
        if (now.retryNote != null) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.refresh, size: 18, color: context.appWarning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(now.retryNote!,
                    style: TextStyle(fontSize: 15, color: context.appWarning)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ── 대상 가전 한 줄 ───────────────────────────────────────────────────────

class _TargetLine extends StatelessWidget {
  const _TargetLine({required this.appliance});

  final ApplianceMap appliance;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(appliance.icon, size: 18, color: context.appMuted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              appliance.displayName,
              style: TextStyle(fontSize: 15, color: context.appMuted),
            ),
          ),
        ],
      );
}

// ── 구간형 진행 ───────────────────────────────────────────────────────────

/// N칸 중 K칸. 채운 칸은 완료, 지금 칸은 테두리로 구분, 나머지는 비움.
/// 색을 빼도 채움/테두리/비움 세 가지가 남는다.
class _SegmentedProgress extends StatelessWidget {
  const _SegmentedProgress({
    required this.total,
    required this.completed,
    required this.phase,
  });

  final int total;
  final int completed;
  final ExecutionPhase phase;

  @override
  Widget build(BuildContext context) {
    final active =
        phase == ExecutionPhase.running || phase == ExecutionPhase.retrying;
    // 끝난 칸은 무채색으로 채우고, 지금 칸의 테두리만 강조한다 -- 보라는
    // '지금'에만 쓴다. 재시도는 주의색.
    final accent =
        phase == ExecutionPhase.retrying ? context.appWarning : context.appPrimary;
    final doneColor =
        phase == ExecutionPhase.retrying ? context.appWarning : context.appInk;
    // 단계가 많으면 칸이 너무 얇아진다 -- 12개까지만 칸으로 그리고, 그
    // 이상은 글자가 대신 말한다.
    final drawSegments = total <= 12;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('총 $total단계 중 $completed단계', style: AppText.title),
        if (drawSegments) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < total; i++) ...[
                Expanded(
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                      color: i < completed
                          ? doneColor
                          : Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(3),
                      border: (i == completed && active)
                          ? Border.all(color: accent, width: 2)
                          : null,
                    ),
                  ),
                ),
                if (i < total - 1) const SizedBox(width: 4),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

// ── 단계 행 ───────────────────────────────────────────────────────────────

enum _StepState { done, current, pending }

/// 카드로 감싸지 않는다. 완료는 체크, 지금은 채운 원 + '지금' 글자, 나머지는
/// 빈 원 -- 색을 빼도 셋이 구분된다.
class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.index,
    required this.label,
    required this.state,
    required this.isLast,
  });

  final int index;
  final String label;
  final _StepState state;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (state) {
      _StepState.done => (Icons.check_circle, context.appSuccess),
      _StepState.current => (Icons.radio_button_checked, context.appPrimary),
      _StepState.pending => (Icons.radio_button_unchecked, context.appMuted),
    };
    final current = state == _StepState.current;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                    color: state == _StepState.pending
                        ? context.appOnSurfaceSoft
                        : null,
                  ),
                ),
              ),
              if (current)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    border: Border.all(color: context.appPrimary, width: 1.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '지금',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: context.appPrimary,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (!isLast) Divider(height: 1, color: context.appBorderFaint),
      ],
    );
  }
}

// ── 정지 영역 ─────────────────────────────────────────────────────────────

/// 긴급 정지는 색뿐 아니라 **정지 기호·두꺼운 외곽선·격리된 자리**로
/// 구분한다. 흑백에서 '다시 확인'과 같은 회색 막대 둘로 보이면, 급한 순간에
/// 어느 쪽인지 읽어야 한다.
class _StopArea extends StatelessWidget {
  const _StopArea({
    required this.showRecheck,
    required this.onRecheck,
    required this.onStop,
  });

  final bool showRecheck;
  final VoidCallback onRecheck;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) => Material(
        color: context.appBackground,
        child: SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.appBorderFaint)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showRecheck) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onRecheck,
                      icon: const Icon(Icons.refresh),
                      label: const Text('다시 확인'),
                    ),
                  ),
                  // 정지와 재확인 사이를 띄운다 -- 붙여 두면 급할 때
                  // 옆 것을 누른다.
                  const SizedBox(height: 16),
                ],
                SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.stop,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: Theme.of(context).colorScheme.onSurface,
                          width: 3,
                        ),
                      ),
                    ),
                    onPressed: onStop,
                    icon: const Icon(Icons.stop, size: 28),
                    label: const Text(
                      '긴급 정지',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
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
      v >= warningThreshold ? context.appWarning : context.appInk;

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
                Icon(icon, color: context.appMuted, size: 18),
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
