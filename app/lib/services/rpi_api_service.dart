import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/appliance.dart';
import '../models/auto_rule.dart';
import '../models/estop.dart';
import '../models/hub.dart';
import '../models/learning_status.dart';
import '../models/quiet_hours.dart';
import '../models/routine.dart';
import '../models/routine_candidate.dart';
import '../models/scenario_run.dart';

class RpiApiException implements Exception {
  RpiApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

  /// 제안 승인 재검사 실패(409) — 승인한 대상·경로·동작·인자가 바뀌었거나 승인이
  /// 만료·무효가 됐다. 서버는 이 카드를 내리므로 다시 확인해야 한다. 같은 409인
  /// '다른 작업 실행 중'(`an execution is already in progress`)과 구분한다 —
  /// 서버의 승인 오류 문장은 모두 '승인'을 담는다(`rpi/commands/approval.py`).
  bool get isApprovalChanged => statusCode == 409 && message.contains('승인');

  @override
  String toString() => 'RpiApiException($statusCode): $message';
}

class RpiButtonStep {
  const RpiButtonStep({required this.button, required this.success});
  final String button;
  final bool success;

  factory RpiButtonStep.fromJson(Map<String, dynamic> json) => RpiButtonStep(
        button: json['button'] as String,
        success: json['success'] as bool,
      );
}

class RpiExecuteResult {
  const RpiExecuteResult({required this.status, required this.buttons});
  final String status;
  final List<RpiButtonStep> buttons;
}

// 실행 접수 응답(비동기 job 모델). 서버는 물리 실행을 기다리지 않고 즉시
// job_id를 돌려주며, 진행·완료는 status() 폴링에서 lastJobId와 대조해 판정한다.
class RpiJobAccepted {
  const RpiJobAccepted(
      {required this.jobId, this.autoAllowFailure, this.status = 'accepted', this.stop});
  final String jobId;

  /// '다음부터 자동으로'(approve-and-allow)에서 이번 실행은 제출됐지만 자동 허용은 저장되지 않았을 때 서버 문장
  /// (`auto_allow: {ok: false, reason}`, 3차 평가 H2 — 허용 저장 사이 전체 정지). 그 밖에는 null.
  final String? autoAllowFailure;

  /// 서버가 알린 접수 상태. `stopped`면 서버가 발화를 정지어로 받아 실행 대신 정지를 했다(안전 보고 G7, 2026-10-16) —
  /// 이때 [jobId]는 멈춘 실행의 job이거나 빈 문자열이라 **따라갈 새 실행이 없다**. 옛 서버는 늘 `accepted`.
  final String status;

  /// `stopped`일 때 서버의 정지 결과(`POST /stop` 응답과 같은 모양). 그 밖에는 null.
  final StopOutcome? stop;

  bool get stopped => status == 'stopped';

  factory RpiJobAccepted.fromJson(Map<String, dynamic> json) {
    final allow = json['auto_allow'];
    String? failure;
    if (allow is Map<String, dynamic> && allow['ok'] == false) {
      final reason = allow['reason'];
      failure = reason is String && reason.isNotEmpty ? reason : '다음부터 자동 실행은 켜지 않았어요';
    }
    final status = json['status'];
    final stop = json['stop'];
    return RpiJobAccepted(
      jobId: json['job_id'] as String,
      autoAllowFailure: failure,
      status: status is String ? status : 'accepted',
      stop: stop is Map<String, dynamic> ? StopOutcome.fromJson(stop) : null,
    );
  }
}

/// POST /stop 응답의 정지 확인 단계(2026-10-13). 옛 서버·보고 수단이 없으면 [stopLevel]이 null.
class StopOutcome {
  const StopOutcome(
      {this.stopLevel,
      this.ackMs,
      this.confirmed = false,
      this.jobId,
      this.reportsJobId = false,
      this.wasRunning = false});

  factory StopOutcome.fromJson(Map<String, dynamic> json) {
    final level = json['stop_level'];
    return StopOutcome(
      stopLevel: level is String ? level : null,
      ackMs: (json['stop_ack_ms'] as num?)?.toInt(),
      confirmed: json['stop_confirmed'] == true,
      jobId: json['stop_job_id'] is String ? json['stop_job_id'] as String : null,
      reportsJobId: json.containsKey('stop_job_id'),
      wasRunning: json['was_running'] == true,
    );
  }

  /// 요청 순간 서버에 실행 중인 작업이 있었나(`was_running`). 모르면(옛 응답) 거짓.
  final bool wasRunning;

  /// 이 정지가 멈춘 실행의 job_id(평가 2026-10-13 H1). 옛 서버·실행 중이 아니었으면 null.
  final String? jobId;

  /// 응답에 `stop_job_id` 필드가 있었는지(2차 평가 M-N1). 거짓이면 이 필드를 모르는 옛 서버다 —
  /// 새 서버의 명시적 null(실행 중이 아니던 정지)과 구별한다.
  final bool reportsJobId;

  /// 이 정지 단계를 [jobId] 실행의 것으로 볼 수 있는지. 새 서버는 같은 job을 멈췄다고 밝힐 때만,
  /// 필드가 없는 옛 서버만 종전처럼(호환 — 출처를 증명하지는 못한다).
  bool belongsTo(String? jobId) =>
      !reportsJobId || (this.jobId != null && this.jobId == jobId);

  /// sent | mcu_ack | verified | null
  final String? stopLevel;
  final int? ackMs;

  /// mcu_ack 이상일 때만 true.
  final bool confirmed;
}

class RpiStatusResult {
  final String executionMode;
  final String lastExecutionMode;
  const RpiStatusResult({
    this.executionMode = 'unknown',
    this.lastExecutionMode = 'unknown',
    required this.running,
    this.lastStatus,
    this.lastButtons,
    this.currentButton,
    this.currentAttempt,
    this.completedSteps,
    this.totalSteps,
    this.verificationConfidence,
    this.verificationDetail,
    this.jobId,
    this.lastJobId,
    this.applianceId,
    this.lastApplianceId,
    this.lastOutcome,
    this.route,
    this.lastRoute,
    this.lastReceipt,
    this.lastConfirmation,
    this.lastDetail,
    this.lastRetryCount,
    this.lastOperationConfirmed,
    this.lastOperationSource,
    this.lastOperationDetail,
    this.lastAbortReason,
    this.estopLatched = false,
    this.estopDetail,
    this.lastStopLevel,
    this.lastStopAckMs,
    this.lastStopJobId,
    this.reportsStopJobId = false,
  });
  final bool running;

  /// 마지막 긴급 정지의 확인 단계(2026-10-13): sent | mcu_ack | verified. 옛 서버·보고 없음은 null.
  final String? lastStopLevel;
  final int? lastStopAckMs;

  /// 그 정지가 멈춘 실행의 job_id(H1). [reportsStopJobId]가 거짓이면 이 필드를 모르는 옛 서버다.
  final String? lastStopJobId;
  final bool reportsStopJobId;

  /// [jobId] 실행의 정지 확인 단계만(H1). 서버가 정지의 실행을 밝히면 같은 job일 때만, 옛 서버면 종전처럼.
  String? stopLevelOf(String jobId) => !reportsStopJobId || lastStopJobId == jobId
      ? lastStopLevel
      : null;
  int? stopAckMsOf(String jobId) =>
      stopLevelOf(jobId) == null ? null : lastStopAckMs;

  /// 콘센트 모듈 비상정지 걸림(2026-10-05). 없거나 null이면 거짓.
  final bool estopLatched;
  final String? estopDetail;
  final String? lastStatus;

  /// success | failed | stopped | safety_stop | unconfirmed. 옛 서버는 null —
  /// 그때는 [lastStatus]로 판정한다(`resultKindOf`).
  final String? lastOutcome;

  /// 제어 경로 physical | thinq (실행 중 / 마지막). 옛 서버는 null.
  final String? route;
  final String? lastRoute;

  /// 상대가 받았나: accepted | unknown | not_dispatched.
  final String? lastReceipt;

  /// 확인 근거: none | reported | press_confirmed | state_confirmed | operation_confirmed.
  final String? lastConfirmation;

  /// 서버가 쓴 사람이 읽을 한 줄(ThinQ 결과).
  final String? lastDetail;

  /// 마지막 물리 실행의 재시도 합(버튼별 시도 수 - 1). 버튼별 보고가 없으면
  /// null이다 -- **0으로 지어내지 않는다**(2026-09-29 G1).
  final int? lastRetryCount;

  /// L3(가전 동작) 판정. 판정기가 없거나 판정하지 못했으면 null(G2).
  final bool? lastOperationConfirmed;

  /// 판정 입력 real | mock. mock의 true는 실제 동작 근거가 아니다.
  final String? lastOperationSource;
  final String? lastOperationDetail;

  /// 모션 걸림·재시작·기한 초과·준비 안 됨으로 재시도 없이 멈춘 원인(서버 2026-10-14, 예: `motion_alarm: stall`).
  /// 눌림 확인 실패와 가르는 근거다. 옛 서버·그 밖의 결과는 null.
  final String? lastAbortReason;
  final List<RpiButtonStep>? lastButtons;
  // 실행 중 실시간 진행 (running=true일 때만 값이 있을 수 있음)
  final String? currentButton;
  final int? currentAttempt;
  final int? completedSteps;
  final int? totalSteps;
  // 폐루프 검증 근거 -- 버튼이 눌렸는지 센서로 확인한 결과.
  // 이 제품의 차별점이라 화면까지 도달해야 한다.
  final double? verificationConfidence;
  final String? verificationDetail;
  // job 모델: 실행 중이면 jobId, 끝나면 lastJobId에 값이 있다
  final String? jobId;
  final String? lastJobId;

  /// 이 실행이 **대상으로 삼은** 가전. jobId와 같은 규칙으로 옮겨간다.
  ///
  /// 화면이 지금 고른 가전으로 메우지 않게 하려고 서버가 말해준다 --
  /// 실행 중에 다른 가전을 골라도 진행 중인 작업의 대상은 바뀌지 않는다.
  final String? applianceId;
  final String? lastApplianceId;
}

class RpiSuggestion {
  const RpiSuggestion({
    this.isDemo = false,
    required this.id,
    required this.purpose,
    required this.timeBand,
    required this.occurrences,
    this.steps = const [],
    this.reason = '',
    this.applianceId,
    this.scenarioId,
    this.commands = const [],
    this.routineId,
    this.routineName,
    this.autoRuleOffer,
  });
  final bool isDemo;
  final String id;
  final String purpose;

  /// '다음부터도 자동으로'를 고를 수 있는 카드면 그 내용(서버 2026-10-13). 없으면 버튼이 없다.
  final AutoRuleOffer? autoRuleOffer;

  /// 루틴이 만든 카드면 그 루틴(서버 2026-09-30). 있으면 화면은 `purpose`
  /// 대신 `routineName`을 제목으로 쓴다.
  final String? routineId;
  final String? routineName;
  final String timeBand;
  final int occurrences;

  /// 시나리오 제안이면 그 ID. 옛 서버·일반 제안은 null.
  final String? scenarioId;

  /// 승인에 **고정되는** 명령들(대상·경로·동작). 비었으면 종전 물리 제안.
  final List<RpiSuggestionCommand> commands;

  // 환경 기반 제안 등의 "왜 지금" 근거(예: "지금 30°C · 습도 72% — 더워요").
  final String reason;

  /// 이 제안이 조작할 가전. 서버가 모르면 null -- 그때만 현재 선택 가전을 쓴다.
  final String? applianceId;

  // 승인 시 실행될 버튼 시퀀스 미리보기(라벨 문자열). 해석 실패 시 서버가 빈 리스트를 준다.
  final List<String> steps;

  factory RpiSuggestion.fromJson(Map<String, dynamic> json) => RpiSuggestion(
        isDemo: json['is_demo'] == true || json['time_band'] == '데모',
        id: json['id'] as String,
        purpose: json['purpose'] as String,
        timeBand: json['time_band'] as String,
        occurrences: json['occurrences'] as int,
        steps: (json['steps'] as List<dynamic>?)?.cast<String>() ?? const [],
        reason: json['reason'] as String? ?? '',
        applianceId: json['appliance_id'] as String?,
        scenarioId: json['scenario_id'] as String?,
        commands: [
          for (final c in (json['commands'] as List<dynamic>?) ?? const [])
            if (c is Map<String, dynamic>) RpiSuggestionCommand.fromJson(c),
        ],
        routineId: json['routine_id'] as String?,
        routineName: json['routine_name'] as String?,
        autoRuleOffer: AutoRuleOffer.fromJson(json['auto_rule_offer']),
      );
}

/// 시나리오 카드의 확정 명령 하나 — 서버 `commands[]` 항목.
class RpiSuggestionCommand {
  const RpiSuggestionCommand({
    required this.targetId,
    required this.route,
    this.action,
    this.buttons = const [],
    this.summary = '',
  });

  final String targetId;

  /// physical | thinq
  final String route;
  final String? action;
  final List<String> buttons;

  /// 서버가 만든 사람이 읽을 한 줄(예: "공기청정기 풍량 강풍"). 승인에 묶이는 문장.
  final String summary;

  factory RpiSuggestionCommand.fromJson(Map<String, dynamic> json) =>
      RpiSuggestionCommand(
        targetId: json['target_id'] as String? ?? '',
        route: json['route'] as String? ?? 'physical',
        action: json['action'] as String?,
        buttons: (json['buttons'] as List<dynamic>?)?.cast<String>() ?? const [],
        summary: json['summary'] as String? ?? '',
      );
}

/// GET /readiness/{id} — 경로별 준비 상태(물리 4축 / ThinQ 모드·연결·기기·온라인).
class RpiReadiness {
  const RpiReadiness({
    required this.applianceId,
    required this.route,
    required this.state,
    required this.canExecute,
    this.reasons = const [],
  });

  final String applianceId;
  final String route;
  final String state;
  final bool canExecute;
  final List<String> reasons;

  factory RpiReadiness.fromJson(Map<String, dynamic> json) => RpiReadiness(
        applianceId: json['appliance_id'] as String? ?? '',
        route: json['route'] as String? ?? 'physical',
        state: json['state'] as String? ?? 'unknown',
        canExecute: json['can_execute'] as bool? ?? false,
        reasons: (json['reasons'] as List<dynamic>?)?.cast<String>() ?? const [],
      );
}

/// GET /thinq/devices의 등록 가전 하나(서버 구성, 폰에서 편집하지 않는다).
class RpiThinqAppliance {
  const RpiThinqAppliance({
    required this.applianceId,
    required this.name,
    required this.state,
    required this.canExecute,
    this.reasons = const [],
    this.readOnly = false,
  });

  final String applianceId;
  final String name;
  final String state;
  final bool canExecute;
  final List<String> reasons;
  final bool readOnly;

  factory RpiThinqAppliance.fromJson(Map<String, dynamic> json) =>
      RpiThinqAppliance(
        applianceId: json['appliance_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        state: json['readiness'] as String? ?? 'unknown',
        canExecute: json['can_execute'] as bool? ?? false,
        reasons: (json['readiness_reasons'] as List<dynamic>?)?.cast<String>() ??
            const [],
        readOnly: json['read_only'] as bool? ?? false,
      );
}

/// GET /thinq/devices 요약. 서버가 ThinQ를 끈 상태(404)면 조회 결과가 null이다.
class RpiThinqOverview {
  const RpiThinqOverview({
    required this.mode,
    required this.executionMode,
    this.appliances = const [],
  });

  /// off | mock | real
  final String mode;

  /// mock | real | unknown — mock이면 화면이 '모의'로 표시한다.
  final String executionMode;
  final List<RpiThinqAppliance> appliances;

  factory RpiThinqOverview.fromJson(Map<String, dynamic> json) =>
      RpiThinqOverview(
        mode: json['mode'] as String? ?? 'unknown',
        executionMode: json['execution_mode'] as String? ?? 'unknown',
        appliances: [
          for (final a in (json['appliances'] as List<dynamic>?) ?? const [])
            if (a is Map<String, dynamic>) RpiThinqAppliance.fromJson(a),
        ],
      );
}

/// GET /thinq/status/{id} — ThinQ가 지금 알려 준 가전 상태(2026-10-15).
///
/// **읽기 전용이다.** 실패면 [failure]에 이유가 있고 [state]는 비어 있다 —
/// 못 읽은 것을 '꺼짐'이나 빈 값으로 보이지 않게 한다. [readAt]은 폰이 응답을 받은 시각이다.
class RpiThinqStatus {
  const RpiThinqStatus({
    this.executionMode = 'unknown',
    this.state = const {},
    this.failure,
    this.readAt,
  });

  const RpiThinqStatus.failed(String reason) : this(failure: reason);

  /// mock | real | unknown — mock이면 화면이 '모의'로 표시한다.
  final String executionMode;
  final Map<String, dynamic> state;
  final String? failure;
  final DateTime? readAt;

  bool get ok => failure == null;
}

/// GET /thinq/discovered의 기기 하나 — ThinQ 계정에서 찾은 가전(2026-10-13).
///
/// 기기 ID 원문 대신 서버가 준 [key]로 추가·제거한다.
class RpiThinqFound {
  const RpiThinqFound({
    required this.key,
    required this.kindLabel,
    this.alias = '',
    this.modelName = '',
    required this.support,
    this.supportReason = '',
    this.added = false,
    this.source,
    this.applianceId,
    this.name,
    this.canAdd = false,
    this.reason,
  });

  final String key;
  final String kindLabel;
  final String alias;
  final String modelName;

  /// controllable | status_only | unsupported | unknown
  final String support;
  final String supportReason;
  final bool added;

  /// added(사용자가 추가) | config(서버 설정) — 추가됐을 때만.
  final String? source;
  final String? applianceId;
  final String? name;
  final bool canAdd;

  /// 추가할 수 없는 이유(지원 안 함·상태만·같은 종류가 이미 있음).
  final String? reason;

  String get title => alias.isNotEmpty ? alias : kindLabel;

  factory RpiThinqFound.fromJson(Map<String, dynamic> json) => RpiThinqFound(
        key: json['key'] as String? ?? '',
        kindLabel: json['kind_label'] as String? ?? '가전',
        alias: json['alias'] as String? ?? '',
        modelName: json['model_name'] as String? ?? '',
        support: json['support'] as String? ?? 'unknown',
        supportReason: json['support_reason'] as String? ?? '',
        added: json['added'] as bool? ?? false,
        source: json['source'] as String?,
        applianceId: json['appliance_id'] as String?,
        name: json['name'] as String?,
        canAdd: json['can_add'] as bool? ?? false,
        reason: json['reason'] as String?,
      );
}

/// GET /thinq/discovered 결과. **조회 실패와 0대를 섞지 않는다** — 실패면
/// [failure]에 사람 말 이유가 있고 [devices]는 의미가 없다.
class RpiThinqDiscovery {
  const RpiThinqDiscovery({
    this.mode = 'unknown',
    this.executionMode = 'unknown',
    this.mockCloud = false,
    this.devices = const [],
    this.failure,
    this.off = false,
  });

  const RpiThinqDiscovery.failed(String reason, {bool off = false})
      : this(failure: reason, off: off);

  final String mode;
  final String executionMode;
  final bool mockCloud;
  final List<RpiThinqFound> devices;
  final String? failure;

  /// 허브에서 ThinQ 연동이 꺼져 있다(404).
  final bool off;

  bool get ok => failure == null;

  factory RpiThinqDiscovery.fromJson(Map<String, dynamic> json) {
    final mode = json['mode'] as String? ?? 'unknown';
    final executionMode = json['execution_mode'] as String? ?? 'unknown';
    final mockCloud = json['mock_cloud'] as bool? ?? false;
    if (json['reachable'] == false) {
      return RpiThinqDiscovery(
        mode: mode,
        executionMode: executionMode,
        mockCloud: mockCloud,
        failure: (json['error'] as String?)?.isNotEmpty == true
            ? json['error'] as String
            : 'ThinQ 계정 목록을 불러오지 못했어요.',
      );
    }
    return RpiThinqDiscovery(
      mode: mode,
      executionMode: executionMode,
      mockCloud: mockCloud,
      devices: [
        for (final d in (json['devices'] as List<dynamic>?) ?? const [])
          if (d is Map<String, dynamic>) RpiThinqFound.fromJson(d),
      ],
    );
  }
}

class RpiHistoryButton {
  const RpiHistoryButton({
    required this.button,
    required this.success,
    required this.attempts,
  });
  final String button;
  final bool success;
  final int attempts;

  factory RpiHistoryButton.fromJson(Map<String, dynamic> json) =>
      RpiHistoryButton(
        button: json['button'] as String,
        success: json['success'] as bool,
        attempts: (json['attempts'] as num).toInt(),
      );
}

// 실행 이력 1건 — retryCount > 0이면 폐루프가 실제로 재시도로 회복했다는
// 기록(타임라인에서 배지로 강조하는 핵심 데이터).
/// 보호자 알림 한 건 — 실패·위험소리·긴급정지·안부 신호.
/// message는 서버가 사용자 언어로 완성해 보낸다.
class RpiCareEvent {
  const RpiCareEvent({
    required this.id,
    required this.kind,
    required this.message,
    required this.occurredAt,
    this.purpose,
  });
  final int id;
  final String kind; // execution_failed | emergency_stop | danger_sound | quiet_routine
  final String message;
  final String? purpose;
  final DateTime occurredAt;

  factory RpiCareEvent.fromJson(Map<String, dynamic> json) => RpiCareEvent(
        id: json['id'] as int,
        kind: json['kind'] as String,
        message: json['message'] as String,
        purpose: json['purpose'] as String?,
        occurredAt: DateTime.parse(json['occurred_at'] as String).toLocal(),
      );
}

class RpiHistoryEntry {
  final String executionMode;
  const RpiHistoryEntry({
    this.executionMode = 'unknown',
    required this.jobId,
    required this.finishedAt,
    required this.status,
    required this.retryCount,
    required this.buttons,
    this.purpose,
    this.applianceId,
    this.termination = 'unknown',
    this.outcome,
    this.route = 'unknown',
    this.receipt = 'unknown',
    this.confirmation = 'unknown',
    this.detail = '',
    this.abortReason,
  });
  final String jobId;
  final DateTime finishedAt;
  final String? purpose; // 버튼 직접 실행(수동 조작)은 null
  final String status; // succeeded | safety_stopped | failed
  final int retryCount;
  final List<RpiHistoryButton> buttons;

  /// 어느 가전을 눌렀는가. 이 열이 생기기 전 기록은 null이다.
  final String? applianceId;

  /// completed | stopped_by_user | retries_exhausted | unknown.
  /// status만으로는 '사용자가 멈춤'과 '재시도 소진'이 뭉개진다.
  final String termination;

  /// success | failed | stopped | safety_stop | unconfirmed. 옛 서버는 null.
  final String? outcome;

  /// physical | thinq | unknown(옛 기록).
  final String route;
  final String receipt;
  final String confirmation;
  final String detail;

  /// 모션 중단 원인(서버 2026-10-14, 예: `motion_alarm: stall`). 옛 서버·그 밖은 null.
  final String? abortReason;

  /// 목록 표시용 제목 — 목적이 없으면 누른 버튼 라벨을 나열
  String get displayTitle =>
      purpose ?? buttons.map((b) => b.button).join(' · ');

  factory RpiHistoryEntry.fromJson(Map<String, dynamic> json) =>
      RpiHistoryEntry(
        executionMode: json['execution_mode'] as String? ?? 'unknown',        jobId: json['job_id'] as String,
        finishedAt: DateTime.parse(json['finished_at'] as String).toLocal(),
        purpose: json['purpose'] as String?,
        status: json['status'] as String,
        retryCount: (json['retry_count'] as num).toInt(),
        buttons: (json['buttons'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(RpiHistoryButton.fromJson)
            .toList(),
        applianceId: json['appliance_id'] as String?,
        termination: json['termination'] as String? ?? 'unknown',
        outcome: json['outcome'] as String?,
        route: json['route'] as String? ?? 'unknown',
        receipt: json['receipt'] as String? ?? 'unknown',
        confirmation: json['confirmation'] as String? ?? 'unknown',
        detail: json['detail'] as String? ?? '',
        abortReason: json['abort_reason'] as String?,
      );
}

class SensorReading {
  final bool mocked;
  const SensorReading({this.temperature, this.humidity, this.mocked = true});
  final double? temperature;
  final double? humidity;

  factory SensorReading.fromJson(Map<String, dynamic> json) => SensorReading(
        mocked: json['mocked'] != false,
        temperature: (json['temperature'] as num?)?.toDouble(),
        humidity: (json['humidity'] as num?)?.toDouble(),
      );
}

class RpiHealthData {
  const RpiHealthData({
    required this.ok,
    required this.actuatorReady,
    this.dndUntil,
    this.dndScope,
  });
  final bool ok;
  final bool actuatorReady;
  final DateTime? dndUntil;

  /// 잠시 쉬기 범위(2026-10-14 마감 2번) — `suggestions_and_auto`(새 제안+자동 실행)·`suggestions_only`(업데이트 전
  /// 설정을 이어받음, 새 제안만)·null.
  final String? dndScope;

  factory RpiHealthData.fromJson(Map<String, dynamic> json) => RpiHealthData(
        ok: json['ok'] as bool? ?? false,
        actuatorReady: json['actuator_ready'] as bool? ?? false,
        dndUntil: json['dnd_until'] == null
            ? null
            : DateTime.tryParse(json['dnd_until'] as String),
        dndScope: json['dnd_scope'] as String?,
      );
}

class RpiNodeInfo {
  const RpiNodeInfo({required this.applianceId, required this.baseUrl});
  final String applianceId;
  final String baseUrl;

  factory RpiNodeInfo.fromJson(Map<String, dynamic> json) => RpiNodeInfo(
        applianceId: json['appliance_id'] as String,
        baseUrl: json['base_url'] as String,
      );
}

/// POST /panel-scan 초안의 버튼 하나.
class PanelScanButton {
  const PanelScanButton({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
    required this.kind,
    required this.labelFromModel,
  });

  final String id;
  final String label;

  /// 편집기 격자 칸(열, 행).
  final int x;
  final int y;

  /// button | dial
  final String kind;

  /// false면 인식이 이름을 읽지 못해 서버가 임시 이름을 붙였다.
  final bool labelFromModel;

  factory PanelScanButton.fromJson(Map<String, dynamic> json) =>
      PanelScanButton(
        id: json['id'] as String,
        label: json['label'] as String,
        x: (json['x'] as num).toInt(),
        y: (json['y'] as num).toInt(),
        kind: json['kind'] as String? ?? 'button',
        labelFromModel: json['label_from_model'] as bool? ?? true,
      );
}

/// 조작부 사진 인식 **초안**. 서버는 저장하지 않는다 — 사람이 고친 뒤 등록한다.
class PanelScanDraft {
  const PanelScanDraft({
    required this.rows,
    required this.cols,
    required this.buttons,
    this.dropped = const [],
    this.notes = const [],
    this.model = '',
  });

  final int rows;
  final int cols;
  final List<PanelScanButton> buttons;

  /// 서버가 인식 결과에서 뺀 항목과 이유.
  final List<String> dropped;
  final List<String> notes;

  /// 인식에 쓴 모델 id.
  final String model;

  factory PanelScanDraft.fromJson(Map<String, dynamic> json) => PanelScanDraft(
        rows: (json['rows'] as num).toInt(),
        cols: (json['cols'] as num).toInt(),
        buttons: (json['buttons'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(PanelScanButton.fromJson)
            .toList(),
        dropped: (json['dropped'] as List<dynamic>?)?.cast<String>() ?? const [],
        notes: (json['notes'] as List<dynamic>?)?.cast<String>() ?? const [],
        model: json['model'] as String? ?? '',
      );
}

class RpiApiService {
  RpiApiService(String baseUrl, {http.Client? client, String? apiKey})
      : _base = Uri.parse(baseUrl.replaceAll(RegExp(r'/$'), '')),
        _client = client ?? http.Client(),
        _apiKey = (apiKey == null || apiKey.trim().isEmpty)
            ? null
            : apiKey.trim();

  final Uri _base;
  final http.Client _client;

  /// 이 서비스가 붙어 있는 서버 주소(끝 슬래시 없음). 응답이 **어느 서버의**
  /// 것인지 표시할 때 쓴다.
  String get baseUrl => _base.toString();

  // 서버 SIMPLELAY_API_KEY와 짝 — 설정돼 있으면 모든 요청에 X-API-Key 헤더
  final String? _apiKey;

  Map<String, String> get _headers => {
        if (_apiKey != null) 'X-API-Key': _apiKey,
      };

  Map<String, String> get _jsonHeaders => {
        'Content-Type': 'application/json',
        ..._headers,
      };

  static const _timeout = Duration(seconds: 8);

  // GET /health — 연결 확인 + DND 상태 + actuator 상태
  Future<Map<String, dynamic>> routineRequest(Map<String, dynamic>? event) async {
    final uri = _base.replace(path: '/simulator/routine/${event == null ? 'state' : 'event'}');
    final response = await (event == null
        ? _client.get(uri, headers: _jsonHeaders)
        : _client.post(uri, headers: _jsonHeaders, body: jsonEncode(event)))
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw StateError('모의 요청 실패: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> requestPairing(String code, String phone) async {
    final res = await _client.post(_base.replace(path: '/pair'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'code': code, 'phone': phone})).timeout(_timeout);
    _checkStatus(res);
    return _decodeMap(res);
  }

  Future<Map<String, dynamic>> pairingResult(String token) async {
    final res = await _client.post(_base.replace(path: '/pair/result'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'token': token})).timeout(_timeout);
    _checkStatus(res);
    return _decodeMap(res);
  }

  Future<bool> ping() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/status'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode == 401) {
        throw RpiApiException(401, '허브 키가 필요해요');
      }
      return res.statusCode == 200;
    } on RpiApiException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  Future<RpiHealthData?> health() async {
    try {
      final res = await _client
          // 공개 /health는 생존·버전만(2026-10-14 보안 점검) — 준비 상태·잠시 쉬기는 인증 경로에서 받는다.
          .get(_base.replace(path: '/health/detail'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      return RpiHealthData.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // GET /sensors — DHT22 온습도
  Future<SensorReading?> sensors() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/sensors'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      return SensorReading.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // POST /dnd — DND 설정 (minutes: 30, 60, 120). 돌려주는 값은 서버 `persisted`(2026-10-14 HIGH 재확인 M-R1):
  // true 저장됨 · false 저장 실패(이번 세션만 적용 — 화면이 알린다) · null 저장소 없는 구성·옛 서버.
  Future<bool?> setDnd(int minutes) async {
    final res = await _client
        .post(
          _base.replace(path: '/dnd'),
          headers: _jsonHeaders,
          body: jsonEncode({'duration_minutes': minutes}),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return _persisted(res);
  }

  // DELETE /dnd — DND 해제. 돌려주는 값은 setDnd와 같다.
  Future<bool?> clearDnd() async {
    final res = await _client
        .delete(_base.replace(path: '/dnd'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return _persisted(res);
  }

  static bool? _persisted(http.Response res) {
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      return body is Map<String, dynamic> && body['persisted'] is bool ? body['persisted'] as bool : null;
    } catch (_) {
      return null;
    }
  }

  // GET/PUT /quiet-hours — 조용한 시간(2026-10-14). 서버에 영속, 키오스크와 같은 상태.
  Future<QuietHoursStatus?> quietHours() async {
    final res = await _client
        .get(_base.replace(path: '/quiet-hours'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return QuietHoursStatus.fromJson(_decodeMap(res));
  }

  /// 바꿀 값만 보낸다(`enabled`·`start`·`end`). 422 detail은 화면에 그대로 보여도 되는 문장.
  Future<QuietHoursStatus?> setQuietHours(Map<String, Object> change) async {
    final res = await _client
        .put(_base.replace(path: '/quiet-hours'),
            headers: _jsonHeaders, body: jsonEncode(change))
        .timeout(_timeout);
    _checkStatus(res);
    return QuietHoursStatus.fromJson(_decodeMap(res));
  }

  // POST /execute — 즉시 job_id 접수 응답(비동기 job 모델)
  Future<RpiJobAccepted> execute(
    String text, {
    String source = 'voice',
    String? applianceId,
  }) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'text': text,
            'source': source,
            if (applianceId != null) 'appliance_id': applianceId,
          }),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return RpiJobAccepted.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  // POST /execute-buttons — 의도 해석 우회, 사용자 정의 가전의 수동 버튼 실행용
  Future<RpiJobAccepted> executeButtons(
    List<String> buttons, {
    String? applianceId,
  }) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute-buttons'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'buttons': buttons,
            if (applianceId != null) 'appliance_id': applianceId,
          }),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return RpiJobAccepted.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// POST /thinq/command — ThinQ 가전 직접 조작(2026-10-15). 화면이 확인을 받은 뒤에만
  /// 부른다. 허용되지 않는 값은 허브가 보내기 전에 거절한다(RpiApiException).
  ///
  /// 시간 초과·연결 오류(그 밖의 예외)는 **보내지 못했다는 뜻이 아니다** — 요청이 이미
  /// 허브에 닿았을 수 있다. 부르는 쪽은 '결과를 모른다'로 다루고 상태를 다시 읽는다
  /// (package:http로는 '보내기 전 거부'와 '보낸 뒤 응답 없음'을 믿을 만하게 가르지 못한다).
  Future<RpiJobAccepted> thinqCommand(
    String applianceId,
    String action,
    Map<String, String> args,
  ) async {
    final res = await _client
        .post(
          _base.replace(path: '/thinq/command'),
          headers: _jsonHeaders,
          body: jsonEncode(
              {'appliance_id': applianceId, 'action': action, 'args': args}),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return RpiJobAccepted.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  // POST /execute-for-appliance — 사용자 정의 가전용 음성 명령. 서버 고정 규칙이
  // 아니라 이 가전의 실제 버튼 라벨 어휘를 넘겨서 LLM이 그 안에서만 해석하게 한다.
  // LLM이 서버에 설정 안 돼 있으면 503(RpiApiException)으로 실패한다.
  Future<RpiJobAccepted> executeForAppliance(
    String text,
    List<String> knownButtons, {
    String? applianceId,
  }) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute-for-appliance'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'text': text,
            'known_buttons': knownButtons,
            if (applianceId != null) 'appliance_id': applianceId,
          }),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return RpiJobAccepted.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  // GET /status
  Future<RpiStatusResult> status() async {
    final res =
        await _client.get(_base.replace(path: '/status'), headers: _headers).timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final rawButtons = body['last_buttons'] as List<dynamic>?;
    return RpiStatusResult(
        executionMode: body['execution_mode'] as String? ?? 'unknown',
        lastExecutionMode: body['last_execution_mode'] as String? ?? 'unknown',
      running: body['running'] as bool,
      lastStatus: body['last_status'] as String?,
      lastButtons: rawButtons
          ?.cast<Map<String, dynamic>>()
          .map(RpiButtonStep.fromJson)
          .toList(),
      currentButton: body['current_button'] as String?,
      currentAttempt: (body['current_attempt'] as num?)?.toInt(),
      completedSteps: (body['completed_steps'] as num?)?.toInt(),
      totalSteps: (body['total_steps'] as num?)?.toInt(),
      verificationConfidence:
          (body['verification_confidence'] as num?)?.toDouble(),
      verificationDetail: body['verification_detail'] as String?,
      jobId: body['job_id'] as String?,
      lastJobId: body['last_job_id'] as String?,
      applianceId: body['appliance_id'] as String?,
      lastApplianceId: body['last_appliance_id'] as String?,
      lastOutcome: body['last_outcome'] as String?,
      route: body['route'] as String?,
      lastRoute: body['last_route'] as String?,
      lastReceipt: body['last_receipt'] as String?,
      lastConfirmation: body['last_confirmation'] as String?,
      lastDetail: body['last_detail'] as String?,
      lastRetryCount: (body['last_retry_count'] as num?)?.toInt(),
      lastOperationConfirmed: body['last_operation_confirmed'] as bool?,
      lastOperationSource: body['last_operation_source'] as String?,
      lastOperationDetail: body['last_operation_detail'] as String?,
      lastAbortReason: body['last_abort_reason'] as String?,
      estopLatched: body['estop_latched'] == true,
      estopDetail: body['estop_latched'] == true && body['estop_detail'] is String
          ? body['estop_detail'] as String
          : null,
      lastStopLevel: body['last_stop_level'] as String?,
      lastStopAckMs: (body['last_stop_ack_ms'] as num?)?.toInt(),
      lastStopJobId: body['last_stop_job_id'] as String?,
      reportsStopJobId: body.containsKey('last_stop_job_id'),
    );
  }

  // POST /stop
  /// 정지 요청. 돌려주는 값은 서버가 알린 정지 확인 단계(2026-10-13) — 옛 서버면 단계 없음.
  Future<StopOutcome> stop() async {
    final res = await _client
        .post(_base.replace(path: '/stop'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      return body is Map<String, dynamic>
          ? StopOutcome.fromJson(body)
          : const StopOutcome();
    } on FormatException {
      return const StopOutcome();
    }
  }

  /// POST /stop/ack — 사람이 확인한 비상정지 해제 요청(2026-10-05).
  ///
  /// **사용자가 확인 대화에서 '해제'를 누른 뒤에만** 부른다. 예외를 던지지 않고
  /// 결과 종류로 돌려준다 — 화면은 실패해도 배너를 남기고 이유를 보인다.
  Future<EstopAckResult> ackEstop() async {
    try {
      final res = await _client
          .post(_base.replace(path: '/stop/ack'), headers: _headers)
          .timeout(_timeout);
      _checkStatus(res);
      return EstopAckResult.fromJson(_decodeMap(res));
    } on RpiApiException catch (e) {
      return EstopAckResult.fromStatusCode(e.statusCode, detail: e.message);
    } catch (_) {
      return const EstopAckResult(EstopAckOutcome.failed);
    }
  }

  // GET /suggestions
  Future<LearningStatus> learningStatus() async {
    final res = await _client
        .get(_base.replace(path: '/learning'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return LearningStatus.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<List<RpiSuggestion>> suggestions() async {
    final res = await _client
        .get(_base.replace(path: '/suggestions'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
    return body
        .cast<Map<String, dynamic>>()
        .map(RpiSuggestion.fromJson)
        .toList();
  }

  // POST /suggestions/{id}/approve — 즉시 job_id 접수 응답(비동기 job 모델)
  Future<RpiJobAccepted> approveSuggestion(String id) async {
    final res = await _client
        .post(_base.replace(path: '/suggestions/$id/approve'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return RpiJobAccepted.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  // POST /suggestions/{id}/reject
  Future<void> rejectSuggestion(String id, {bool mute = false}) async {
    final res = await _client
        .post(
          _base.replace(path: '/suggestions/$id/reject'),
          headers: _jsonHeaders,
          body: jsonEncode({'mute': mute}),
        )
        .timeout(_timeout);
    _checkStatus(res);
  }

  Future<void> snoozeSuggestion(String id) async {
    final res = await _client.post(
      _base.replace(path: '/suggestions/$id/snooze'),
      headers: _jsonHeaders,
    ).timeout(_timeout);
    _checkStatus(res);
  }

  Future<Map<String, List<String>>> revisionOptions(String id) async {
    final res = await _client.get(
      _base.replace(path: '/suggestions/$id/revision-options'), headers: _headers,
    ).timeout(_timeout);
    _checkStatus(res);
    final options = jsonDecode(res.body)['options'] as Map<String, dynamic>;
    return options.map((key, value) => MapEntry(key, (value as List).cast<String>()));
  }

  Future<RpiSuggestion> reviseSuggestion(String id, String purpose) async {
    final res = await _client.post(
      _base.replace(path: '/suggestions/$id/revise'), headers: _jsonHeaders,
      body: jsonEncode({'purpose': purpose}),
    ).timeout(_timeout);
    _checkStatus(res);
    return RpiSuggestion.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  // GET /suppressions -- 다시 추천 안 하는 루틴 목록
  Future<List<String>> suppressions() async {
    final res = await _client
        .get(_base.replace(path: '/suppressions'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['purposes'] as List).cast<String>();
  }

  // POST /suppressions/unmute -- 억제 해제
  Future<void> unmuteSuppression(String purpose) async {
    final res = await _client
        .post(
          _base.replace(path: '/suppressions/unmute'),
          headers: _jsonHeaders,
          body: jsonEncode({'purpose': purpose}),
        )
        .timeout(_timeout);
    _checkStatus(res);
  }

  // ── 안부 확인 일시 중지 (F5) ────────────────────────────────────────
  //
  // 제안 DND(분 단위)와 다른 것이다. 이건 "며칠간 조용한 게 정상이다"이고,
  // 쉬는 동안에도 실행 실패·위험소리 알림은 그대로 간다.

  /// 쉬고 있으면 종료 날짜, 아니면 null. 조회 실패도 null이다 — 호출부가
  /// 그 구분을 필요로 하지 않는다(화면은 서버가 답할 때만 상태를 바꾼다).
  /// 쉬는 중이면 종료 날짜, 아니면 null.
  ///
  /// **쉬는 중인지는 서버의 `paused`로 판단한다.** 날짜만 보고
  /// 추측하면 이미 끝난 일시 중지의 지난 날짜를 받았을 때 화면이
  /// "7월 23일까지 쉬어요"라고 말하는데 서버는 이미 안부 신호를 다시
  /// 보내고 있는 상태가 된다.
  Future<DateTime?> wellnessPause() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/wellness-pause'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['paused'] != true) return null;
      final until = body['until'] as String?;
      return until == null ? null : DateTime.tryParse(until);
    } catch (_) {
      return null;
    }
  }

  /// 성공하면 서버가 확정한 종료 날짜, 실패하면 null.
  ///
  /// 서버가 상한(90일)과 지난 날짜를 거절한다 -- 날짜 선택기의 제한은
  /// 편의일 뿐, 규칙 자체는 서버에 있다.
  Future<DateTime?> setWellnessPause(DateTime until) async {
    try {
      final res = await _client
          .post(
            _base.replace(path: '/wellness-pause'),
            headers: _jsonHeaders,
            body: jsonEncode({
              'until': until.toIso8601String().split('T').first,
            }),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final saved = body['until'] as String?;
      return saved == null ? null : DateTime.tryParse(saved);
    } catch (_) {
      return null;
    }
  }

  Future<bool> clearWellnessPause() async {
    try {
      final res = await _client
          .delete(_base.replace(path: '/wellness-pause'), headers: _headers)
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // GET /history — 실행 이력(최신순)
  Future<List<RpiHistoryEntry>> history({int limit = 50}) async {
    final res = await _client
        .get(
          _base.replace(
            path: '/history',
            queryParameters: {'limit': '$limit'},
          ),
          headers: _headers,
        )
        .timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
    return body
        .cast<Map<String, dynamic>>()
        .map(RpiHistoryEntry.fromJson)
        .toList();
  }

  /// GET /readiness/{id} — 경로별 준비 상태. 조회 실패는 null(모름 ≠ 준비 안 됨).
  Future<RpiReadiness?> readiness(String applianceId) async {
    try {
      final res = await _client
          .get(_base.replace(path: '/readiness/$applianceId'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      return RpiReadiness.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// GET /scenarios — 시나리오 ID → 이름. 옛 서버·실패는 빈 맵(이름 없이 질문만 보인다).
  Future<Map<String, String>> scenarioNames() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/scenarios'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return const {};
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return {
        for (final d in body.whereType<Map<String, dynamic>>())
          if (d['scenario_id'] is String && d['name'] is String)
            d['scenario_id'] as String: d['name'] as String,
      };
    } catch (_) {
      return const {};
    }
  }

  /// GET /scenarios/last-run — 마지막 실행의 단계별 결과. 기록이 없거나 옛 서버·
  /// 조회 실패면 null(화면은 아무것도 새로 말하지 않는다).
  Future<ScenarioRun?> scenarioLastRun() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/scenarios/last-run'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      return ScenarioRun.fromLastRunJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// GET /thinq/devices — 허브가 ThinQ를 껐으면(404) null.
  ///
  /// **조회 실패는 null이 아니라 예외다**(외부 검토 M3, 2026-10-15) — 연결 실패를 'ThinQ
  /// 계정이 연결되지 않았다'로 말하지 않게. 시간 초과·연결 오류는 그대로, 404가 아닌
  /// 오류 응답은 [RpiApiException]으로 던진다. 목록만 쓰는 화면은 예전처럼 `valueOrNull`로 본다.
  Future<RpiThinqOverview?> thinqOverview() async {
    final res = await _client
        .get(_base.replace(path: '/thinq/devices'), headers: _headers)
        .timeout(_timeout);
    if (res.statusCode == 404) return null;
    _checkStatus(res);
    return RpiThinqOverview.fromJson(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  // 찾기·추가는 허브가 ThinQ 클라우드에 목록·기기 프로필을 묻고 답한다 — 일반 제한(8초)보다 길게.
  static const _thinqTimeout = Duration(seconds: 20);

  /// GET /thinq/discovered — ThinQ 계정에서 찾은 가전. 실패는 이유가 담긴
  /// 결과로 돌려준다(null·빈 목록으로 '0대'처럼 보이지 않게).
  Future<RpiThinqDiscovery> thinqDiscovery() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/thinq/discovered'), headers: _headers)
          .timeout(_thinqTimeout);
      if (res.statusCode == 404) {
        return const RpiThinqDiscovery.failed(
            '허브에서 ThinQ 연결이 꺼져 있어요 — 허브 설정에서 켜야 가전을 찾을 수 있어요.',
            off: true);
      }
      if (res.statusCode == 401) {
        return const RpiThinqDiscovery.failed('허브 키가 맞지 않아요 — 허브 설정에서 키를 확인해 주세요.');
      }
      if (res.statusCode != 200) {
        return RpiThinqDiscovery.failed(
            '허브가 ThinQ 목록을 주지 못했어요 (HTTP ${res.statusCode}).');
      }
      return RpiThinqDiscovery.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return const RpiThinqDiscovery.failed('허브에 닿지 않아요 — 연결을 확인한 뒤 다시 찾아 주세요.');
    }
  }

  /// GET /thinq/status/{id} — 지금 상태(읽기만). 실패는 이유가 담긴 결과로 돌려준다.
  Future<RpiThinqStatus> thinqStatus(String applianceId, {DateTime Function()? now}) async {
    try {
      final res = await _client
          .get(
              _base.replace(
                  path: '/thinq/status/${Uri.encodeComponent(applianceId)}'),
              headers: _headers)
          .timeout(_thinqTimeout);
      if (res.statusCode == 401) {
        return const RpiThinqStatus.failed('허브 키가 맞지 않아요 — 허브 설정에서 키를 확인해 주세요.');
      }
      if (res.statusCode != 200) {
        return RpiThinqStatus.failed(_utf8Detail(res, '지금 상태를 읽지 못했어요'));
      }
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final state = body['state'];
      if (state is! Map<String, dynamic>) {
        return const RpiThinqStatus.failed('허브가 준 상태를 해석하지 못했어요.');
      }
      return RpiThinqStatus(
        executionMode: body['execution_mode'] as String? ?? 'unknown',
        state: state,
        readAt: (now ?? DateTime.now)(),
      );
    } catch (_) {
      return const RpiThinqStatus.failed('허브에 닿지 않아요 — 연결을 확인한 뒤 다시 읽어 주세요.');
    }
  }

  /// POST /thinq/added — 찾은 가전 하나를 추가한다. 실패면 이유를 담아 던진다.
  Future<String> addThinqDevice(String key) async {
    final http.Response res;
    try {
      res = await _client
          .post(_base.replace(path: '/thinq/added'),
              headers: _jsonHeaders, body: jsonEncode({'key': key}))
          .timeout(_thinqTimeout);
    } catch (_) {
      throw RpiApiException(0, '허브에 닿지 않아 추가하지 못했어요.');
    }
    if (res.statusCode != 200) {
      throw RpiApiException(res.statusCode, _utf8Detail(res, '추가하지 못했어요'));
    }
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return body['name'] as String? ?? '';
  }

  /// DELETE /thinq/added/{key} — 사용자가 추가한 가전을 뺀다.
  Future<void> removeThinqDevice(String key) async {
    final http.Response res;
    try {
      res = await _client
          .delete(_base.replace(path: '/thinq/added/$key'), headers: _headers)
          .timeout(_timeout);
    } catch (_) {
      throw RpiApiException(0, '허브에 닿지 않아 빼지 못했어요.');
    }
    if (res.statusCode != 200) {
      throw RpiApiException(res.statusCode, _utf8Detail(res, '빼지 못했어요'));
    }
  }

  /// FastAPI 오류 문장(UTF-8). 못 읽으면 대체 문장.
  String _utf8Detail(http.Response res, String fallback) {
    try {
      final detail =
          (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
    } catch (_) {
      // 아래 대체 문장
    }
    return '$fallback (HTTP ${res.statusCode}).';
  }

  // GET /nodes — 등록된 ESP32 노드 목록
  /// GET /care-events — 보호자 알림함(최신순).
  ///
  /// 실패는 null — 빈 목록과 구분해야 한다: 일시적 통신 실패를 "알림 0건"
  /// 으로 표현하면 보고 있던 알림이 사라지고 배지도 꺼져, 보호자가
  /// "해결됐나 보다"라고 오해한다 (교차 리뷰 #13).
  Future<List<RpiCareEvent>?> careEvents({int limit = 50}) async {
    try {
      final res = await _client
          .get(
            _base.replace(
              path: '/care-events',
              queryParameters: {'limit': '$limit'},
            ),
            headers: _headers,
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return body
          .cast<Map<String, dynamic>>()
          .map(RpiCareEvent.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<List<RpiNodeInfo>> listNodes() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/nodes'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body) as List<dynamic>;
      return body
          .cast<Map<String, dynamic>>()
          .map(RpiNodeInfo.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// GET /appliances의 커스텀 가전 **정의 전체**.
  ///
  /// 동기화가 서버에만 있는 가전을 **내려받아 병합**하는 데 쓴다. 예전에는
  /// id만 받아서 "이 폰에 없으면 유령"으로 보고 지웠는데, 폰이 둘이면 그건
  /// 다른 폰의 등록이었다 -- 서버에만 있다는 것은 "지워도 된다"가 아니라
  /// "이 폰이 아직 못 받았다"는 뜻이다.
  ///
  /// 조회 실패는 **null**이다. 빈 목록으로 뭉개면 "서버에 아무것도 없다"로
  /// 읽혀 병합·삭제 판단이 통째로 뒤집힌다.
  Future<List<ApplianceMap>?> customAppliances() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/appliances'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return [
        for (final item in body.cast<Map<String, dynamic>>())
          if (item['is_custom'] == true) ApplianceMap.fromJson(item),
      ];
    } catch (_) {
      return null;
    }
  }

  /// GET /appliances **전체** -- 서버 내장 가전과 사용자 등록 가전을 함께,
  /// 각각 `isCustom`으로 구분해 돌려준다.
  ///
  /// 내장 가전 목록(`serverApplianceCatalogProvider`)이 쓴다. 준비 상태
  /// (`can_execute`·`readiness`)도 항목마다 실려 오므로, 목록에 있다는
  /// 사실만으로 실행 가능하다고 보지 않는다.
  ///
  /// 조회 실패는 `customAppliances()`와 같은 이유로 **null**이다 -- 빈
  /// 목록과 섞으면 "서버에 가전이 없다"로 읽힌다.
  Future<List<ApplianceMap>?> listAppliances() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/appliances'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return [
        for (final item in body.cast<Map<String, dynamic>>())
          ApplianceMap.fromJson(item),
      ];
    } catch (_) {
      return null;
    }
  }

  // PUT /appliances/{id} — 커스텀 가전을 서버에 등록 (키오스크가 같은
  // 목록을 받아 폰에서 추가한 가전이 키오스크에도 뜬다). 서버가 죽어 있어도
  // 폰 로컬 저장은 이미 끝난 뒤라, 실패는 false만 돌려주고 막지 않는다.
  Future<bool> registerAppliance(ApplianceMap appliance) async {
    try {
      final res = await _client
          .put(
            _base.replace(path: '/appliances/${appliance.id}'),
            headers: _jsonHeaders,
            body: jsonEncode({
              // "내가 본 판은 이거였다". 모르면(0) 밝히지 않는다 --
              // 최초 등록과 기기 저장분의 경로다.
              if (appliance.revision > 0)
                'expected_revision': appliance.revision,
              'name': appliance.name,
              // 종류가 진실원천이다. 예전에는 이 자리에 내장 가전의
              // id나 'custom'을 넣어서, 식별자와 종류가 뭉개지고
              // 커스텀 가전의 종류는 아예 사라졌다.
              'category': appliance.category.value,
              'rows': appliance.rows,
              'cols': appliance.cols,
              'buttons': [
                for (final b in appliance.buttons)
                  {'id': b.id, 'label': b.label, 'x': b.x, 'y': b.y},
              ],
            }),
          )
          .timeout(_timeout);
      if (res.statusCode == 409) {
        // 다른 기기가 먼저 바꿨다. false로 뭉개면 호출부가 통신 실패로
        // 보고 계속 재시도한다 -- 같은 충돌이 영원히 반복된다.
        throw RpiApiException(409, _detailOf(res));
      }
      return res.statusCode == 200;
    } on RpiApiException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  String _detailOf(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['detail']
              as String? ??
          res.body;
    } catch (_) {
      return res.body;
    }
  }

  // 사진 인식은 서버가 외부 인식 서비스를 기다린다(서버 제한 60초) — 일반
  // 요청 제한(8초)으로 끊으면 성공할 인식도 매번 실패로 보인다.
  static const _panelScanTimeout = Duration(seconds: 75);

  /// POST /panel-scan — 조작부 사진으로 버튼 배치 **초안**을 받는다.
  ///
  /// 서버는 초안을 저장하지 않는다. 실패는 화면에 그대로 보여줄 문장을 담은
  /// [RpiApiException]으로 던진다 — 꺼져 있음(503)·크레딧 부족·사진 형식
  /// 오류는 사용자가 할 일이 서로 달라서 '실패했어요' 하나로 뭉개지 않는다.
  Future<PanelScanDraft> scanPanel(List<int> imageBytes) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            _base.replace(path: '/panel-scan'),
            headers: _jsonHeaders,
            body: jsonEncode({'image_base64': base64Encode(imageBytes)}),
          )
          .timeout(_panelScanTimeout);
    } on TimeoutException {
      throw RpiApiException(0, '사진을 읽는 데 너무 오래 걸려요. 잠시 후 다시 시도해 주세요.');
    } catch (_) {
      throw RpiApiException(0, '서버에 연결하지 못했어요. 연결 상태를 확인해 주세요.');
    }
    if (res.statusCode == 404) {
      throw RpiApiException(404, '서버가 사진 인식을 지원하지 않아요. 서버를 업데이트해 주세요.');
    }
    if (res.statusCode != 200) {
      throw RpiApiException(res.statusCode, _panelScanDetail(res));
    }
    try {
      return PanelScanDraft.fromJson(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>,
      );
    } catch (_) {
      throw RpiApiException(res.statusCode, '서버 응답을 읽을 수 없어요.');
    }
  }

  /// 오류 문장. FastAPI는 charset 없이 JSON을 보내므로 바이트를 UTF-8로 직접
  /// 푼다(res.body는 latin1로 풀어 한글이 깨진다). 검증 오류(422)는 목록으로 온다.
  String _panelScanDetail(http.Response res) {
    try {
      final detail =
          (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['detail'];
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is List && detail.isNotEmpty) {
        final msg = (detail.first as Map<String, dynamic>)['msg'] as String?;
        if (msg != null && msg.isNotEmpty) {
          return msg.replaceFirst(RegExp(r'^Value error,\s*'), '');
        }
      }
    } catch (_) {
      // 아래 기본 문장
    }
    return '사진 인식에 실패했어요 (HTTP ${res.statusCode}).';
  }

  // DELETE /appliances/{id} — 서버 목록에서도 제거
  Future<bool> deleteAppliance(
    String applianceId, {
    int? expectedRevision,
  }) async {
    try {
      final res = await _client
          .delete(
            _base.replace(
              path: '/appliances/$applianceId',
              queryParameters: expectedRevision == null
                  ? null
                  : {'expected_revision': '$expectedRevision'},
            ),
            headers: _headers,
          )
          .timeout(_timeout);
      if (res.statusCode == 409) {
        // 내가 본 판 이후에 다른 기기가 바꿨다. false로 뭉개면 호출부가
        // 통신 실패로 보고 계속 재시도한다 -- 같은 충돌이 영원히 반복된다.
        throw RpiApiException(409, _detailOf(res));
      }
      // 404는 성공으로 본다 -- 되돌려 놓으려던 상태(그 가전이 없음)가 이미
      // 성립했다. 실패로 치면 대기열에서 영영 안 빠진다.
      return res.statusCode == 200 || res.statusCode == 404;
    } on RpiApiException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  // POST /nodes/{id} — ESP32 노드 등록 (이미 있으면 덮어씀)
  Future<bool> registerNode(String applianceId, String baseUrl) async {
    try {
      final res = await _client
          .post(
            _base.replace(path: '/nodes/$applianceId'),
            headers: _jsonHeaders,
            body: jsonEncode({'base_url': baseUrl}),
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // DELETE /nodes/{id} — 노드 등록 해제
  Future<bool> unregisterNode(String applianceId) async {
    try {
      final res = await _client
          .delete(_base.replace(path: '/nodes/$applianceId'), headers: _headers)
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── 허브 상태·위치 (2026-09-30) ─────────────────────────────────────────

  /// GET /status 중 탭 구조·대기 표시에 쓰는 값. 실패는 예외.
  Future<HubStatus> hubStatus() async {
    final res = await _client
        .get(_base.replace(path: '/status'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    // 여기부터는 허브가 답했다 — 해석 실패(본문이 맵이 아님·필드 타입 오류 TypeError 등)는 통신 단절과 구별되게
    // 모두 FormatException으로 알린다(2차 평가 L-N1). 주기 조회는 이것을 '닿음'으로 센다.
    try {
      return HubStatus.fromJson(_decodeMap(res));
    } on FormatException {
      rethrow;
    } on Object catch (e) {
      throw FormatException('허브 /status 응답 형식이 맞지 않아요: $e');
    }
  }

  Future<HubLocation> hubLocation() async {
    final res = await _client
        .get(_base.replace(path: '/hub/location'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return HubLocation.fromJson(_decodeMap(res));
  }

  /// PUT /hub/location. 서버가 약 1km(소수 둘째 자리)로 줄여 저장한다.
  /// 국내 밖이면 422 — detail을 그대로 보여 준다.
  Future<HubLocation> setHubLocation(double lat, double lon) async {
    final res = await _client
        .put(
          _base.replace(path: '/hub/location'),
          headers: _jsonHeaders,
          body: jsonEncode({'lat': lat, 'lon': lon}),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return HubLocation.fromJson(_decodeMap(res));
  }

  // ── 루틴 (2026-09-30, docs/devlog/devlog_2026-09-30-routines.md §3) ──────────────
  //
  // 이 묶음에는 **실행 호출이 없다.** '지금 실행'도 카드를 만들 뿐이고,
  // 실행은 제안 승인(approveSuggestion) 하나로만 일어난다.

  Future<List<Routine>> routines() async {
    final res = await _client
        .get(_base.replace(path: '/routines'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return _decodeList(res).map(Routine.fromJson).toList();
  }

  Future<List<Routine>> routineTemplates() async {
    final res = await _client
        .get(_base.replace(path: '/routines/templates'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return _decodeList(res).map(Routine.fromJson).toList();
  }

  Future<List<RoutineNextRun>> nextRoutines({int limit = 3}) async {
    final res = await _client
        .get(
          _base.replace(
            path: '/routines/next',
            queryParameters: {'limit': '$limit'},
          ),
          headers: _headers,
        )
        .timeout(_timeout);
    _checkStatus(res);
    return _decodeList(res).map(RoutineNextRun.fromJson).toList();
  }

  /// 새 루틴(id 없음)은 POST, 있으면 PUT(전체 교체). 422 detail은 화면에
  /// 그대로 보여도 되는 문장이다.
  Future<Routine> saveRoutine(Routine routine) async {
    final id = routine.id;
    final body = jsonEncode(routine.toRequestJson());
    final res = await (id == null
            ? _client.post(_base.replace(path: '/routines'),
                headers: _jsonHeaders, body: body)
            : _client.put(_base.replace(path: '/routines/$id'),
                headers: _jsonHeaders, body: body))
        .timeout(_timeout);
    _checkStatus(res);
    return Routine.fromJson(_decodeMap(res));
  }

  Future<void> deleteRoutine(String id) async {
    final res = await _client
        .delete(_base.replace(path: '/routines/$id'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
  }

  // ── 사용 기록 → 루틴 초안(2026-10-14) — 저장만 한다(실행·카드·자동 실행 허용 없음) ──

  Future<List<RoutineCandidate>> routineCandidates() async {
    final res = await _client
        .get(_base.replace(path: '/routines/candidates'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return [
      for (final item in _decodeList(res))
        if (RoutineCandidate.fromJson(item) case final c?) c,
    ];
  }

  /// [run]은 `manual`(직접 실행할 때만) 또는 `ask_at_time`(정해진 때 물어보기).
  Future<Routine> saveRoutineCandidate(String key, {required String name, required String run}) async {
    final res = await _client
        .post(
          _base.replace(path: '/routines/candidates/$key/save'),
          headers: _jsonHeaders,
          body: jsonEncode({'name': name, 'run': run}),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return Routine.fromJson(_decodeMap(res)['routine'] as Map<String, dynamic>);
  }

  Future<void> declineRoutineCandidate(String key) async {
    final res = await _client
        .post(_base.replace(path: '/routines/candidates/$key/decline'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
  }

  // ── 자동 실행 허용 규칙(2026-10-13) — 규칙은 카드에서만 생긴다(빈 폼 없음) ──

  /// '이번에 실행하고 다음부터 자동으로' — 이번 실행(job)과 규칙 저장을 한 번에. 확인 화면이 보여 준
  /// 내용의 지문을 함께 보낸다(다르면 서버 409). 물리 누름 카드는 서버가 422로 거절한다.
  Future<RpiJobAccepted> approveAndAllowSuggestion(String id, String offerFingerprint) async {
    final res = await _client
        .post(
          _base.replace(path: '/suggestions/$id/approve-and-allow'),
          headers: _jsonHeaders,
          body: jsonEncode({'offer_fingerprint': offerFingerprint}),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return RpiJobAccepted.fromJson(_decodeMap(res));
  }

  Future<List<AutoRule>> autoRules() async {
    final res = await _client
        .get(_base.replace(path: '/routines/auto-rules'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return _decodeList(res).map(AutoRule.fromJson).toList();
  }

  /// 끄기(`fingerprint` 없음) · 다시 허용(확인 화면을 본 뒤 목록의 `fingerprint`).
  Future<AutoRule> setAutoRuleEnabled(String id, bool enabled, {String? fingerprint}) async {
    final res = await _client
        .post(
          _base.replace(path: '/routines/auto-rules/$id/enable'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'enabled': enabled,
            if (fingerprint != null) 'fingerprint': fingerprint,
          }),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return AutoRule.fromJson(_decodeMap(res));
  }

  /// 설정값만 바꾼다. 서버는 자동 실행을 끄고 다시 허용을 요구한다.
  Future<AutoRule> updateAutoRuleValue(String id, String value) async {
    final res = await _client
        .put(
          _base.replace(path: '/routines/auto-rules/$id'),
          headers: _jsonHeaders,
          body: jsonEncode({'value': value}),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return AutoRule.fromJson(_decodeMap(res));
  }

  Future<void> deleteAutoRule(String id) async {
    final res = await _client
        .delete(_base.replace(path: '/routines/auto-rules/$id'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
  }

  Future<Routine> setRoutineEnabled(String id, bool enabled) async {
    final res = await _client
        .post(
          _base.replace(path: '/routines/$id/enable'),
          headers: _jsonHeaders,
          body: jsonEncode({'enabled': enabled}),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return Routine.fromJson(_decodeMap(res));
  }

  /// '지금 실행' — 승인 루틴은 카드를 만들고, 알림 루틴은 알림만 남긴다.
  Future<RoutineTriggerResult> triggerRoutine(String id) async {
    final res = await _client
        .post(_base.replace(path: '/routines/$id/trigger'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    final body = _decodeMap(res);
    if (body['kind'] == 'suggestion') {
      final card = body['suggestion'] as Map<String, dynamic>?;
      return RoutineTriggerResult(suggestionId: card?['id'] as String?);
    }
    final notice = body['notice'];
    return RoutineTriggerResult(
      notice: notice is Map<String, dynamic>
          ? notice['message'] as String? ?? notice['text'] as String?
          : null,
    );
  }

  // ── 가전 추가: 사진 매핑·확인 주행 (2026-09-30) ──────────────────────────

  Future<MappingFrame> mappingFrame() async {
    final res = await _client
        .get(_base.replace(path: '/mapping/frame'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    return MappingFrame.fromJson(_decodeMap(res));
  }

  /// PUT /appliances/{id}/mapping — 사진 파일은 보내지 않는다(크기·좌표만).
  Future<MappingSaveResult> saveMapping(
    String applianceId,
    MappingRequest request,
  ) async {
    final res = await _client
        .put(
          _base.replace(path: '/appliances/$applianceId/mapping'),
          headers: _jsonHeaders,
          body: jsonEncode(request.toJson()),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return MappingSaveResult.fromJson(_decodeMap(res));
  }

  /// POST /appliances/{id}/verify-pass — 누르지 않고 Z를 올린 채 지나간다.
  Future<VerifyPass> startVerifyPass(String applianceId) async {
    final res = await _client
        .post(
          _base.replace(path: '/appliances/$applianceId/verify-pass'),
          headers: _jsonHeaders,
          body: jsonEncode(<String, dynamic>{}),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return VerifyPass.fromJson(_decodeMap(res));
  }

  Future<VerifyPass> verifyPassStatus(String applianceId) async {
    final res = await _client
        .get(
          _base.replace(path: '/appliances/$applianceId/verify-pass'),
          headers: _headers,
        )
        .timeout(_timeout);
    _checkStatus(res);
    return VerifyPass.fromJson(_decodeMap(res));
  }

  /// PUT /appliances/{id} 결과를 **기다려서** 알려 준다. [registerAppliance]는
  /// 실패를 false로 삼키지만, 가전 추가 마지막 단계는 등록이 서버에 닿아야
  /// 사진 매핑을 저장할 수 있으므로 사유가 필요하다.
  Future<Map<String, dynamic>> registerApplianceStrict(
    ApplianceMap appliance,
  ) async {
    final res = await _client
        .put(
          _base.replace(path: '/appliances/${appliance.id}'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'name': appliance.name,
            'category': appliance.category.value,
            'rows': appliance.rows,
            'cols': appliance.cols,
            'buttons': [
              for (final b in appliance.buttons)
                {'id': b.id, 'label': b.label, 'x': b.x, 'y': b.y},
            ],
          }),
        )
        .timeout(_timeout);
    _checkStatus(res);
    return _decodeMap(res);
  }

  Map<String, dynamic> _decodeMap(http.Response res) =>
      jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;

  List<Map<String, dynamic>> _decodeList(http.Response res) =>
      (jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList();

  void _checkStatus(http.Response res) {
    if (res.statusCode >= 400) {
      // FastAPI는 charset 없이 JSON을 보낸다 — res.body(latin1)로 풀면 한글
      // detail이 깨져 승인 불일치(409) 같은 사유를 가를 수 없다.
      String detail;
      try {
        detail = utf8.decode(res.bodyBytes);
      } catch (_) {
        detail = res.body;
      }
      try {
        final raw = (jsonDecode(detail) as Map<String, dynamic>)['detail'];
        if (raw is String) {
          detail = raw;
        } else if (raw is List && raw.isNotEmpty && raw.first is Map) {
          // 요청 모양 검증(422)은 목록으로 온다. 첫 문장만 쓴다.
          final msg = (raw.first as Map)['msg'];
          if (msg is String && msg.isNotEmpty) {
            detail = msg.replaceFirst(RegExp(r'^Value error,\s*'), '');
          }
        }
      } catch (_) {}
      throw RpiApiException(res.statusCode, detail);
    }
  }

  void dispose() => _client.close();
}
