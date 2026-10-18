import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/line_break.dart';
import '../models/appliance.dart';
import '../models/command_result.dart';
import '../models/execution_status.dart';
import '../models/scenario_run.dart';
import '../models/suggestion.dart';
import '../providers/appliance_provider.dart';
import '../providers/execution_status_provider.dart';
import '../providers/hub_provider.dart' show developerModeProvider;
import '../providers/rpi_api_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/button_map_grid.dart';
import '../widgets/voice_stop_indicator.dart';
import '../theme/app_tokens.dart';

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
    // 전기·소리 수치는 개발자 모드(본체가 켠 개발자 조건)일 때만 — 일반 화면에 mA·dB를 내지 않는다(평가 5차 10/18).
    final hasRawSensor = ref.watch(developerModeProvider) &&
        (status.currentMa != null ||
            status.soundDb != null ||
            _maHistory.any((v) => v > 0) ||
            _dbHistory.any((v) => v > 0));

    return Scaffold(
      appBar: AppBar(title: const Text('실행 상태')),
      body: Column(
        children: [
          // **지금 보고 있는 실행이** 모의일 때만 말한다. 전역 토글을
          // 보면 진짜로 움직이고 있는 작업 위에도 이 배너가 떠서, 화면이
          // 정반대의 말을 하게 된다 -- 폐루프의 존재 이유가 "눌림을
          // 확인했는가"인데 그 확인을 화면이 뒤집는 셈이다.
          if (status.phase != ExecutionPhase.idle && status.modeLabel.isNotEmpty)
            Semantics(
              liveRegion: true,
              label: status.modeLabel,
              child: ExcludeSemantics(
                child: Container(
                  width: double.infinity,
                  color: context.appWarning.withValues(alpha: 0.16),
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpace.xl, vertical: AppSpace.sm),
                  child: Row(
                    children: [
                      Icon(Icons.science_outlined,
                          size: 18, color: context.appWarning),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Text(
                          status.modeLabel,
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
              padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.xxl),
              children: [
                // ── 어느 가전, 무슨 일 ─────────────────────────────────────
                // liveRegion: 실행 상태는 사용자가 화면을 다시 훑지 않아도
                // 스크린리더가 바뀔 때마다 읽어줘야 하는 정보다. 눈으로
                // 진행 표시를 볼 수 없는 사용자에게는 이것이 유일한 채널.
                Semantics(
                  liveRegion: true,
                  label: [
                    if (target != null) target.displayName,
                    status.label ?? '지금 하는 일이 없어요',
                    if (now.button != null) "${now.button} 버튼",
                    now.headline,
                    if (now.detail != null) now.detail!,
                    if (_finished(status.phase)) ..._resultFactWords(status),
                    if (_finished(status.phase))
                      if (operationSentence(status) case final o?) o,
                    if (totalSteps > 1 && status.phase != ExecutionPhase.idle)
                      '$totalSteps개 중 ${status.completedSteps}개 했어요',
                  ].join('. '),
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (target != null) ...[
                          _TargetLine(appliance: target),
                          const SizedBox(height: AppSpace.sm),
                        ],
                        Text(
                          status.label ?? '지금 하는 일이 없어요',
                          style: TextStyle(
                            fontSize: AppFont.cardTitle,
                            fontWeight: FontWeight.w600,
                            color: status.phase == ExecutionPhase.idle
                                ? null
                                : context.appMuted,
                          ),
                        ),
                        const SizedBox(height: AppSpace.lg),

                        // ── 지금 무엇을 하고 있는가 — 가장 크게 ────────────
                        // 이 제품의 차별점(실제 버튼을 누르고 센서로 확인)이
                        // 화면에 도착하는 지점이다. 없으면 '빙글빙글 돌다
                        // 완료되는 앱'이 된다.
                        _NowBlock(now: now),
                        // 끝난 실행의 경로·확인 수준. 서버가 준 값만 말한다.
                        if (_finished(status.phase))
                          _ResultFacts(status: status),
                      ],
                    ),
                  ),
                ),

                // ── 단계별 결과(G4) ───────────────────────────────────────
                // 위 한 줄은 /status의 **마지막 단계** 기준이다. 두 가전을 잇는
                // 실행이 끝났으면 단계마다 경로·확인 수준을 따로 보인다 -- 그
                // job의 기록일 때만(다른 실행의 단계를 내 결과로 보이지 않는다).
                if (_finished(status.phase) && status.sequenceId != null)
                  _RunSteps(jobId: status.sequenceId!),

                // ── 진행 — 구간형 ─────────────────────────────────────────
                // 연속 퍼센트가 아니다. 버튼 5개 중 2개를 눌렀다는 사실은
                // 40%가 아니라 '5개 중 2개'다. 퍼센트는 마치 남은 시간을
                // 아는 것처럼 보이게 하는데, 우리는 모른다.
                // 조작이 하나뿐이면 진행 막대를 그리지 않는다 — 위 결과 문장이 다 말한다(외부 평가 10/16 p08).
                if (status.phase != ExecutionPhase.idle && totalSteps > 1) ...[
                  const SizedBox(height: AppSpace.xxl),
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
                // ThinQ 가전은 누를 버튼판이 없다 — 그리지 않는다(2026-10-15).
                if (target != null &&
                    !target.isThinq &&
                    status.steps.isNotEmpty &&
                    status.phase != ExecutionPhase.idle) ...[
                  const SizedBox(height: AppSpace.xxxl),
                  Text('${target.displayName} 버튼판', style: AppText.title),
                  const SizedBox(height: AppSpace.md),
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
                // ThinQ 한 단계는 제목과 같은 말이라 목록을 되풀이하지 않는다(외부 평가 10/16 p08).
                if (status.steps.length > 1 ||
                    (status.steps.isNotEmpty && target?.isThinq != true)) ...[
                  const SizedBox(height: AppSpace.xxxl),
                  Text(target?.isThinq == true ? '할 일' : '누르는 순서',
                      style: AppText.title),
                  const SizedBox(height: AppSpace.sm),
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
                  const SizedBox(height: AppSpace.xl),
                  _SensorRecord(
                    stacked: MediaQuery.textScalerOf(context).scale(1) > 1.3,
                    children: [
                      Expanded(
                        child: _SensorChart(
                          label: '전기 사용',
                          icon: Icons.electric_bolt,
                          history: _maHistory,
                          maxY: 2000,
                          warningThreshold: 1500,
                          current: status.currentMa,
                          unit: 'mA',
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: _SensorChart(
                          label: '소리',
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
          if (_finished(status.phase))
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_retryAdvised(status))
                      const Text('가전을 본 뒤 처음 화면에서 다시 해 주세요.'),
                    FilledButton(
                      onPressed: _returnToOrigin,
                      child: Text(_retryAdvised(status) ? '다시 하기' : '확인'),
                    ),
                    // '확인'과 같은 일을 하는 '닫기'는 다시 시도할 때만 둔다(외부 평가 10/16 p08 — 중복 버튼).
                    if (_retryAdvised(status))
                      TextButton(onPressed: _returnToOrigin, child: const Text('닫기')),
                  ],
                ),
              ),
            ),
          // 실행 중 음성 '멈춰'를 듣는 동안만 보인다(2026-10-07).
          const VoiceStopIndicator(),
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

  /// 다시 실행을 권해도 되는가. 실패는 **미전송 근거(not_dispatched)가 있을 때만** — 접수된 뒤 일부를 누르고
  /// 실패했을 수 있어 일괄 재시도 권고는 이미 한 조작을 되풀이하게 한다(외부 평가 2026-10-13 M4).
  /// 안전 정지는 종전대로(가전을 확인한 뒤).
  /// 모션 걸림·재시작 등(abortReason)은 권하지 않는다 — 장치를 먼저 봐야 하고 같은 조작을 되풀이하면 또 걸린다(2026-10-14).
  bool _retryAdvised(ExecutionStatus status) => switch (_kindOf(status)) {
        ResultKind.safetyStop => status.abortReason == null,
        ResultKind.failed => status.receipt == 'not_dispatched',
        _ => false,
      };

  void _returnToOrigin() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go('/');
    }
  }

  /// 대상 가전에 등록된 이름 그대로. 대상을 모르면 전역 표(내장 코드만
  /// 안다) -- 커스텀 가전의 버튼은 코드 그대로 나온다. 지어내지 않는다.
  static String _stepLabel(ApplianceMap? target, String code) =>
      target != null && target.buttons.any((b) => b.id == code)
          ? target.labelFor(code)
          : readableStep(code);
}

// ── 끝난 실행의 경로·확인 수준 ──────────────────────────────────────────

bool _finished(ExecutionPhase p) =>
    p == ExecutionPhase.completed ||
    p == ExecutionPhase.failed ||
    p == ExecutionPhase.unconfirmed;

ResultKind _kindOf(ExecutionStatus s) => s.outcome != null
    ? resultKindOf(outcome: s.outcome)
    : switch (s.phase) {
        ExecutionPhase.completed => ResultKind.success,
        ExecutionPhase.unconfirmed => ResultKind.unconfirmed,
        _ => ResultKind.failed,
      };

/// 결과 한 단어 · 경로 · 확인 수준. 옛 서버(필드 없음)면 결과 단어만 남는다.
///
/// 물리 경로 칩은 두지 않는다 — 결과 문장("버튼 조작을 마쳤어요"·"누름 장치가
/// 응답했어요")이 이미 말한다(2026-10-13, 기록 문구 규칙과 같은 원칙). ThinQ는
/// 결과 문장만으로 경로가 드러나지 않을 수 있어 남긴다.
List<String> _resultFactWords(ExecutionStatus s) {
  final kind = _kindOf(s);
  return [
    // 옛 서버에서 outcome이 없으면 phase로만 안다 -- 정지·안전 정지를 지어내지 않는다.
    if (s.outcome != null) resultWord(kind),
    if (s.route == 'thinq') 'LG 가전',
    if (confirmationLabel(
      route: s.route,
      receipt: s.receipt,
      confirmation: s.confirmation,
      kind: kind,
      executionMode: s.isDemo ? 'mock' : s.executionMode,
      aborted: s.abortReason != null,
    )
        case final c?)
      c,
  ];
}

class _ResultFacts extends StatelessWidget {
  const _ResultFacts({required this.status});

  final ExecutionStatus status;

  @override
  Widget build(BuildContext context) {
    final words = _resultFactWords(status);
    // ThinQ 성공(2026-10-14)은 큰 문장이 서버 문장을 그대로 말한다 — 같은 줄을 두 번 쓰지 않는다.
    final mockRun = status.isDemo || status.executionMode == 'mock';
    final detail = status.route == 'thinq' &&
            thinqOutcomeSentence(status.confirmation, status.detail) != null &&
            !(mockRun && status.confirmation == 'state_confirmed')
        ? null
        : status.detail;
    if (words.isEmpty &&
        (detail == null || detail.isEmpty) &&
        status.operationConfirmed == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (final w in words)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.xs),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: context.appBorderSubtle),
                  ),
                  child: Text(w, style: const TextStyle(fontSize: AppFont.caption)),
                ),
            ],
          ),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text(detail,
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          ],
          _OperationLine(status: status),
        ],
      ),
    );
  }
}

/// 끝난 다단계 실행의 단계 목록. 기록이 그 job의 것이 아니거나 한 단계뿐이면
/// 아무것도 그리지 않는다(한 단계는 위 한 줄이 이미 같은 말을 한다).
class _RunSteps extends ConsumerWidget {
  const _RunSteps({required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = ref.watch(scenarioRunForJobProvider(jobId)).valueOrNull;
    if (run == null || run.jobId != jobId || run.steps.length < 2) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('할 일별 결과', style: AppText.title),
          const SizedBox(height: AppSpace.sm),
          for (var i = 0; i < run.steps.length; i++)
            Builder(builder: (context) {
              final step = run.steps[i];
              final title = '${i + 1}. ${step.summary.isNotEmpty ? step.summary : step.targetId}';
              final facts = runStepFacts(step);
              final detail = step.detail;
              return Semantics(
                label: '$title. $facts',
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: const TextStyle(
                                fontSize: AppFont.body, fontWeight: FontWeight.w600)),
                        const SizedBox(height: AppSpace.xs),
                        Text(facts,
                            style: TextStyle(
                                fontSize: AppFont.caption, color: context.appMuted)),
                        if (detail != null && detail.isNotEmpty)
                          Text(detail,
                              style: TextStyle(
                                  fontSize: AppFont.caption, color: context.appMuted)),
                      ],
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

/// L3(가전 동작) 판정 한 줄. **판정이 없으면(null) 아무 말도 하지 않는다** --
/// 버튼을 누른 것과 가전이 실제로 움직인 것은 다른 사실이고, 판정기가 없는
/// 실행에서 "동작을 확인했다"는 말이 나오면 안 된다.
/// L3 판정 한 문장. 판정이 없으면 null — 말하지 않는다.
/// 실행 환경을 판정보다 먼저 본다 — 모의 실행의 true는 모의 판정일 뿐이다
/// (10/6 Copilot 리뷰 66990be).
///
/// 외부 평가 2026-10-13 M5: 실물 모션이어도 L3 판정의 입력은 따로 모의일 수 있다(RPi4 `L3_MODE=mock`).
/// 그래서 **판정 출처가 real일 때만** 실제 동작을 확인했다고 말한다. mock이면 모의 판정, 출처를 모르면 단정하지 않는다.
String? operationSentence(ExecutionStatus s) => switch (s.operationConfirmed) {
      true when s.isDemo || s.executionMode == 'mock' =>
        '연습이라 실제 가전은 보지 않았어요',
      true when s.operationSource == 'real' => '가전이 전기를 쓰기 시작한 것도 확인했어요',
      true when s.operationSource == 'mock' => '가전 동작은 연습 값으로 봤어요. 실제로 확인한 건 아니에요',
      true => '가전이 움직였는지 몰라요. 집에서 가전을 확인해야 해요',
      false => '가전이 움직였는지 몰라요',
      null => null,
    };

/// 실제 동작을 확인한 판정인가 — 확인 아이콘·색은 이때만(M5).
bool operationVerifiedForReal(ExecutionStatus s) =>
    s.operationConfirmed == true &&
    !s.isDemo &&
    s.executionMode != 'mock' &&
    s.operationSource == 'real';

class _OperationLine extends StatelessWidget {
  const _OperationLine({required this.status});

  final ExecutionStatus status;

  @override
  Widget build(BuildContext context) {
    final confirmed = status.operationConfirmed;
    if (confirmed == null) return const SizedBox.shrink();
    final caption = [
      // 출처(연습·실제)는 위 문장이 이미 말한다(2026-10-17 같은 말 한 번) — 서버 설명만 붙인다.
      if (status.operationDetail case final d? when d.isNotEmpty) d,
    ].join('. ');
    final verified = operationVerifiedForReal(status);
    final color = verified ? context.appSuccess : context.appWarning;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 색으로만 말하지 않는다 -- 모양이 같이 간다.
              Icon(
                verified ? Icons.verified_outlined : Icons.help_outline,
                size: 18,
                color: color,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  operationSentence(status)!,
                  style: TextStyle(
                      fontSize: AppFont.caption, fontWeight: FontWeight.w600, color: color),
                ),
              ),
            ],
          ),
          if (caption.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Text(caption,
                style: TextStyle(fontSize: AppFont.caption, color: context.appMuted)),
          ],
        ],
      ),
    );
  }
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
      // 센서 %는 일반 화면에 내지 않는다(2026-10-17 쉬운 말 규칙 6).
      if (attempt > 1) '$attempt번째 시도',
    ].join('. ');

    switch (s.phase) {
      case ExecutionPhase.idle:
        return const _NowState(
          headline: '실행하면 여기서 진행을 볼 수 있어요.',
          idle: true,
        );
      case ExecutionPhase.waiting:
        return _NowState(headline: s.message ?? '실행하라고 보냈어요');
      case ExecutionPhase.running:
        if (s.currentButton == null) {
          return const _NowState(headline: '하는 중이에요');
        }
        return _NowState(
          button: s.currentButton,
          headline: hasVerification ? '눌렸는지 보는 중' : '누르는 중',
          // 서버가 눌림 판정(누름 센서)을 보내지 않으면 보고 있다고 하지 않는다(10/18 §3-5) — 지금 실물 구성(누름 장치 보고만)은
          // 버튼별 판정 없이 끝에 결과만 알려 온다. 그때는 다음에 무엇이 오는지만 말한다.
          detail: hasVerification ? evidence : '다 누르면 결과를 알려 드려요.',
        );
      case ExecutionPhase.retrying:
        return _NowState(
          button: s.currentButton,
          headline: '자리를 맞춰 다시 누르는 중',
          detail: evidence.isEmpty ? null : evidence,
          tone: _Tone.caution,
          // '재시도'는 실패로 읽힌다. 눌림이 확인되지 않아 자리를 다시
          // 맞추고 누르는 것은 이 제품이 하기로 한 일이다.
          retryNote: '눌렸는지 몰라서 자리를 맞추고 다시 눌러요.',
        );
      case ExecutionPhase.completed:
        // 서버 문장이 없을 때 기본값이 "버튼 조작을 마쳤어요"면, 실행 환경도
        // 확인 근거도 모르는 실행을 확인했다고 말하게 된다. 같은 규칙
        // (finishedMessage)으로 아는 만큼만 말한다.
        return _NowState(
          headline: s.message ??
              finishedMessage(
                kind: ResultKind.success,
                // 모의 실행은 이 job에 새겨져 있다(전역 토글이 아니다).
                executionMode: s.isDemo ? 'mock' : s.executionMode,
                route: s.route,
                receipt: s.receipt,
                confirmation: s.confirmation,
                detail: s.detail,
              ),
          tone: _Tone.done,
        );
      case ExecutionPhase.failed:
        return _NowState(
          headline: s.message ??
              finishedMessage(
                kind: ResultKind.failed,
                // 모의 실행은 이 job에 새겨져 있다(전역 토글이 아니다).
                executionMode: s.isDemo ? 'mock' : s.executionMode,
                route: s.route,
                receipt: s.receipt,
              ),
          tone: _Tone.failed,
        );
      case ExecutionPhase.unknown:
        return _NowState(
          headline: s.message ?? '지금 상태를 몰라요. 집에서 가전을 확인해야 해요.',
          tone: _Tone.caution,
        );
      case ExecutionPhase.unconfirmed:
        // 실패로 말하지 않는다 -- 다시 보내면 중복 실행이 될 수 있다.
        return _NowState(
          headline: s.message ?? unconfirmedSentence(receipt: s.receipt),
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
                padding: const EdgeInsets.only(top: AppSpace.xs),
                child: Icon(icon, size: 24, color: color),
              ),
              const SizedBox(width: AppSpace.sm),
            ],
            Expanded(
              // 어절 단위로 줄을 바꾼다 — 큰 글씨에서 '동/작을'처럼 낱말 가운데서 끊겼다(UI 평가 10/17).
              child: Text(
                keepWordsTogether(now.headline),
                semanticsLabel: now.headline,
                style: now.button != null
                    ? TextStyle(
                        fontSize: AppFont.cardTitle, fontWeight: FontWeight.w600, color: color)
                    : TextStyle(
                        fontSize: now.idle ? AppFont.caption : AppFont.cardTitle,
                        fontWeight:
                            now.idle ? FontWeight.w400 : FontWeight.w600,
                        color: color ?? (now.idle ? context.appMuted : null),
                      ),
              ),
            ),
          ],
        ),
        if (now.detail != null) ...[
          const SizedBox(height: AppSpace.xs),
          Text(now.detail!, style: TextStyle(color: context.appMuted)),
        ],
        if (now.retryNote != null) ...[
          const SizedBox(height: AppSpace.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.refresh, size: 18, color: context.appWarning),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(now.retryNote!,
                    style: TextStyle(fontSize: AppFont.caption, color: context.appWarning)),
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
          const SizedBox(width: AppSpace.sm),
          Flexible(
            child: Text(
              appliance.displayName,
              style: TextStyle(fontSize: AppFont.caption, color: context.appMuted),
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
    // 끝난 칸은 무채색으로 채우고, 지금 칸의 테두리만 강조한다 -- 강조색은
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
        // 이 실행의 조작 진행(서버 total_steps — 버튼 하나 또는 명령 한 묶음). 루틴 목록의
        // "N단계"(루틴 단계 수)와 다른 축이라 다른 말로 부른다. 숫자와 단위는 붙어 다닌다
        // (단어 결합 문자 U+2060, 외부 평가 2026-10-13 L3).
        Text('$total\u2060개 중 $completed\u2060개 했어요', style: AppText.title),
        if (drawSegments) ...[
          const SizedBox(height: AppSpace.md),
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
                if (i < total - 1) const SizedBox(width: AppSpace.xs),
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
          padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
          child: Row(
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(width: AppSpace.lg),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: AppFont.cardTitle,
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
                      const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
                  decoration: BoxDecoration(
                    border: Border.all(color: context.appPrimary, width: 1.5),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '지금',
                    style: TextStyle(
                      fontSize: AppFont.caption,
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
            padding: const EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.lg),
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
                      label: const Text('새로 보기'),
                    ),
                  ),
                  // 정지와 재확인 사이를 띄운다 -- 붙여 두면 급할 때
                  // 옆 것을 누른다.
                  const SizedBox(height: AppSpace.lg),
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
                      '정지',
                      style: TextStyle(fontSize: AppFont.cardTitle, fontWeight: FontWeight.w700),
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
      if (unwrapped.isNotEmpty) unwrapped.add(const SizedBox(height: AppSpace.md));
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
              padding: const EdgeInsets.symmetric(vertical: AppSpace.lg, horizontal: AppSpace.xs),
              child: Row(
                children: [
                  Icon(Icons.show_chart, size: 20, color: context.appMuted),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      // 무엇의 기록인지(UI 평가 3차 10/17 — '센서'는 기술 말이었다).
                      keepWordsTogether('전기와 소리 기록'),
                      style: TextStyle(
                        fontSize: AppFont.caption,
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
          const SizedBox(height: AppSpace.xs),
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
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: context.appMuted, size: 18),
                const SizedBox(width: AppSpace.sm),
                // 확대하면 '전류 (mA)'가 반쪽 카드 폭을 넘는다 -- 줄바꿈할 자리를 준다
                Expanded(child: Text(label, style: context.appCaption)),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Text(displayValue, style: AppText.sensor),
            const SizedBox(height: AppSpace.md),
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
