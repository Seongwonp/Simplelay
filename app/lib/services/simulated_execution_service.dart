import 'rpi_api_service.dart';

/// 실제 명령 전송 없이 실행과 진행 조회만 모의한다.
///
/// 제안·가전·이력·센서 조회와 `stop()`은 실제 서버를 사용한다. 모의 모드 전에
/// 시작된 실제 작업도 정지할 수 있어야 한다.
class SimulatedExecutionService extends RpiApiService {
  SimulatedExecutionService(super.baseUrl, {super.client, super.apiKey});

  static int _counter = 0;

  /// 현재 모의 job. 새 실행이 이전 job의 지연된 진행을 대체한다.
  String? _jobId;
  DateTime? _startedAt;
  List<String> _buttons = const [];

  /// 모의 실행의 단계별 지연.
  static const _perStep = Duration(milliseconds: 900);

  /// 단계 수를 알 수 없는 경로의 진행 표시용 기본 단계.
  static const _unknownSequence = ['1단계', '2단계', '3단계'];

  RpiJobAccepted _begin(List<String> buttons) {
    _counter += 1;
    _jobId = 'demo-$_counter';
    _startedAt = DateTime.now();
    _buttons = buttons;
    return RpiJobAccepted(jobId: _jobId!);
  }

  // 실행: 나가지 않는다

  @override
  Future<RpiJobAccepted> execute(
    String text, {
    String source = 'voice',
    String? applianceId,
    String? clientRequestId,
  }) async =>
      _begin(_unknownSequence);

  @override
  Future<RpiJobAccepted> executeButtons(
    List<String> buttons, {
    String? applianceId,
    String? clientRequestId,
  }) async =>
      _begin(buttons);

  @override
  Future<RpiJobAccepted> executeForAppliance(
    String text,
    List<String> knownButtons, {
    String? applianceId,
    String? clientRequestId,
  }) async =>
      _begin(_unknownSequence);

  @override
  Future<RpiJobAccepted> approveSuggestion(String id, {String? clientRequestId}) async =>
      _begin(_unknownSequence);

  /// 흉내낸 job의 진행. 실제 `/status`에는 이 job이 없으므로 여기서 답해야
  /// 한다 — 그대로 넘기면 추적기가 "내 job의 흔적이 없다"고 판단해 폴링
  /// 10회 뒤 '확인 불가'로 빠진다.
  ///
  /// 모의 실행이 없을 때는 실제 상태를 그대로 넘긴다. 데모를 켜기 전에
  /// 시작한 진짜 작업이 화면에서 사라지면 안 된다.
  @override
  Future<RpiStatusResult> status() async {
    final jobId = _jobId;
    final startedAt = _startedAt;
    if (jobId == null || startedAt == null) return super.status();

    final total = _buttons.isEmpty ? _unknownSequence.length : _buttons.length;
    final elapsed = DateTime.now().difference(startedAt);
    final done =
        (elapsed.inMilliseconds ~/ _perStep.inMilliseconds).clamp(0, total);

    if (done >= total) {
      return RpiStatusResult(
        running: false,
        lastStatus: 'succeeded',
        lastJobId: jobId,
        lastButtons: [
          for (final b in _buttons)
            RpiButtonStep(button: b, success: true),
        ],
      );
    }
    return RpiStatusResult(
      running: true,
      jobId: jobId,
      completedSteps: done,
      totalSteps: total,
      currentButton: _buttons.isEmpty ? null : _buttons[done],
      currentAttempt: 1,
      // 센서 신뢰도는 만들지 않는다. 없는 측정값을 지어내면 리뷰가 안티패턴
      // 으로 지목한 "앱에서 못 받는 데이터를 데모 값으로 보충"이 된다.
      verificationDetail: '연습이라 실제로 누르지 않았어요',
    );
  }

  /// 흉내낸 job은 위 [status]가 답한다. 다른 job(데모를 켜기 전의 진짜 작업)은 실제 본체에 묻는다.
  @override
  Future<RpiStatusResult> jobStatus(String jobId) =>
      jobId == _jobId ? status() : super.jobStatus(jobId);

  /// 모의 실행 정지. 진짜 작업이 함께 돌고 있을 수 있으므로 실제 `/stop`도
  /// 보낸다 — 여기서 아끼면 멈출 수단이 사라진다.
  @override
  Future<StopOutcome> stop() async {
    _jobId = null;
    _startedAt = null;
    return super.stop();
  }
}
