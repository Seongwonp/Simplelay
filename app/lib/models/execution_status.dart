enum ExecutionPhase { idle, waiting, running, retrying, completed, failed }

class ExecutionStatus {
  const ExecutionStatus({
    this.sequenceId,
    this.label,
    this.steps = const [],
    this.completedSteps = 0,
    this.currentMa,
    this.soundDb,
    this.phase = ExecutionPhase.idle,
    this.message,
  });

  final String? sequenceId;
  final String? label;
  final List<String> steps;
  final int completedSteps;
  final double? currentMa;
  final double? soundDb;
  final ExecutionPhase phase;
  final String? message;

  ExecutionStatus copyWith({
    String? sequenceId,
    String? label,
    List<String>? steps,
    int? completedSteps,
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
        currentMa: currentMa ?? this.currentMa,
        soundDb: soundDb ?? this.soundDb,
        phase: phase ?? this.phase,
        message: message ?? this.message,
      );
}
