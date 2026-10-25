import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../models/ambient.dart';
import '../models/appliance.dart';
import '../models/auto_run.dart';
import '../models/estop.dart';
import '../models/kiosk_history.dart';
import '../models/learning_status.dart';
import '../models/scenario_run.dart';
import '../models/thinq.dart';

class HealthStatus {
  const HealthStatus({
    required this.ok,
    this.actuatorReady = true,
    this.dndUntil,
    this.dndScope,
    this.quietActive = false,
    this.quietScheduleActive = false,
    this.quietSchedule,
    this.quietKnown = true,
  });

  final bool ok;
  final bool actuatorReady;
  final DateTime? dndUntil;

  /// 잠시 쉬기 범위(2026-10-14 마감 2번) — `suggestions_only`면 업데이트 전 설정을 이어받아 새 제안만 쉰다.
  final String? dndScope;

  /// 조용한 시간(2026-10-14, 서버 /health/detail `quiet` — 폰 /quiet-hours와 같은 상태). 매일 시간대 또는 잠시 쉬기.
  /// 이때는 일반 안내 소리(제안 도착·자동 실행 결과 낭독)를 내지 않는다.
  final bool quietActive;

  /// 조용한 시간 상태를 받았나(2026-10-14 보안 점검). 받지 못하면(인증 실패·끊김·옛 서버) '꺼짐'으로 보지 않는다 —
  /// [speakGeneral]이 거짓이 되어 일반 안내 소리를 쉰다.
  final bool quietKnown;

  /// 일반 안내 소리(제안 도착·자동 실행 결과 낭독)를 내도 되나 — 조용한 시간이 꺼져 있다고 **확인했을 때만**.
  bool get speakGeneral => quietKnown && !quietActive;

  /// 지금이 매일 조용한 시간대인가(잠시 쉬기가 아니라).
  final bool quietScheduleActive;

  /// 켜 둔 매일 시간대 (시작, 끝). 꺼져 있거나 옛 서버면 null.
  final (String, String)? quietSchedule;

  static const disconnected = HealthStatus(ok: false, actuatorReady: false, quietKnown: false);

  factory HealthStatus.fromJson(Map<String, dynamic> json) {
    final quiet = json['quiet'];
    final q = quiet is Map ? quiet : const {};
    final start = q['start'], end = q['end'];
    return HealthStatus(
      ok: json['ok'] as bool? ?? false,
      // 빠지면 준비 안 됨(2026-10-14 보안 점검 — 모르는 것을 준비됨으로 보지 않는다).
      actuatorReady: json['actuator_ready'] as bool? ?? false,
      dndUntil: json['dnd_until'] == null
          ? null
          : DateTime.parse(json['dnd_until'] as String),
      dndScope: json['dnd_scope'] as String?,
      quietActive: q['active'] == true,
      quietKnown: q['active'] is bool,
      quietScheduleActive: q['active'] == true && q['reason'] == 'schedule',
      quietSchedule: q['enabled'] == true && start is String && end is String
          ? (start, end)
          : null,
    );
  }
}

class SensorData {
  final bool mocked;
  const SensorData({this.temperature, this.humidity, this.mocked = true});

  final double? temperature;
  final double? humidity;

  factory SensorData.fromJson(Map<String, dynamic> json) => SensorData(
        mocked: json['mocked'] != false,
        temperature: (json['temperature'] as num?)?.toDouble(),
        humidity: (json['humidity'] as num?)?.toDouble(),
      );
}

class AlertState {
  const AlertState({
    required this.active,
    this.kind,
    this.meanPeriodSeconds,
  });

  final bool active;
  final String? kind;
  final double? meanPeriodSeconds;

  static const inactive = AlertState(active: false);

  factory AlertState.fromJson(Map<String, dynamic> json) => AlertState(
        active: json['active'] as bool? ?? false,
        kind: json['kind'] as String?,
        meanPeriodSeconds: (json['mean_period_seconds'] as num?)?.toDouble(),
      );
}

class KioskSuggestion {
  const KioskSuggestion({
    this.isDemo = false,
    required this.id,
    required this.purpose,
    required this.occurrences,
    this.steps = const [],
    this.reason = '',
    this.timeBand = '',
    this.applianceId,
    this.scenarioId,
    this.commands = const [],
    this.routineId,
    this.routineName,
    this.autoRuleOffer,
    this.adoptOffer,
    this.signals = const [],
    this.canMarkDone = false,
    this.kind = 'action',
    this.question,
    this.speech,
  });

  final bool isDemo;

  /// 'action'(승인하면 실행) · 'advice'(조언 — 실행 없음, '알겠어요'·'괜찮아요'만, 서버 `kind` 2026-10-26).
  final String kind;

  /// 조언 카드인가 — '네'·'다음부터 알아서'가 없고, 닫기만 한다.
  bool get isAdvice => kind == 'advice';

  /// 서버가 아는 묻는 말("제습기를 켤까요?"). 없으면 화면이 목적 문장에서 만든다.
  final String? question;

  /// 소리로 읽을 말(서버 `speech`) — "<근거 문장> <묻는 말>". 없으면 화면이 근거 + 자기 질문으로 만든다.
  final String? speech;

  /// '왜 지금' 신호(서버 `signals`, 2026-10-26) — 이 카드를 띄운 근거들. 서버가 만든 그대로만 보여 준다(화면에서 만들지 않음).
  final List<KioskSuggestionSignal> signals;

  /// 습관 카드면 참(서버 `can_mark_done`) — '이미 했어요'(오늘은 다시 묻지 않음)를 둔다.
  final bool canMarkDone;

  /// '다음부터는 알아서 하기' 내용(서버 `auto_rule_offer`, 2026-10-25 키오스크에도). 없으면 이 카드는 맡길 수 없다 —
  /// 낮은 위험 LG 가전 동작 하나인 시각 루틴·가열 종료 카드만 서버가 준다. 물리 누름 카드는 늘 묻는다.
  final KioskAutoRuleOffer? autoRuleOffer;

  /// 습관 카드에서 바로 '매일 이 시간에'(서버 `adopt_offer`, 2026-10-25). 없으면 이 카드는 루틴으로 저장할 초안이 없다.
  final KioskAdoptOffer? adoptOffer;

  /// 사용자 루틴 카드면 그 루틴(2026-09-30). 이름이 있으면 화면은 이 이름을
  /// 사용자가 붙인 말로 함께 보여 준다. 승인은 여전히 카드 id에 묶인다.
  final String? routineId;
  final String? routineName;

  /// 시나리오 제안이면 그 ID. 옛 서버·일반 제안은 null.
  final String? scenarioId;

  /// 승인에 **고정되는** 명령들(대상·경로·동작). 비어 있지 않으면 시나리오 카드다 --
  /// ThinQ 가전은 키오스크 조작판 목록(/appliances)에 없으므로 대상 확인을
  /// 조작판이 아니라 이 명령과 서버 준비 상태로 한다.
  final List<KioskSuggestionCommand> commands;

  bool get isScenario => commands.isNotEmpty;

  /// 사용자가 루틴을 직접 실행해서 생긴 카드(폰 `Suggestion.userStarted`와 같은 기준, 2026-10-14).
  /// 이때 근거 줄('직접 실행을 눌렀어요')은 사용자가 방금 한 일을 되풀이할 뿐이라 숨긴다.
  bool get userStarted =>
      routineId != null && reason.trimRight().endsWith('직접 실행을 눌렀어요');
  final String id;
  final String purpose;
  final int occurrences;

  /// 이 제안이 조작할 가전. 서버가 대상을 모르면(가전 없이 쌓인 옛 이력)
  /// null이다 -- 그때 화면은 지금 고른 가전으로 대신 채우지 않는다.
  final String? applianceId;

  // 이 루틴을 되풀이하던 시간대('아침'·'저녁'). 환경 제안은 '환경',
  // 시연용 강제 생성은 '데모'로 온다.
  final String timeBand;

  // 환경 기반 제안 등의 "왜 지금" 근거(예: "지금 30°C · 습도 72% — 더워요").
  final String reason;

  // 승인 시 실행될 버튼 시퀀스 미리보기 — 실제 버튼 라벨 문자열(예: "해동")로 온다.
  // 미리보기 해석이 실패하면 서버가 빈 리스트를 준다.
  final List<String> steps;

  /// "왜 지금 이걸 제안하는가"를 한 문장으로. 폰과 같은 규칙이다.
  ///
  /// 데모 제안은 패턴 감지를 우회하려고 횟수를 지어내므로 비운다 --
  /// 그 숫자를 '이만큼 하셨어요'로 보여주면 화면이 사실이 아닌 말을 한다.
  String get whyNow {
    if (reason.isNotEmpty) return reason;
    if (occurrences <= 0 || timeBand.isEmpty) return '';
    if (timeBand == '데모' || timeBand == '환경') return '';
    // '최근'은 쓰지 않는다 — 이 대체문은 기간을 모른다(서버 문장이 비었을 때만 쓴다).
    // 이유만 담담하게(평가 14차 10/18 — '하셔서 여쭤봐요'는 높임·낮춤이 섞인 번역투였다). 기간은 모르므로 '이번 주' 같은 말은 붙이지 않는다.
    return '$timeBand에 $occurrences번 하셨어요';
  }

  /// 실행 중·완료 화면이 "무엇을 했는지" 부를 이름 — **평서형**이다.
  ///
  /// purpose는 카드의 질문("'아침 데우기' 루틴을 실행할까요?")일 수 있다. 완료
  /// 화면이 그 질문을 되풀이하면 아직 묻는 중처럼 읽힌다(10/6 S11 실패널).
  /// 루틴 이름 → 시나리오 이름 → 질문이 아닌 purpose 순으로 쓰고, 셋 다
  /// 없으면 질문 대신 일반 명사로 말한다.
  String doneLabel({String? scenarioName}) {
    final routine = routineName;
    if (routine != null && routine.isNotEmpty) return "'$routine' 루틴";
    final isQuestion = purpose.trimRight().endsWith('?');
    if (!isQuestion) return purpose;
    if (scenarioName != null && scenarioName.isNotEmpty) return scenarioName;
    return '제안한 일';
  }

  factory KioskSuggestion.fromJson(Map<String, dynamic> json) =>
      KioskSuggestion(
        isDemo: json['is_demo'] == true || json['time_band'] == '데모',
        id: json['id'] as String,
        purpose: json['purpose'] as String,
        // 기본값을 1로 두면 횟수를 모르는 제안이 '1번 하셨어요'라고
        // 말하게 된다 -- 모르면 0으로 두고 근거를 만들지 않는다.
        occurrences: (json['occurrences'] as num?)?.toInt() ?? 0,
        steps: (json['steps'] as List<dynamic>?)?.cast<String>() ?? const [],
        reason: json['reason'] as String? ?? '',
        timeBand: json['time_band'] as String? ?? '',
        applianceId: json['appliance_id'] as String?,
        scenarioId: json['scenario_id'] as String?,
        routineId: json['routine_id'] as String?,
        routineName: json['routine_name'] as String?,
        autoRuleOffer: KioskAutoRuleOffer.fromJson(json['auto_rule_offer']),
        adoptOffer: KioskAdoptOffer.fromJson(json['adopt_offer']),
        signals: KioskSuggestionSignal.listFromJson(json['signals']),
        canMarkDone: json['can_mark_done'] == true,
        kind: json['kind'] == 'advice' ? 'advice' : 'action',
        question: (json['question'] as String?)?.trim().isEmpty ?? true ? null : (json['question'] as String).trim(),
        speech: (json['speech'] as String?)?.trim().isEmpty ?? true ? null : (json['speech'] as String).trim(),
        commands: [
          for (final c in (json['commands'] as List<dynamic>?) ?? const [])
            if (c is Map<String, dynamic>) KioskSuggestionCommand.fromJson(c),
        ],
      );
}

/// 카드를 띄운 신호 하나(서버 `signals[]`) — 예: '집에 계심', '최근 7일 중 5일'.
class KioskSuggestionSignal {
  const KioskSuggestionSignal({required this.label, this.ok = true});

  final String label;
  final bool ok;

  /// 서버가 준 목록 그대로(빈 이름은 버림). 화면은 앞에서 4개까지만 보인다.
  static List<KioskSuggestionSignal> listFromJson(Object? json) {
    if (json is! List) return const [];
    return [
      for (final item in json)
        if (item is Map && item['label'] is String && (item['label'] as String).trim().isNotEmpty)
          KioskSuggestionSignal(label: (item['label'] as String).trim(), ok: item['ok'] != false),
    ];
  }
}

/// 습관 카드의 '매일 이 시간에' 내용 — [auto]면 맡기기까지(낮은 위험 LG 가전), 아니면 매일 묻기 루틴(물리 누름).
class KioskAdoptOffer {
  const KioskAdoptOffer({required this.candidateKey, required this.askTime, required this.auto, this.evidence});

  final String candidateKey;
  final String askTime; // "HH:MM"
  final bool auto;
  final String? evidence;

  static KioskAdoptOffer? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final key = json['candidate_key'];
    final at = json['ask_time'];
    if (key is! String || at is! String) return null;
    return KioskAdoptOffer(
        candidateKey: key, askTime: at, auto: json['auto'] == true, evidence: json['evidence'] as String?);
  }
}

/// 카드의 '다음부터는 알아서' 내용 — 조건·동작·단서·지문(허락은 이 지문에 묶인다).
class KioskAutoRuleOffer {
  const KioskAutoRuleOffer(
      {required this.conditionText, required this.actionText, required this.caveat, required this.fingerprint});

  final String conditionText;
  final String actionText;
  final String caveat;
  final String fingerprint;

  static KioskAutoRuleOffer? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final fingerprint = json['fingerprint'];
    if (fingerprint is! String || fingerprint.isEmpty) return null;
    return KioskAutoRuleOffer(
      conditionText: json['condition_text'] as String? ?? '',
      actionText: json['action_text'] as String? ?? '',
      caveat: json['caveat'] as String? ?? '',
      fingerprint: fingerprint,
    );
  }
}

class KioskSuggestionCommand {
  const KioskSuggestionCommand({
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

  /// 서버가 만든 한 줄(어느 가전의 무엇을 어떻게). 승인에 묶이는 문장.
  final String summary;

  factory KioskSuggestionCommand.fromJson(Map<String, dynamic> json) =>
      KioskSuggestionCommand(
        targetId: json['target_id'] as String? ?? '',
        route: json['route'] as String? ?? 'physical',
        action: json['action'] as String?,
        buttons:
            (json['buttons'] as List<dynamic>?)?.cast<String>() ?? const [],
        summary: json['summary'] as String? ?? '',
      );
}

/// GET /readiness/{id} — 경로별 준비 상태.
class KioskReadiness {
  const KioskReadiness({
    required this.applianceId,
    required this.route,
    required this.canExecute,
    this.reasons = const [],
  });

  final String applianceId;
  final String route;
  final bool canExecute;
  final List<String> reasons;

  factory KioskReadiness.fromJson(Map<String, dynamic> json) => KioskReadiness(
        applianceId: json['appliance_id'] as String? ?? '',
        route: json['route'] as String? ?? 'physical',
        canExecute: json['can_execute'] as bool? ?? false,
        reasons:
            (json['reasons'] as List<dynamic>?)?.cast<String>() ?? const [],
      );
}

/// API 오류 — 상태 코드와 서버 문장(detail)을 남긴다.
class KioskApiException implements Exception {
  KioskApiException(this.statusCode, this.detail);

  final int statusCode;
  final String detail;

  /// 제안 승인 재검사 실패(409) — 승인한 내용이 바뀌었거나 승인이 만료·무효.
  /// '다른 작업 실행 중'(같은 409)과 가른다: 서버의 승인 오류 문장은 모두
  /// '승인'을 담는다(`rpi/commands/approval.py`).
  bool get isApprovalChanged => statusCode == 409 && detail.contains('승인');

  @override
  String toString() => 'kiosk api $statusCode: $detail';
}

class KioskButtonResult {
  const KioskButtonResult({required this.button, required this.success});
  final String button;
  final bool success;

  factory KioskButtonResult.fromJson(Map<String, dynamic> json) =>
      KioskButtonResult(
        button: json['button'] as String,
        success: json['success'] as bool,
      );
}

class KioskStatus {
  final String executionMode;
  final String lastExecutionMode;
  const KioskStatus({
    this.executionMode = 'unknown',
    this.lastExecutionMode = 'unknown',
    required this.running,
    this.lastStatus,
    this.lastButtons,
    this.currentButton,
    this.currentAttempt,
    this.completedSteps,
    this.verificationConfidence,
    this.verificationDetail,
    this.totalSteps,
    this.jobId,
    this.lastJobId,
    this.applianceId,
    this.lastApplianceId,
    this.lastOutcome,
    this.lastRoute,
    this.route,
    this.lastReceipt,
    this.lastConfirmation,
    this.lastDetail,
    this.lastRetryCount,
    this.lastOperationConfirmed,
    this.lastOperationSource,
    this.lastOperationDetail,
    this.lastAbortReason,
    this.lastAutoRun,
    this.developerMode = false,
    this.holdState,
    this.holdStopOutcome,
    this.holdDetail,
    this.holdApplianceId,
    this.holdStopButton,
    this.holdExecutionMode,
    this.estopLatched = false,
    this.estopDetail,
    this.lastStopLevel,
    this.lastStopAckMs,
    this.lastStopJobId,
    this.reportsStopJobId = false,
    this.finished,
    this.routineRunId,
    this.routineStatus,
    this.routineSegment,
    this.routineSegmentJobId,
    this.routineDetail,
  });

  final bool running;

  /// GET /jobs/{job_id}의 끝남(검토 10/19). /status·옛 본체는 null — 그때는 종전처럼 last_job_id 대조로 본다.
  final bool? finished;

  // ── 루틴 실행(GET /jobs의 첫 실행 번호, 검토 10/19) — 루틴 전체 수명. 루틴이 아니거나 옛 본체면 모두 null ──
  /// 루틴 실행 번호(`/routines/runs/{id}/stop`의 번호, 첫 구간 번호와 같다).
  final String? routineRunId;

  /// running | succeeded | failed | stopped | unconfirmed — 루틴 전체 상태.
  final String? routineStatus;

  /// 지금(끝났으면 마지막) 구간의 순번(1부터)과 그 구간의 실행 번호.
  final int? routineSegment;
  final String? routineSegmentJobId;

  /// 루틴 결과 한 줄(끝났을 때).
  final String? routineDetail;

  /// 마지막 긴급 정지의 확인 단계(2026-10-13): sent | mcu_ack | verified. 옛 서버·보고 없음은 null.
  final String? lastStopLevel;
  final int? lastStopAckMs;

  /// 그 정지가 멈춘 실행의 job_id(평가 2026-10-13 H1·M1). [reportsStopJobId]가 거짓이면 이 필드를 모르는 옛 서버다.
  final String? lastStopJobId;
  final bool reportsStopJobId;

  /// [jobId] 실행의 정지 단계만. 서버가 정지의 실행을 밝히면 같은 job일 때만, 옛 서버면 종전처럼.
  String? stopLevelOf(String jobId) =>
      !reportsStopJobId || lastStopJobId == jobId ? lastStopLevel : null;
  int? stopAckMsOf(String jobId) =>
      stopLevelOf(jobId) == null ? null : lastStopAckMs;

  /// 콘센트 모듈 비상정지 걸림(2026-10-05). 옛 서버·보고 수단 없는 실행기(null)는
  /// 걸리지 않은 것으로 본다 — 실행 거절은 어차피 서버가 한다.
  final bool estopLatched;

  /// 걸린 사유(서버 문장). 걸리지 않았으면 null.
  final String? estopDetail;

  /// 서버 개발자 모드(SIMPLELAY_DEV_MODE). 시연 흔적은 이 값이 참일 때만 보인다.
  final bool developerMode;

  // ── 정지 버튼 대기·보관(2026-09-30) — 판정은 RPi4가 하고 서버는 옮기기만 한다.
  /// hovering_stop | stopping | parking | parked | fault | released | null(대기 없음)
  final String? holdState;

  /// stopped(정지됨·전력 하강 확인) | requested_unconfirmed(정지 요청함·미확인) |
  /// drive_fault(구동부 이상으로 정지 버튼을 못 누름) | null
  final String? holdStopOutcome;

  /// 서버가 쓴 화면 문장.
  final String? holdDetail;
  final String? holdApplianceId;

  /// 정지 버튼 **라벨**(버튼 id가 아니다).
  final String? holdStopButton;

  /// 대기 보고의 실행 환경 mock | real | unknown.
  final String? holdExecutionMode;

  final String? lastStatus;

  /// success | failed | stopped | safety_stop | unconfirmed. 옛 서버는 null.
  final String? lastOutcome;

  /// physical | thinq. 옛 서버는 null.
  final String? lastRoute;

  /// 실행 중인 **지금 단계**의 경로 physical | thinq(서버 /status `route`). 실행 중이 아니거나 옛 서버면 null.
  /// 이어받은 실행을 LG 가전 화면으로 보일지 가르는 근거다(평가 10차 10/18, [isAdoptedThinqRun]).
  final String? route;

  /// accepted | unknown | not_dispatched
  final String? lastReceipt;

  /// none | reported | press_confirmed | state_confirmed | operation_confirmed
  final String? lastConfirmation;

  /// 서버가 쓴 한 줄(ThinQ 결과).
  final String? lastDetail;

  /// 마지막 물리 실행의 재시도 합. 버튼별 보고가 없으면 null(0이 아니다).
  final int? lastRetryCount;

  /// L3(가전 동작) 판정. 판정기가 없거나 판정하지 못했으면 null.
  final bool? lastOperationConfirmed;

  /// 판정 입력 real | mock. mock의 true는 실제 동작 근거가 아니다.
  final String? lastOperationSource;
  final String? lastOperationDetail;

  /// 모션 걸림·재시작·기한 초과·준비 안 됨으로 재시도 없이 멈춘 원인(서버 2026-10-14, 예: `motion_alarm: stall`).
  final String? lastAbortReason;

  /// 결과가 나온 마지막 자동 실행(서버 2026-10-14 `last_auto_run`). 옛 서버·없으면 null.
  final KioskAutoRun? lastAutoRun;
  final List<KioskButtonResult>? lastButtons;

  // 실행 중 진행 상황 — /status가 폴링될 때만 채워지고, 완료되면 서버가 비운다.
  final String? currentButton;
  final int? currentAttempt;
  final int? completedSteps;
  final double? verificationConfidence;
  final String? verificationDetail;

  // job 모델: 실행 중이면 jobId, 끝나면 lastJobId. totalSteps는 진행바용.
  final int? totalSteps;
  final String? jobId;
  final String? lastJobId;

  /// 이 실행이 **대상으로 삼은** 가전. jobId와 같은 규칙으로 옮겨간다.
  /// 화면이 지금 고른 가전으로 메우지 않게 하려고 서버가 말해준다.
  final String? applianceId;
  final String? lastApplianceId;

  factory KioskStatus.fromJson(Map<String, dynamic> json) => KioskStatus(
        executionMode: json['execution_mode'] as String? ?? 'unknown',
        lastExecutionMode: json['last_execution_mode'] as String? ?? 'unknown',
        running: json['running'] as bool? ?? false,
        lastStatus: json['last_status'] as String?,
        lastButtons: (json['last_buttons'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>()
            .map(KioskButtonResult.fromJson)
            .toList(),
        currentButton: json['current_button'] as String?,
        currentAttempt: (json['current_attempt'] as num?)?.toInt(),
        completedSteps: (json['completed_steps'] as num?)?.toInt(),
        verificationConfidence:
            (json['verification_confidence'] as num?)?.toDouble(),
        verificationDetail: json['verification_detail'] as String?,
        totalSteps: (json['total_steps'] as num?)?.toInt(),
        jobId: json['job_id'] as String?,
        lastJobId: json['last_job_id'] as String?,
        applianceId: json['appliance_id'] as String?,
        lastApplianceId: json['last_appliance_id'] as String?,
        lastOutcome: json['last_outcome'] as String?,
        lastRoute: json['last_route'] as String?,
        route: json['route'] as String?,
        lastReceipt: json['last_receipt'] as String?,
        lastConfirmation: json['last_confirmation'] as String?,
        lastDetail: json['last_detail'] as String?,
        lastRetryCount: (json['last_retry_count'] as num?)?.toInt(),
        lastOperationConfirmed: json['last_operation_confirmed'] as bool?,
        lastOperationSource: json['last_operation_source'] as String?,
        lastOperationDetail: json['last_operation_detail'] as String?,
        lastAbortReason: json['last_abort_reason'] as String?,
        lastAutoRun: KioskAutoRun.fromJson(json['last_auto_run']),
        developerMode: json['developer_mode'] as bool? ?? false,
        holdState: json['hold_state'] as String?,
        holdStopOutcome: json['hold_stop_outcome'] as String?,
        holdDetail: json['hold_detail'] as String?,
        holdApplianceId: json['hold_appliance_id'] as String?,
        holdStopButton: json['hold_stop_button'] as String?,
        holdExecutionMode: json['hold_execution_mode'] as String?,
        estopLatched: json['estop_latched'] == true,
        estopDetail: json['estop_latched'] == true && json['estop_detail'] is String
            ? json['estop_detail'] as String
            : null,
        lastStopLevel: json['last_stop_level'] as String?,
        lastStopAckMs: (json['last_stop_ack_ms'] as num?)?.toInt(),
        lastStopJobId: json['last_stop_job_id'] as String?,
        reportsStopJobId: json.containsKey('last_stop_job_id'),
        finished: json['finished'] as bool?,
        routineRunId: json['routine_run_id'] as String?,
        routineStatus: json['routine_status'] as String?,
        routineSegment: (json['routine_segment'] as num?)?.toInt(),
        routineSegmentJobId: json['routine_segment_job_id'] as String?,
        routineDetail: json['routine_detail'] as String?,
      );
}

/// `POST /routines/{id}/trigger` 결과 — 승인 루틴은 **카드**(실행은 카드 승인 뒤),
/// 알림 루틴은 알림 문장만 온다. 여기서 실행이 일어나는 경로는 없다.
class RoutineTriggerResult {
  const RoutineTriggerResult({this.suggestion, this.notice});

  final KioskSuggestion? suggestion;
  final String? notice;
}

// 실행 접수 응답(비동기 job 모델). 서버는 물리 실행을 기다리지 않고 즉시
// job_id를 돌려주며, 완료는 status() 폴링에서 lastJobId와 대조해 판정한다.
class KioskJobAccepted {
  const KioskJobAccepted({required this.jobId});
  final String jobId;

  factory KioskJobAccepted.fromJson(Map<String, dynamic> json) =>
      KioskJobAccepted(jobId: json['job_id'] as String);
}

/// 실행 접수 하나에 붙이는 요청 번호(본체 `client_request_id`, `[A-Za-z0-9_-]{1,64}`, 검토 10/19).
/// 같은 번호를 다시 보내도 본체는 한 번만 접수하고, 응답을 잃으면 [KioskApiService.jobByRequest]로 그 실행 번호를 찾는다.
String newKioskRequestId() {
  final rand = Random();
  final tail = List.generate(2, (_) => rand.nextInt(0x7fffffff).toRadixString(36)).join();
  return 'kiosk-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$tail';
}

/// 요청 번호로 찾은 결과(GET /jobs/by-request, 검토 10/19).
enum KioskRequestLookupKind {
  /// 본체가 이 요청을 접수했다 — [KioskRequestLookup.jobId]가 그 실행.
  found,

  /// 본체는 요청 번호 조회를 아는데 이 번호로 접수한 실행이 없다(아직 안 닿았거나 접수 실패).
  unknown,

  /// 옛 본체 — 이 조회 자체가 없다. 부른 쪽이 종전 방식으로 찾는다.
  unsupported,

  /// 통신 실패·해석 불가 — 아무것도 알지 못했다.
  failed,
}

class KioskRequestLookup {
  const KioskRequestLookup(this.kind, [this.jobId]);
  final KioskRequestLookupKind kind;
  final String? jobId;
}

/// 실행 번호 하나의 상태(GET /jobs/{job_id}, 검토 10/19). [status]는 /status와 같은 모양에 그 실행 것만 —
/// 비상정지·대기·자동 실행 같은 기기 전체 값은 비어 있다(/status에서 읽는다).
class KioskJobLookup {
  const KioskJobLookup.found(KioskStatus this.status) : unsupported = false;
  const KioskJobLookup.unknown()
      : status = null,
        unsupported = false;
  const KioskJobLookup.unsupported()
      : status = null,
        unsupported = true;

  /// 찾은 실행. null이면 본체가 이 실행을 모른다.
  final KioskStatus? status;

  /// 옛 본체(조회 없음)·통신 실패 — 부른 쪽이 /status의 마지막 한 건으로 종전처럼 본다.
  final bool unsupported;
}

/// 방 안 사람 감지 판단(GET /presence/room). [sleepScreen]이면 처음 화면을 어둡게 해도 된다.
class RoomPresenceInfo {
  const RoomPresenceInfo(
      {required this.state,
      required this.sleepScreen,
      this.arrivedAt,
      this.greeting,
      this.greetingWeather,
      this.cameraEnabled = true});
  final String state;
  final bool sleepScreen;
  final DateTime? arrivedAt;

  /// 돌아왔을 때 건넬 인사 한 줄(서버가 정한다 — 외출 뒤 저녁이면 하루 위로).
  final String? greeting;

  /// 인사 뒤에 이어 말할 날씨 한 줄(10/26 — '오늘 비 예보가 있어요. 우산 챙기세요'). 화면 인사 알약에는 넣지 않고 소리로만.
  final String? greetingWeather;

  /// 사용자가 카메라를 끈 동안은 false — 본체가 카메라를 열지 않는다.
  final bool cameraEnabled;
}

/// 휴대폰에서 알아들은 말의 확인 질문(GET /intent/proposals, 2026-10-26). 본체가 정한 닫힌 목록의 동작만 담는다.
/// 키오스크·폰 중 먼저 정한 쪽만 실행한다 — 본체는 정하기만 하고 실행하지 않는다.
class KioskIntentProposal {
  const KioskIntentProposal({
    required this.id,
    required this.question,
    required this.label,
    required this.kind,
    this.applianceId,
    this.buttons = const [],
    this.action,
    this.args = const {},
    this.routineId,
    this.fingerprint,
  });

  final String id, question, label, kind;
  final String? applianceId, action, routineId, fingerprint;
  final List<String> buttons;
  final Map<String, Object> args;

  static bool _identifier(Object? s) => s is String && s.isNotEmpty && s.length <= 64 && !s.contains('/');

  /// 모양이 맞지 않으면 null — 화면에 띄우지 않는다(모르는 동작을 지어내지 않는다).
  static KioskIntentProposal? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], question = raw['question'], label = raw['label'], action = raw['action'];
    if (!_identifier(id) || question is! String || question.trim().isEmpty || label is! String || action is! Map) {
      return null;
    }
    final kind = action['kind'];
    final aid = action['appliance_id'];
    final buttons = action['buttons'];
    final args = action['args'];
    if (kind == 'buttons' &&
        _identifier(aid) &&
        buttons is List &&
        buttons.isNotEmpty &&
        buttons.every((b) => b is String && b.trim().isNotEmpty)) {
      return KioskIntentProposal(
          id: id as String, question: question, label: label, kind: 'buttons',
          applianceId: aid as String, buttons: buttons.cast<String>());
    }
    if (kind == 'thinq' &&
        _identifier(aid) &&
        action['action'] is String &&
        args is Map &&
        args.isNotEmpty &&
        args.entries.every((e) => e.key is String && e.value is String)) {
      return KioskIntentProposal(
          id: id as String, question: question, label: label, kind: 'thinq',
          applianceId: aid as String, action: action['action'] as String,
          args: {for (final e in args.entries) e.key as String: e.value as Object});
    }
    if (kind == 'routine' &&
        _identifier(action['routine_id']) &&
        action['fingerprint'] is String &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(action['fingerprint'] as String)) {
      return KioskIntentProposal(
          id: id as String, question: question, label: label, kind: 'routine',
          routineId: action['routine_id'] as String, fingerprint: action['fingerprint'] as String);
    }
    // 모르는 종류 — 질문은 보이되 키오스크에서 보낼 길이 없다('휴대폰에서 정해 주세요').
    return KioskIntentProposal(id: id as String, question: question, label: label, kind: kind is String ? kind : '');
  }
}

class NodeInfo {
  const NodeInfo({required this.applianceId, required this.baseUrl});

  final String applianceId;
  final String baseUrl;

  factory NodeInfo.fromJson(Map<String, dynamic> json) => NodeInfo(
        applianceId: json['appliance_id'] as String,
        baseUrl: json['base_url'] as String,
      );
}

// RPi5에서 로컬로 도는 rpi/api FastAPI 서버(localhost:8000)를 호출한다.
class KioskApiService {
  KioskApiService({String? baseUrl})
      : _base = Uri.parse((baseUrl ??
                (kIsWeb ? Uri.base.origin : 'http://localhost:8000'))
            .replaceAll(RegExp(r'/$'), ''));

  final Uri _base;
  final _client = http.Client();
  static const _timeout = Duration(seconds: 4);
  // ThinQ 상태 조회·명령 접수는 클라우드를 거칠 수 있어 더 기다린다.
  static const _thinqTimeout = Duration(seconds: 12);

  static const _jsonHeaders = {'Content-Type': 'application/json'};

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

  Future<Map<String, dynamic>> pairingSession({bool create = false}) async {
    final uri = _base.replace(path: '/pair/session');
    final res = await (create ? _client.post(uri) : _client.get(uri)).timeout(_timeout);
    _ensureOk(res);
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> approvePairing(String requestId, bool approved) async {
    final res = await _client.post(_base.replace(path: '/pair/approve'),
      headers: _jsonHeaders,
      body: jsonEncode({'request_id': requestId, 'approved': approved})).timeout(_timeout);
    _ensureOk(res);
  }

  /// 사람이 확인한 실행(본체 GET /acks의 job_answers, 2026-10-19) — 키오스크·폰 어디서 확인했든. 실패·옛 본체면 null
  /// (지우지도 지어내지도 않는다 — 부른 쪽이 직전 값을 그대로 둔다).
  Future<Map<String, String>?> ackedJobs() async {
    try {
      final res = await _client.get(_base.replace(path: '/acks')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final answers = body is Map<String, dynamic> ? body['job_answers'] : null;
      if (answers is! Map) return null;
      return {for (final e in answers.entries) if (e.value is String) '${e.key}': e.value as String};
    } catch (_) {
      return null;
    }
  }

  /// 사람이 봤다·답했다를 본체에 적는다(POST /acks) — 폰 홈 못 한 일 경고·설정 탭 배지에서도 사라진다.
  /// [answer]: seen(지난 일 '확인') · moved · not_moved — 화면에 보인 그 실행 하나만(본체 `/acks` 계약, 검토 10/19).
  /// 맨 failures_seen은 보내지 않는다: 키오스크는 보호자 알림 목록을 보이지 않으므로 '못 한 일을 이 번호까지 봤다'고 댈 번호가 없다.
  /// 적지 못하면 false(키오스크 화면은 그래도 닫는다 — 다음 조회에서 다시 보일 수 있다).
  Future<bool> postAck({required String jobId, String answer = 'seen'}) async {
    try {
      final res = await _client
          .post(_base.replace(path: '/acks'),
              headers: _jsonHeaders,
              body: jsonEncode({'job_id': jobId, 'answer': answer}))
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<void> closePairing() async {
    final res = await _client.delete(_base.replace(path: '/pair/session')).timeout(_timeout);
    _ensureOk(res);
  }

  Future<HealthStatus> checkHealth() async {
    try {
      final res =
          // 공개 /health는 생존·버전만(2026-10-14 보안 점검) — 같은 기기 루프백이라 키 없이 상세를 받는다.
          await _client.get(_base.replace(path: '/health/detail')).timeout(_timeout);
      if (res.statusCode != 200) return HealthStatus.disconnected;
      return HealthStatus.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return HealthStatus.disconnected;
    }
  }

  Future<SensorData?> sensors() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/sensors')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      return SensorData.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<AlertState> alerts() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/alerts')).timeout(_timeout);
      if (res.statusCode != 200) return AlertState.inactive;
      return AlertState.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return AlertState.inactive;
    }
  }

  /// 돌려주는 값은 서버 `persisted`(2026-10-14 HIGH 재확인 M-R1): true 저장됨 · false 저장 실패(이번 세션만 적용 —
  /// 화면이 알린다) · null 저장소 없는 구성·옛 서버·해석 불가. 오류 응답(4xx·5xx)은 [KioskApiException] — 적용되지 않았다(검토 10/19 코어 6차).
  Future<bool?> setDnd(int minutes) async {
    final res = await _client
        .post(
          _base.replace(path: '/dnd'),
          body: jsonEncode({'duration_minutes': minutes}),
          headers: _jsonHeaders,
        )
        .timeout(_timeout);
    _ensureOk(res);
    return _persisted(res);
  }

  Future<bool?> clearDnd() async {
    final res = await _client.delete(_base.replace(path: '/dnd')).timeout(_timeout);
    _ensureOk(res);
    return _persisted(res);
  }

  static bool? _persisted(http.Response res) {
    if (res.statusCode != 200) return null;
    try {
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      return body is Map<String, dynamic> && body['persisted'] is bool ? body['persisted'] as bool : null;
    } catch (_) {
      return null;
    }
  }

  Future<LearningStatus> learningStatus() async {
    final res =
        await _client.get(_base.replace(path: '/learning')).timeout(_timeout);
    _ensureOk(res);
    // FastAPI는 charset 없이 JSON을 보낸다 — 한글(습관 이름·정리 문장)은 바이트를 UTF-8로 직접 푼다.
    return LearningStatus.fromJson(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  /// '알게 된 것'에서 습관 숨기기(POST /suppressions/mute) — 카드의 '다시 받지 않기'와 같다.
  Future<void> hideHabit(String purpose) => _suppression('mute', purpose);

  /// 숨긴 습관 다시 보이기(POST /suppressions/unmute).
  Future<void> unhideHabit(String purpose) => _suppression('unmute', purpose);

  Future<void> _suppression(String action, String purpose) async {
    final res = await _client
        .post(
          _base.replace(path: '/suppressions/$action'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'purpose': purpose}),
        )
        .timeout(_timeout);
    _ensureOk(res);
  }

  Future<List<KioskSuggestion>> suggestions() async {
    final res = await _client
        .get(_base.replace(path: '/suggestions'))
        .timeout(_timeout);
    // FastAPI는 charset 없이 JSON을 보낸다 — 바이트를 UTF-8로 직접 푼다.
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
    return body
        .cast<Map<String, dynamic>>()
        .map(KioskSuggestion.fromJson)
        .toList();
  }

  Future<KioskStatus> status() async {
    final res =
        await _client.get(_base.replace(path: '/status')).timeout(_timeout);
    return KioskStatus.fromJson(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  /// [clientRequestId]가 있으면 본체가 같은 번호를 한 번만 접수한다(검토 10/19). 옛 본체는 이 필드를 무시한다.
  Future<KioskJobAccepted> executeButtons(
    List<String> buttons, {
    String? applianceId,
    String? clientRequestId,
  }) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute-buttons'),
          body: jsonEncode({
            'buttons': buttons,
            if (applianceId != null) 'appliance_id': applianceId,
            if (clientRequestId != null) 'client_request_id': clientRequestId,
          }),
          headers: _jsonHeaders,
        )
        .timeout(_timeout);
    _ensureOk(res);
    return KioskJobAccepted.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// '이번에 하고 다음부터는 알아서'(approve-and-allow). 이번 실행 번호와 맡기기 저장 결과(실패면 서버 이유)를 돌려준다.
  Future<(KioskJobAccepted, String?)> approveAndAllowSuggestion(String id, String fingerprint,
      {String? clientRequestId}) async {
    final res = await _client
        .post(_base.replace(path: '/suggestions/$id/approve-and-allow'),
            headers: _jsonHeaders,
            body: jsonEncode({
              'offer_fingerprint': fingerprint,
              if (clientRequestId != null) 'client_request_id': clientRequestId,
            }))
        .timeout(_timeout);
    _ensureOk(res);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final allow = body['auto_allow'];
    final failed = allow is Map<String, dynamic> && allow['ok'] != true
        ? (allow['reason'] as String? ?? '다음부터 알아서 하기는 저장하지 못했어요')
        : null;
    return (KioskJobAccepted.fromJson(body), failed);
  }

  /// '이번에 하고, 매일 이 시간에'(approve-and-adopt). 이번 실행 번호와, 저장·맡기기가 안 됐으면 서버 이유.
  Future<(KioskJobAccepted, String?)> approveAndAdoptSuggestion(String id, String candidateKey) async {
    final res = await _client
        .post(_base.replace(path: '/suggestions/$id/approve-and-adopt'),
            headers: _jsonHeaders, body: jsonEncode({'candidate_key': candidateKey}))
        .timeout(_timeout);
    _ensureOk(res);
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    String? problem;
    for (final part in [body['adopt'], body['auto_allow']]) {
      if (part is Map<String, dynamic> && part['ok'] != true) {
        problem ??= part['reason'] as String? ?? '루틴으로 저장하지 못했어요';
      }
    }
    return (KioskJobAccepted.fromJson(body), problem);
  }

  Future<KioskJobAccepted> approveSuggestion(String id, {String? clientRequestId}) async {
    final res = await _client
        .post(_base.replace(path: '/suggestions/$id/approve'),
            headers: clientRequestId == null ? null : _jsonHeaders,
            body: clientRequestId == null ? null : jsonEncode({'client_request_id': clientRequestId}))
        .timeout(_timeout);
    _ensureOk(res);
    return KioskJobAccepted.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  /// GET /jobs/by-request/{id} — 응답을 잃은 접수의 실행 번호(검토 10/19). 본체는 접수 중이면 끝날 때까지 기다렸다 답한다.
  /// 404는 '모르는 번호'와 '옛 본체(조회 없음)' 둘 다다 — 형식이 틀린 번호로 한 번 더 물어 가른다(새 본체 422, 옛 본체 404).
  Future<KioskRequestLookup> jobByRequest(String clientRequestId) async {
    try {
      final res = await _client
          .get(_base.replace(path: '/jobs/by-request/$clientRequestId'))
          .timeout(_lookupTimeout);
      if (res.statusCode == 200) {
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        final job = body is Map<String, dynamic> ? body['job_id'] : null;
        return job is String
            ? KioskRequestLookup(KioskRequestLookupKind.found, job)
            : const KioskRequestLookup(KioskRequestLookupKind.failed);
      }
      if (res.statusCode != 404) return const KioskRequestLookup(KioskRequestLookupKind.failed);
      final probe = await _client.get(_base.replace(path: '/jobs/by-request/!')).timeout(_timeout);
      return switch (probe.statusCode) {
        422 => const KioskRequestLookup(KioskRequestLookupKind.unknown),
        404 => const KioskRequestLookup(KioskRequestLookupKind.unsupported),
        _ => const KioskRequestLookup(KioskRequestLookupKind.failed),
      };
    } catch (_) {
      return const KioskRequestLookup(KioskRequestLookupKind.failed);
    }
  }

  /// 본체가 접수 중인 요청을 기다렸다 답하는 몫까지(본체 상한 30초보다 짧게 — 그동안 다른 조회가 오래 멈추지 않게).
  static const _lookupTimeout = Duration(seconds: 12);

  /// GET /jobs/{job_id} — 이 실행 하나의 진행·결과(검토 10/19). /status는 마지막 한 건만 보여 그사이 다른 실행이 끝나면
  /// 내 결과를 잃었다. 본체가 '모르는 실행'이라고 답하면 [KioskJobLookup.unknown], 옛 본체(경로 없음 'Not Found')·실패는
  /// [KioskJobLookup.unsupported] — 그때는 /status로 종전처럼 본다.
  Future<KioskJobLookup> jobStatus(String jobId) async {
    try {
      final res = await _client.get(_base.replace(path: '/jobs/$jobId')).timeout(_timeout);
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (res.statusCode == 200 && body is Map<String, dynamic>) {
        return KioskJobLookup.found(KioskStatus.fromJson(body));
      }
      if (res.statusCode == 404 && body is Map<String, dynamic> && body['detail'] == 'job not found') {
        return const KioskJobLookup.unknown();
      }
      return const KioskJobLookup.unsupported();
    } catch (_) {
      return const KioskJobLookup.unsupported();
    }
  }

  /// 옛 본체가 `client_request_id`를 모르는 필드로 거절했나(422 extra_forbidden, 그 필드 위치). 다른 422는 아니다.
  static bool _refusedRequestIdField(http.Response res) {
    if (res.statusCode != 422) return false;
    try {
      final detail = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['detail'];
      return detail is List &&
          detail.any((e) =>
              e is Map && e['type'] == 'extra_forbidden' && e['loc'] is List && (e['loc'] as List).contains('client_request_id'));
    } catch (_) {
      return false;
    }
  }

  // 에러 응답({"detail": ...})을 접수 성공으로 오파싱하지 않도록 명시 확인 —
  // 409(이미 실행 중) 등이 조용히 삼켜져 실행 화면에 고착되는 것을 막는다.
  static void _ensureOk(http.Response res) {
    if (res.statusCode >= 400) {
      String detail;
      try {
        detail = utf8.decode(res.bodyBytes);
      } catch (_) {
        detail = res.body;
      }
      try {
        final d = (jsonDecode(detail) as Map<String, dynamic>)['detail'];
        if (d is String) detail = d;
      } catch (_) {}
      throw KioskApiException(res.statusCode, detail);
    }
  }

  /// GET /readiness/{id}. 조회 실패는 null — 모름은 막지 않는다(서버가 실행 직전에
  /// 다시 검사해 412로 거절한다).
  Future<KioskReadiness?> readiness(String applianceId) async {
    try {
      final res = await _client
          .get(_base.replace(path: '/readiness/$applianceId'))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      return KioskReadiness.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// GET /scenarios/last-run — 마지막 실행의 단계별 결과(G4). 기록이 없거나
  /// 옛 서버·조회 실패면 null — 화면은 아무것도 새로 말하지 않는다.
  Future<ScenarioRun?> scenarioLastRun() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/scenarios/last-run'))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      return ScenarioRun.fromLastRunJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// GET /scenarios — ID → 이름. 실패·옛 서버는 빈 맵.
  Future<Map<String, String>> scenarioNames() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/scenarios')).timeout(_timeout);
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

  /// GET /thinq/power — 서버가 최근 조회로 **켜져 있다고 본** ThinQ 가전 ID(2026-10-16, 가전 줄 '켜짐').
  /// 서버는 기억만 돌려준다(ThinQ 클라우드를 새로 부르지 않는다). 실패·옛 서버·꺼짐·모름은 빈 집합.
  Future<Set<String>> thinqPowerOn() async {
    _powerOff = const {};
    try {
      final res =
          await _client.get(_base.replace(path: '/thinq/power')).timeout(_timeout);
      if (res.statusCode != 200) return const {};
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      final list = body is Map<String, dynamic> ? body['appliances'] : null;
      if (list is! List) return const {};
      final entries = list.whereType<Map<String, dynamic>>().where((e) => e['appliance_id'] is String);
      _powerOff = {
        for (final e in entries)
          if (e['power'] == 'off') e['appliance_id'] as String,
      };
      return {
        for (final e in entries)
          if (e['power'] == 'on') e['appliance_id'] as String,
      };
    } catch (_) {
      return const {};
    }
  }

  Set<String> _powerOff = const {};

  /// 마지막 [thinqPowerOn] 조회에서 서버가 **꺼져 있다고 본** ThinQ 가전 ID(평가 10차 10/18 — 꺼진 공기청정기 타일이
  /// '준비됐어요'로 보였다, 폰은 '꺼져 있어요'). 같은 응답의 `power == 'off'`만 — 모름·실패는 빈 집합.
  Set<String> get thinqPowerOff => _powerOff;

  /// GET /routines/next — 가장 가까운 시각 루틴 하나(평소 화면 '다음 루틴'). 없거나 실패·옛 서버면 null.
  Future<KioskNextRun?> nextRoutine() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/routines/next', queryParameters: {'limit': '1'}))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! List || body.isEmpty || body.first is! Map<String, dynamic>) return null;
      return KioskNextRun.fromJson(body.first as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// GET /routines/next — 가까운 시각 루틴 여러 회차('자동 실행' 탭, 시안 B 10/24). 읽기만 한다.
  /// 실패·옛 서버면 null(화면은 '불러오지 못했어요'), 없으면 빈 목록. 이상한 항목은 그 하나만 뺀다.
  Future<List<KioskNextRun>?> nextRoutines({int limit = 10}) async {
    try {
      final res = await _client
          .get(_base.replace(path: '/routines/next', queryParameters: {'limit': '$limit'}))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! List) return null;
      return [
        for (final item in body)
          if (item is Map<String, dynamic>)
            if (KioskNextRun.fromJson(item) case final run?) run,
      ];
    } catch (_) {
      return null;
    }
  }

  /// GET /history — 최근 실행 기록('기록' 탭, 시안 B 10/24, 폰 기록 화면과 같은 경로). 읽기만 한다.
  /// 실패·옛 서버면 null, 없으면 빈 목록. 이상한 항목은 그 하나만 뺀다.
  Future<List<KioskHistoryEntry>?> history({int limit = 20}) async {
    try {
      final res = await _client
          .get(_base.replace(path: '/history', queryParameters: {'limit': '$limit'}))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! List) return null;
      return [
        for (final item in body)
          if (item is Map<String, dynamic>)
            if (KioskHistoryEntry.fromJson(item) case final entry?) entry,
      ];
    } catch (_) {
      return null;
    }
  }

  /// POST /routines/next/skip·unskip — 다음 루틴 그 회차만 한 번 건너뛰기·되돌리기(2026-10-18, 서버 f37d82e5).
  /// 본문은 `/routines/next` 항목의 `routine_id`·`at` 그대로. 던지지 않는다 — 200이면 바뀐 항목, 409·404·422면 서버의
  /// 한국어 `detail`(화면에 그대로 보인다), 그 밖의 실패는 짧은 안내. 409·404면 [KioskSkipResult.reload]로 다시 불러온다.
  Future<KioskSkipResult> setNextRoutineSkip(KioskNextRun next, {required bool skip}) async {
    try {
      final res = await _client
          .post(_base.replace(path: '/routines/next/${skip ? 'skip' : 'unskip'}'),
              headers: _jsonHeaders, body: jsonEncode({'routine_id': next.routineId, 'at': next.at}))
          .timeout(_timeout);
      Object? body;
      try {
        body = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        body = null;
      }
      if (res.statusCode == 200 && body is Map<String, dynamic>) {
        final item = KioskNextRun.fromJson(body);
        if (item != null) return KioskSkipResult(item: item);
        return const KioskSkipResult(message: KioskSkipResult.failed, reload: true);
      }
      final detail = body is Map<String, dynamic> && body['detail'] is String ? body['detail'] as String : null;
      final known = const {404, 409, 422}.contains(res.statusCode);
      return KioskSkipResult(
        message: known && detail != null && detail.isNotEmpty ? detail : KioskSkipResult.failed,
        reload: res.statusCode == 409 || res.statusCode == 404,
      );
    } catch (_) {
      return const KioskSkipResult(message: KioskSkipResult.unreachable);
    }
  }

  /// GET /thinq/air — 서버가 최근 조회로 아는 공기청정기 센서 공기질(2026-10-16, 평소 화면 '실내 공기' 한 줄).
  /// 서버는 기억만 돌려준다(ThinQ 클라우드를 새로 부르지 않는다). 등급을 모르거나 오래됐거나 실패·옛 서버면 null.
  Future<KioskAirReading?> thinqAir() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/thinq/air')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! Map<String, dynamic>) return null;
      final list = body['appliances'];
      if (list is! List) return null;
      final mock = body['execution_mode'] == 'mock';
      for (final e in list.whereType<Map<String, dynamic>>()) {
        final reading = KioskAirReading.fromJson(e, mock: mock);
        if (reading != null) return reading;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// GET /thinq/status/{id} — **ThinQ를 실제로 한 번 부른다**(가전 상세를 열 때·'다시 읽기'에서만).
  /// 실패해도 던지지 않고 이유를 담는다(값을 지어내지 않는다).
  Future<KioskThinqStatus> thinqStatus(String applianceId) async {
    try {
      final res = await _client
          .get(_base.replace(path: '/thinq/status/$applianceId'))
          .timeout(_thinqTimeout);
      if (res.statusCode != 200) {
        String detail = '';
        try {
          final d = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['detail'];
          if (d is String) detail = d;
        } catch (_) {}
        return KioskThinqStatus(
            failure: detail.isNotEmpty ? detail : '잠시 뒤 다시 봐 주세요.');
      }
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return KioskThinqStatus(
        state: body['state'],
        executionMode: body['execution_mode'] as String?,
        readAt: DateTime.now(),
      );
    } on TimeoutException {
      return const KioskThinqStatus(failure: '응답이 늦어요. 가전과 인터넷 연결을 봐 주세요');
    } catch (_) {
      return const KioskThinqStatus(failure: '본체에 연결되지 않았어요');
    }
  }

  /// POST /thinq/command — 키오스크에서 확인을 거친 ThinQ 조작 1건 → job_id(폰과 같은 경로).
  /// 거절(4xx·5xx)은 [KioskApiException], 시간 초과·끊김은 그 예외 그대로 던진다.
  /// [clientRequestId]를 실으면 같은 번호로 다시 보내도 본체가 한 번만 접수하고, 응답을 잃으면 [jobByRequest]로 찾는다(검토 10/19).
  /// 옛 본체는 모르는 필드를 422로 거절한다(접수 없음) — 그때만 번호 없이 한 번 다시 보낸다.
  Future<KioskJobAccepted> thinqCommand(String applianceId, String action, Map<String, Object> args,
      {String? clientRequestId}) async {
    Future<http.Response> post(String? requestId) => _client
        .post(
          _base.replace(path: '/thinq/command'),
          body: jsonEncode({
            'appliance_id': applianceId,
            'action': action,
            'args': args,
            if (requestId != null) 'client_request_id': requestId,
          }),
          headers: _jsonHeaders,
        )
        .timeout(_thinqTimeout);
    var res = await post(clientRequestId);
    if (clientRequestId != null && _refusedRequestIdField(res)) res = await post(null);
    _ensureOk(res);
    return KioskJobAccepted.fromJson(
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
  }

  /// [reason]은 '이미 했어요'일 때만 `already_done`(서버가 오늘은 다시 묻지 않음). '아니요'는 보내지 않는다.
  Future<void> rejectSuggestion(String id, {bool mute = false, String? reason}) async {
    final res = await _client
        .post(
          _base.replace(path: '/suggestions/$id/reject'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'mute': mute, if (reason != null) 'reason': reason}),
        )
        .timeout(_timeout);
    // 이미 만료/처리된 카드는 넘긴 것과 같다. 그 외 실패는 UI에 전달한다.
    if (res.statusCode != 404) _ensureOk(res);
  }

  Future<void> snoozeSuggestion(String id) async {
    final res = await _client.post(
      _base.replace(path: '/suggestions/$id/snooze'),
    ).timeout(_timeout);
    _ensureOk(res);
  }

  Future<Map<String, List<String>>> revisionOptions(String id) async {
    final res = await _client.get(_base.replace(path: '/suggestions/$id/revision-options')).timeout(_timeout);
    _ensureOk(res);
    final options = jsonDecode(res.body)['options'] as Map<String, dynamic>;
    return options.map((key, value) => MapEntry(key, (value as List).cast<String>()));
  }

  Future<KioskSuggestion> reviseSuggestion(String id, String purpose) async {
    final res = await _client.post(_base.replace(path: '/suggestions/$id/revise'),
      headers: {'Content-Type': 'application/json'}, body: jsonEncode({'purpose': purpose}),
    ).timeout(_timeout);
    _ensureOk(res);
    return KioskSuggestion.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// POST /routines/runs/{run_id}/stop — 그 루틴 실행만 멈춘다(남은 구간을 보내지 않고, 지금 누르는 중이면 본체가 긴급 정지도
  /// 보낸다, 검토 10/19). 진행 중인 루틴이 아니면 409, 경로가 없는 옛 본체는 404·405([KioskApiException]) — 부르는 쪽이 /stop으로 갈음한다.
  Future<void> stopRoutineRun(String runId) async {
    final res = await _client
        .post(_base.replace(path: '/routines/runs/${Uri.encodeComponent(runId)}/stop'))
        .timeout(_timeout);
    _ensureOk(res);
  }

  /// POST /stop. 4xx·5xx도 [KioskApiException]으로 던진다 — 본체가 거절한 정지를 '보냈어요'로 보이지 않게(검토 10/19).
  Future<void> stop() async {
    final res = await _client.post(_base.replace(path: '/stop')).timeout(_timeout);
    _ensureOk(res);
  }

  /// POST /stop/ack — 사람이 확인한 비상정지 해제 요청(2026-10-05).
  ///
  /// **사용자가 경고 안의 확인 문장에서 '해제'를 누른 뒤에만** 부른다. 예외를
  /// 던지지 않고 결과 종류로 돌려준다 — 화면은 실패해도 경고를 남기고 이유를 보인다.
  Future<EstopAckResult> ackEstop() async {
    try {
      final res = await _client
          .post(_base.replace(path: '/stop/ack'))
          .timeout(_timeout);
      _ensureOk(res);
      return EstopAckResult.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } on KioskApiException catch (e) {
      return EstopAckResult.fromStatusCode(e.statusCode, detail: e.detail);
    } catch (_) {
      return const EstopAckResult(EstopAckOutcome.failed);
    }
  }

  /// GET /appliances — 서버가 가진 가전 목록(내장 + 폰에서 등록한 커스텀).
  ///
  /// **실패는 null, 성공한 빈 목록은 []** (백로그 B11). 실패를 빈 목록으로
  /// 표현하면 "서버에 가전이 0대"와 "서버에 못 닿음"이 섞여서, 마지막
  /// 가전을 삭제했는데도 키오스크에 이전 조작판이 남는다. null이면 호출부가
  /// 기존 목록을 유지한다(오프라인 우선).
  Future<List<ApplianceMap>?> listAppliances() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/appliances'))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as List<dynamic>;
      final result = <ApplianceMap>[];
      for (final item in body) {
        try {
          result.add(applianceFromServerJson(item as Map<String, dynamic>));
        } catch (_) {
          // 항목 하나가 이상해도 나머지 가전은 계속 쓸 수 있어야 한다
        }
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<List<NodeInfo>> listNodes() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/nodes')).timeout(_timeout);
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body) as List<dynamic>;
      return body.cast<Map<String, dynamic>>().map(NodeInfo.fromJson).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<bool> registerNode(String applianceId, String baseUrl) async {
    try {
      final res = await _client
          .post(
            _base.replace(path: '/nodes/$applianceId'),
            body: jsonEncode({'base_url': baseUrl}),
            headers: _jsonHeaders,
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> unregisterNode(String applianceId) async {
    try {
      final res = await _client
          .delete(_base.replace(path: '/nodes/$applianceId'))
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// GET /presence/room — 방 안 사람 감지(온디바이스 카메라, 2026-10-25). 감지기가 없거나 실패·옛 서버면 null(절전 없음).
  Future<RoomPresenceInfo?> roomPresence() async => (await roomReading()).$1;

  /// GET /presence/room 한 번으로 사람 감지와 방 밝기(10/26 — 'dark'·'light'·'unknown')를 함께 읽는다.
  /// 사람 감지가 꺼져 있어도 밝기는 따로 올 수 있다. 실패·옛 서버면 (null, 'unknown').
  Future<(RoomPresenceInfo?, String)> roomReading() async {
    try {
      final res = await _client.get(_base.replace(path: '/presence/room')).timeout(_timeout);
      if (res.statusCode != 200) return (null, 'unknown');
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final lightRaw = body['light'];
      final lightState = lightRaw is Map ? lightRaw['state'] : null;
      final light = lightState == 'dark' || lightState == 'light' ? lightState as String : 'unknown';
      if (body['enabled'] != true) return (null, light);
      return (RoomPresenceInfo(
        state: body['state'] as String? ?? 'unknown',
        sleepScreen: body['sleep_screen'] == true,
        arrivedAt: DateTime.tryParse(body['arrived_at'] as String? ?? ''),
        greeting: body['greeting'] as String?,
        greetingWeather: body['greeting_weather'] as String?,
        cameraEnabled: body['camera_enabled'] != false,
      ), light);
    } catch (_) {
      return (null, 'unknown');
    }
  }

  /// GET /intent/proposals — 휴대폰에서 말해 아직 정하지 않은 확인 질문(60초). 실패·옛 서버(404)면 빈 목록.
  Future<List<KioskIntentProposal>> intentProposals() async {
    try {
      final res = await _client.get(_base.replace(path: '/intent/proposals')).timeout(_timeout);
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(utf8.decode(res.bodyBytes));
      if (body is! List) return const [];
      return body.map(KioskIntentProposal.tryParse).whereType<KioskIntentProposal>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// POST /intent/proposals/{id}/resolve — 먼저 정한 쪽만 된다. 폰이 먼저 정했거나 시간이 지났으면 409([KioskApiException]).
  /// 본체는 실행하지 않는다 — '네'를 이긴 키오스크가 기존 실행 경로로 보낸다.
  Future<void> resolveIntentProposal(String id, {required bool yes}) async {
    final res = await _client
        .post(_base.replace(path: '/intent/proposals/$id/resolve'),
            body: jsonEncode({'result': yes ? 'yes' : 'no'}), headers: _jsonHeaders)
        .timeout(_timeout);
    _ensureOk(res);
  }

  /// POST /presence/room/camera — 사람 감지 카메라 켜기·끄기(2026-10-25). 바뀐 판단, 실패면 null.
  Future<RoomPresenceInfo?> setRoomCamera(bool enabled) async {
    try {
      final res = await _client
          .post(_base.replace(path: '/presence/room/camera'),
              headers: {'Content-Type': 'application/json'}, body: jsonEncode({'enabled': enabled}))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      return roomPresence();
    } catch (_) {
      return null;
    }
  }

  /// GET /ambient — 인사말·안내 한 줄·예보 4칸. 실패·옛 서버는 null(화면이 인사말만).
  Future<AmbientInfo?> ambient() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/ambient')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      return AmbientInfo.fromJson(
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// GET /connections — 와이파이·누름 장치·플러그. 실패는 null(허브에 못 닿음).
  Future<List<ConnectionItem>?> connections() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/connections'))
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      return [
        for (final item in (body['items'] as List<dynamic>?) ?? const [])
          if (item is Map<String, dynamic>) ConnectionItem.fromJson(item),
      ];
    } catch (_) {
      return null;
    }
  }

  /// GET /routines — 사용자 루틴. 실패·옛 서버는 null(마지막으로 안 목록 유지).
  Future<List<KioskRoutine>?> routines() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/routines')).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      final result = <KioskRoutine>[];
      for (final item in body) {
        try {
          result.add(KioskRoutine.fromJson(item as Map<String, dynamic>));
        } catch (_) {
          // 한 항목이 이상해도 나머지 루틴은 보인다
        }
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  /// POST /routines/{id}/trigger — 카드 만들기(승인 루틴) 또는 알림(알림 루틴).
  /// 실행하지 않는다. 실패는 [KioskApiException](서버 문장 그대로).
  Future<RoutineTriggerResult> triggerRoutine(String id) async {
    final res = await _client
        .post(_base.replace(path: '/routines/$id/trigger'))
        .timeout(_timeout);
    _ensureOk(res);
    final body =
        jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (body['kind'] == 'suggestion' &&
        body['suggestion'] is Map<String, dynamic>) {
      return RoutineTriggerResult(
          suggestion: KioskSuggestion.fromJson(
              body['suggestion'] as Map<String, dynamic>));
    }
    final notice = body['notice'];
    return RoutineTriggerResult(
        notice: notice is Map<String, dynamic>
            ? notice['detail'] as String? ?? ''
            : '');
  }

  void dispose() => _client.close();
}
