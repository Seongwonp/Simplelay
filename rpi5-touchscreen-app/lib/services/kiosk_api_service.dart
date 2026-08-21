import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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
  const SensorData({this.temperature, this.humidity});

  final double? temperature;
  final double? humidity;

  factory SensorData.fromJson(Map<String, dynamic> json) => SensorData(
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
    required this.id,
    required this.purpose,
    required this.occurrences,
    this.steps = const [],
  });

  final String id;
  final String purpose;
  final int occurrences;

  // 승인 시 실행될 버튼 시퀀스 미리보기 — 실제 버튼 라벨 문자열(예: "해동")로 온다.
  // 미리보기 해석이 실패하면 서버가 빈 리스트를 준다.
  final List<String> steps;

  factory KioskSuggestion.fromJson(Map<String, dynamic> json) =>
      KioskSuggestion(
        id: json['id'] as String,
        purpose: json['purpose'] as String,
        occurrences: (json['occurrences'] as num?)?.toInt() ?? 1,
        steps: (json['steps'] as List<dynamic>?)?.cast<String>() ?? const [],
      );
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
  const KioskStatus({
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
  });

  final bool running;
  final String? lastStatus;
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

  factory KioskStatus.fromJson(Map<String, dynamic> json) => KioskStatus(
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
  KioskApiService({String baseUrl = 'http://localhost:8000'})
      : _base = Uri.parse(baseUrl.replaceAll(RegExp(r'/$'), ''));

  final Uri _base;
  final _client = http.Client();
  static const _timeout = Duration(seconds: 4);

  static const _jsonHeaders = {'Content-Type': 'application/json'};

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

  Future<List<KioskSuggestion>> suggestions() async {
    final res = await _client
        .get(_base.replace(path: '/suggestions'))
        .timeout(_timeout);
    final body = jsonDecode(res.body) as List<dynamic>;
    return body
        .cast<Map<String, dynamic>>()
        .map(KioskSuggestion.fromJson)
        .toList();
  }

  Future<KioskStatus> status() async {
    final res =
        await _client.get(_base.replace(path: '/status')).timeout(_timeout);
    return KioskStatus.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
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
      throw Exception('kiosk api ${res.statusCode}: ${res.body}');
    }
  }

  Future<void> rejectSuggestion(String id) async {
    await _client
        .post(_base.replace(path: '/suggestions/$id/reject'))
        .timeout(_timeout);
  }

  Future<void> stop() async {
    await _client.post(_base.replace(path: '/stop')).timeout(_timeout);
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
