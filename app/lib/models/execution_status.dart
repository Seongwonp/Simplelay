enum ExecutionPhase { idle, waiting, running, retrying, completed, failed }

class ExecutionStatus {
  const ExecutionStatus({
    this.sequenceId,
    this.label,
    this.steps = const [],
    this.completedSteps = 0,
    this.currentButton,
    this.totalSteps,
    this.currentAttempt,
    this.verificationConfidence,
    this.verificationDetail,
    this.currentMa,
    this.soundDb,
    this.phase = ExecutionPhase.idle,
    this.message,
  });

  final String? sequenceId;
  final String? label;
  final List<String> steps;
  final int completedSteps;

  // 서버가 주는 실시간 폐루프 증거. 음성 실행처럼 steps 미리보기가
  // 없는 경로에서도 진행을 보여줄 수 있도록 totalSteps를 따로 둔다.
  final String? currentButton;
  final int? totalSteps;
  final int? currentAttempt;
  final double? verificationConfidence;
  final String? verificationDetail;
  final double? currentMa;
  final double? soundDb;
  final ExecutionPhase phase;
  final String? message;

  ExecutionStatus copyWith({
    String? sequenceId,
    String? label,
    List<String>? steps,
    int? completedSteps,
    String? currentButton,
    int? totalSteps,
    int? currentAttempt,
    double? verificationConfidence,
    String? verificationDetail,
    double? currentMa,
    double? soundDb,
    ExecutionPhase? phase,
    String? message,
  }) =>
      ExecutionStatus(
        sequenceId: sequenceId ?? this.sequenceId,
        label: label ?? this.label,
        steps: steps ?? this.steps,
        completedSteps: completedSteps ?? this.completedSteps,
        currentButton: currentButton ?? this.currentButton,
        totalSteps: totalSteps ?? this.totalSteps,
        currentAttempt: currentAttempt ?? this.currentAttempt,
        verificationConfidence:
            verificationConfidence ?? this.verificationConfidence,
        verificationDetail: verificationDetail ?? this.verificationDetail,
        currentMa: currentMa ?? this.currentMa,
        soundDb: soundDb ?? this.soundDb,
        phase: phase ?? this.phase,
        message: message ?? this.message,
      );
}
