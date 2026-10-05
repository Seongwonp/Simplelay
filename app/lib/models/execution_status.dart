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

  /// 보냈지만 확인하지 못함(ThinQ). 실패도 성공도 아니다 -- 다시 보내라고
  /// 권하지 않고 가전을 직접 확인하라고 한다. 이미 보낸 클라우드 명령은
  /// 취소할 수 없으므로 정지 버튼도 내걸지 않는다.
  unconfirmed,
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
    this.outcome,
    this.route,
    this.receipt,
    this.confirmation,
    this.detail,
    this.retryCount,
    this.operationConfirmed,
    this.operationSource,
    this.operationDetail,
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

  /// 끝난 실행의 서버 결과 축(옛 서버는 null). `models/command_result.dart`가 읽는다.
  /// success | failed | stopped | safety_stop | unconfirmed
  final String? outcome;

  /// physical | thinq
  final String? route;

  /// accepted | unknown | not_dispatched
  final String? receipt;

  /// none | reported | press_confirmed | state_confirmed | operation_confirmed
  final String? confirmation;

  /// 서버가 쓴 한 줄(ThinQ 결과).
  final String? detail;

  /// 끝난 실행의 재시도 합. 버튼별 보고가 없으면 null이다(0이 아니다).
  final int? retryCount;

  /// L3(가전 동작) 판정. **null은 '판정하지 않았다'**이고, false를 true로
  /// 올리지 않는다 -- 확인하지 않은 일을 확인했다고 말하지 않는다.
  final bool? operationConfirmed;

  /// 판정 입력 real | mock. mock의 true는 실제 동작 근거가 아니다.
  final String? operationSource;
  final String? operationDetail;
  final String executionMode;
  String get modeLabel => isDemo || executionMode == 'mock'
      ? '모의 실행 — 실제 조작이 아닙니다'
      : executionMode == 'real' ? '실제 장치로 실행' : '실행 환경 미확인';

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
    String? outcome,
    String? route,
    String? receipt,
    String? confirmation,
    String? detail,
    int? retryCount,
    bool? operationConfirmed,
    String? operationSource,
    String? operationDetail,
  }) =>
      ExecutionStatus(
        executionMode: executionMode ?? this.executionMode,
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
        applianceId: applianceId ?? this.applianceId,
        outcome: outcome ?? this.outcome,
        route: route ?? this.route,
        receipt: receipt ?? this.receipt,
        confirmation: confirmation ?? this.confirmation,
        detail: detail ?? this.detail,
        retryCount: retryCount ?? this.retryCount,
        operationConfirmed: operationConfirmed ?? this.operationConfirmed,
        operationSource: operationSource ?? this.operationSource,
        operationDetail: operationDetail ?? this.operationDetail,
        phase: phase ?? this.phase,
        message: message ?? this.message,
        // 실행 모드는 시작할 때 정해지고 그 job이 끝날 때까지 바뀌지
        // 않는다 -- copyWith로 뒤집을 수 있으면 새길 이유가 없다.
        isDemo: isDemo,
      );
}
