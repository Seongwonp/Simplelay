/// GET /scenarios/last-run — 마지막 명령 실행(단일 명령 또는 시나리오)의 단계별 결과.
///
/// `/status`는 **마지막 단계**만 말한다. 두 가전을 잇는 시나리오에서 첫 단계의
/// 경로·확인 수준을 보이려면 이 기록을 읽는다(시연 gap G4). 화면은 이 기록이
/// **방금 끝난 그 job의 것**일 때만 쓴다 -- 다른 실행의 단계를 내 결과처럼
/// 보이면 안 된다. 키오스크(`rpi5-touchscreen-app/lib/models/scenario_run.dart`)와
/// 같은 모양이다.
library;

import 'command_result.dart';

class ScenarioRunStep {
  const ScenarioRunStep({
    required this.targetId,
    required this.route,
    this.action,
    this.summary = '',
    required this.status,
    this.receipt,
    this.confirmation,
    this.executionMode = 'unknown',
    this.detail,
  });

  final String targetId;

  /// physical | thinq
  final String route;
  final String? action;

  /// 서버가 고정한 사람이 읽을 한 줄(가전·동작).
  final String summary;

  /// succeeded | failed | stopped | unconfirmed
  final String status;

  /// accepted | unknown | not_dispatched
  final String? receipt;

  /// none | reported | press_confirmed | state_confirmed | operation_confirmed
  final String? confirmation;

  /// real | mock | unknown
  final String executionMode;
  final String? detail;

  factory ScenarioRunStep.fromJson(Map<String, dynamic> json) =>
      ScenarioRunStep(
        targetId: json['target_id'] as String? ?? '',
        route: json['route'] as String? ?? '',
        action: json['action'] as String?,
        summary: json['summary'] as String? ?? '',
        status: json['status'] as String? ?? '',
        receipt: json['receipt'] as String?,
        confirmation: json['confirmation'] as String?,
        executionMode: json['execution_mode'] as String? ?? 'unknown',
        detail: json['detail'] as String?,
      );
}

/// 단계 하나의 사실 한 줄: 경로 · 실행 환경 · 확인 수준 · 결과.
///
/// 확인 수준은 한 줄 요약과 **같은 규칙**(`confirmationLabel`)으로 말한다 --
/// 서버가 확인하지 못한 단계를 여기서 확인됨으로 올리지 않는다.
String runStepFacts(ScenarioRunStep step) {
  final kind = resultKindOf(status: step.status);
  final confirmation = confirmationLabel(
    route: step.route,
    receipt: step.receipt,
    confirmation: step.confirmation,
    kind: kind,
    executionMode: step.executionMode,
  );
  final saysMock = confirmation != null &&
      (confirmation.contains('연습') || confirmation.contains('모의'));
  return [
    // 물리 경로는 칩이 없다(routeLabel null) — 경로 코드를 그대로 내지 않는다.
    if (routeLabel(step.route) case final r?) r,
    // 실제 실행은 따로 말하지 않는다(평소 상태). 연습은 한 번만, 모름은 그대로.
    if (step.executionMode == 'mock' && !saysMock)
      '연습'
    // 단계 결과(실행 상태·기록 상세)에서는 모르면 모른다고 남긴다 — 실제 성공처럼 보이지 않게(F4, 2026-10-14).
    else if (step.executionMode != 'real' && step.executionMode != 'mock')
      '실제 가전이 움직였는지 몰라요',
    if (confirmation != null) confirmation,
    // 확인 못 함은 위 확인 수준이 이미 '몰라요'라고 한다 — 같은 말을 두 번 쓰지 않는다(2026-10-17).
    if (!(kind == ResultKind.unconfirmed && confirmation != null)) resultWord(kind),
  ].join(', ');
}

class ScenarioRun {
  const ScenarioRun({
    required this.jobId,
    this.scenarioId,
    required this.status,
    required this.steps,
  });

  final String jobId;
  final String? scenarioId;
  final String status;
  final List<ScenarioRunStep> steps;

  /// `{"run": {...}}` 응답 전체를 받는다. 기록이 없으면(`run: null`) null.
  static ScenarioRun? fromLastRunJson(Map<String, dynamic> json) {
    final run = json['run'];
    if (run is! Map<String, dynamic>) return null;
    final jobId = run['job_id'];
    if (jobId is! String) return null;
    return ScenarioRun(
      jobId: jobId,
      scenarioId: run['scenario_id'] as String?,
      status: run['status'] as String? ?? '',
      steps: [
        for (final s in (run['steps'] as List<dynamic>? ?? const []))
          if (s is Map<String, dynamic>) ScenarioRunStep.fromJson(s),
      ],
    );
  }
}
