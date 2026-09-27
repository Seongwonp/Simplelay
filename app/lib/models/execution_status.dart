/// unknown: 통신이 끊겨 **동작 여부를 알 수 없는** 상태.
/// 실패와 구분해야 한다 -- 통신 실패는 물리 동작의 종료를 뜻하지 않는다.
/// 가전이 계속 움직이고 있을 수 있으므로 정지 수단을 남겨야 하는 단계.
enum ExecutionPhase {
  idle,
  waiting,
  running,
  retrying,
  completed,
  failed,
  unknown,
}

class ExecutionStatus {
  const ExecutionStatus({
    this.executionMode = 'unknown',
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
    this.isDemo = false,
    this.applianceId,
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

  /// 이 실행이 **대상으로 삼은** 가전. 서버가 말해준 값이다.
  ///
  /// 화면은 이걸로 버튼 이름을 읽는다. 지금 고른 가전으로 읽으면, 실행
  /// 중에 다른 가전을 고른 순간 화면이 틀린 버튼 이름을 말한다.
  final String? applianceId;

  /// 이 실행이 **모의**였는가. 실행을 시작한 순간에 확정한다.
  ///
  /// 전역 데모 토글을 그때그때 읽으면, 진행 중에 토글을 건드린 것만으로
  /// 이미 시작한 작업의 표시가 뒤집힌다 -- 실제로 움직이고 있는 작업이
  /// "실제 조작이 아닙니다"가 되거나 그 반대가 된다.
  final bool isDemo;
  final String executionMode;
  String get modeLabel => isDemo || executionMode == 'mock'
      ? '모의 실행 — 실제 조작이 아닙니다'
      : executionMode == 'real' ? '실기기 실행' : '실행 환경 미확인';

  ExecutionStatus copyWith({
    String? executionMode,
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
    String? applianceId,
  }) =>
      ExecutionStatus(
        executionMode: executionMode ?? this.executionMode,        sequenceId: sequenceId ?? this.sequenceId,
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
        applianceId: applianceId ?? this.applianceId,
        phase: phase ?? this.phase,
        message: message ?? this.message,
        // 실행 모드는 시작할 때 정해지고 그 job이 끝날 때까지 바뀌지
        // 않는다 -- copyWith로 뒤집을 수 있으면 새길 이유가 없다.
        isDemo: isDemo,
      );
}
