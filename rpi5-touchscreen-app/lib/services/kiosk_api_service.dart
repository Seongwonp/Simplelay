import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

import '../models/appliance.dart';
import '../models/learning_status.dart';

class HealthStatus {
  const HealthStatus({
    required this.ok,
    this.actuatorReady = true,
    this.dndUntil,
  });

  final bool ok;
  final bool actuatorReady;
  final DateTime? dndUntil;

  static const disconnected = HealthStatus(ok: false, actuatorReady: false);

  factory HealthStatus.fromJson(Map<String, dynamic> json) => HealthStatus(
        ok: json['ok'] as bool? ?? false,
        actuatorReady: json['actuator_ready'] as bool? ?? true,
        dndUntil: json['dnd_until'] == null
            ? null
            : DateTime.parse(json['dnd_until'] as String),
      );
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
  });

  final bool isDemo;

  /// 시나리오 제안이면 그 ID. 옛 서버·일반 제안은 null.
  final String? scenarioId;

  /// 승인에 **고정되는** 명령들(대상·경로·동작). 비어 있지 않으면 시나리오 카드다 --
  /// ThinQ 가전은 키오스크 조작판 목록(/appliances)에 없으므로 대상 확인을
  /// 조작판이 아니라 이 명령과 서버 준비 상태로 한다.
  final List<KioskSuggestionCommand> commands;

  bool get isScenario => commands.isNotEmpty;
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
    // 폰과 같은 규칙 -- '최근'은 쓰지 않는다. 서버 집계에 기간 창이
    // 없어서, 화면이 범위를 실제보다 좁게 말하게 된다.
    return '$timeBand 시간에 $occurrences번 하셨어요.';
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
        commands: [
          for (final c in (json['commands'] as List<dynamic>?) ?? const [])
            if (c is Map<String, dynamic>) KioskSuggestionCommand.fromJson(c),
        ],
      );
}

/// 시나리오 카드의 확정 명령 하나(서버 `commands[]`).
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
    this.lastReceipt,
    this.lastConfirmation,
    this.lastDetail,
    this.lastRetryCount,
    this.lastOperationConfirmed,
    this.lastOperationSource,
    this.lastOperationDetail,
  });

  final bool running;
  final String? lastStatus;

  /// success | failed | stopped | safety_stop | unconfirmed. 옛 서버는 null.
  final String? lastOutcome;

  /// physical | thinq. 옛 서버는 null.
  final String? lastRoute;

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
        lastReceipt: json['last_receipt'] as String?,
        lastConfirmation: json['last_confirmation'] as String?,
        lastDetail: json['last_detail'] as String?,
        lastRetryCount: (json['last_retry_count'] as num?)?.toInt(),
        lastOperationConfirmed: json['last_operation_confirmed'] as bool?,
        lastOperationSource: json['last_operation_source'] as String?,
        lastOperationDetail: json['last_operation_detail'] as String?,
      );
}

// 실행 접수 응답(비동기 job 모델). 서버는 물리 실행을 기다리지 않고 즉시
// job_id를 돌려주며, 완료는 status() 폴링에서 lastJobId와 대조해 판정한다.
class KioskJobAccepted {
  const KioskJobAccepted({required this.jobId});
  final String jobId;

  factory KioskJobAccepted.fromJson(Map<String, dynamic> json) =>
      KioskJobAccepted(jobId: json['job_id'] as String);
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

  Future<HealthStatus> checkHealth() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/health')).timeout(_timeout);
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

  Future<void> setDnd(int minutes) async {
    await _client
        .post(
          _base.replace(path: '/dnd'),
          body: jsonEncode({'duration_minutes': minutes}),
          headers: _jsonHeaders,
        )
        .timeout(_timeout);
  }

  Future<void> clearDnd() async {
    await _client.delete(_base.replace(path: '/dnd')).timeout(_timeout);
  }

  Future<LearningStatus> learningStatus() async {
    final res =
        await _client.get(_base.replace(path: '/learning')).timeout(_timeout);
    _ensureOk(res);
    return LearningStatus.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
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

  Future<KioskJobAccepted> executeButtons(
    List<String> buttons, {
    String? applianceId,
  }) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute-buttons'),
          body: jsonEncode({
            'buttons': buttons,
            if (applianceId != null) 'appliance_id': applianceId,
          }),
          headers: _jsonHeaders,
        )
        .timeout(_timeout);
    _ensureOk(res);
    return KioskJobAccepted.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<KioskJobAccepted> approveSuggestion(String id) async {
    final res = await _client
        .post(_base.replace(path: '/suggestions/$id/approve'))
        .timeout(_timeout);
    _ensureOk(res);
    return KioskJobAccepted.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
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

  Future<void> rejectSuggestion(String id, {bool mute = false}) async {
    final res = await _client
        .post(
          _base.replace(path: '/suggestions/$id/reject'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'mute': mute}),
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

  Future<void> stop() async {
    await _client.post(_base.replace(path: '/stop')).timeout(_timeout);
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

  void dispose() => _client.close();
}
