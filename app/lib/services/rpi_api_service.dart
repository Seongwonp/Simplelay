import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/appliance.dart';

class RpiApiException implements Exception {
  RpiApiException(this.statusCode, this.message);
  final int statusCode;
  final String message;

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
  const RpiJobAccepted({required this.jobId});
  final String jobId;

  factory RpiJobAccepted.fromJson(Map<String, dynamic> json) =>
      RpiJobAccepted(jobId: json['job_id'] as String);
}

class RpiStatusResult {
  const RpiStatusResult({
    required this.running,
    this.lastStatus,
    this.lastButtons,
    this.currentButton,
    this.currentAttempt,
    this.completedSteps,
    this.totalSteps,
    this.jobId,
    this.lastJobId,
  });
  final bool running;
  final String? lastStatus;
  final List<RpiButtonStep>? lastButtons;
  // 실행 중 실시간 진행 (running=true일 때만 값이 있을 수 있음)
  final String? currentButton;
  final int? currentAttempt;
  final int? completedSteps;
  final int? totalSteps;
  // job 모델: 실행 중이면 jobId, 끝나면 lastJobId에 값이 있다
  final String? jobId;
  final String? lastJobId;
}

class RpiSuggestion {
  const RpiSuggestion({
    required this.id,
    required this.purpose,
    required this.timeBand,
    required this.occurrences,
    this.steps = const [],
    this.reason = '',
  });
  final String id;
  final String purpose;
  final String timeBand;
  final int occurrences;

  // 환경 기반 제안 등의 "왜 지금" 근거(예: "지금 30°C · 습도 72% — 더워요").
  final String reason;

  // 승인 시 실행될 버튼 시퀀스 미리보기(라벨 문자열). 해석 실패 시 서버가 빈 리스트를 준다.
  final List<String> steps;

  factory RpiSuggestion.fromJson(Map<String, dynamic> json) => RpiSuggestion(
        id: json['id'] as String,
        purpose: json['purpose'] as String,
        timeBand: json['time_band'] as String,
        occurrences: json['occurrences'] as int,
        steps: (json['steps'] as List<dynamic>?)?.cast<String>() ?? const [],
        reason: json['reason'] as String? ?? '',
      );
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
class RpiHistoryEntry {
  const RpiHistoryEntry({
    required this.jobId,
    required this.finishedAt,
    required this.status,
    required this.retryCount,
    required this.buttons,
    this.purpose,
  });
  final String jobId;
  final DateTime finishedAt;
  final String? purpose; // 버튼 직접 실행(수동 조작)은 null
  final String status; // succeeded | safety_stopped | failed
  final int retryCount;
  final List<RpiHistoryButton> buttons;

  /// 목록 표시용 제목 — 목적이 없으면 누른 버튼 라벨을 나열
  String get displayTitle =>
      purpose ?? buttons.map((b) => b.button).join(' · ');

  factory RpiHistoryEntry.fromJson(Map<String, dynamic> json) =>
      RpiHistoryEntry(
        jobId: json['job_id'] as String,
        finishedAt: DateTime.parse(json['finished_at'] as String).toLocal(),
        purpose: json['purpose'] as String?,
        status: json['status'] as String,
        retryCount: (json['retry_count'] as num).toInt(),
        buttons: (json['buttons'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(RpiHistoryButton.fromJson)
            .toList(),
      );
}

class SensorReading {
  const SensorReading({this.temperature, this.humidity});
  final double? temperature;
  final double? humidity;

  factory SensorReading.fromJson(Map<String, dynamic> json) => SensorReading(
        temperature: (json['temperature'] as num?)?.toDouble(),
        humidity: (json['humidity'] as num?)?.toDouble(),
      );
}

class RpiHealthData {
  const RpiHealthData({
    required this.ok,
    required this.actuatorReady,
    this.dndUntil,
  });
  final bool ok;
  final bool actuatorReady;
  final DateTime? dndUntil;

  factory RpiHealthData.fromJson(Map<String, dynamic> json) => RpiHealthData(
        ok: json['ok'] as bool? ?? false,
        actuatorReady: json['actuator_ready'] as bool? ?? false,
        dndUntil: json['dnd_until'] == null
            ? null
            : DateTime.tryParse(json['dnd_until'] as String),
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

class RpiApiService {
  RpiApiService(String baseUrl, {http.Client? client, String? apiKey})
      : _base = Uri.parse(baseUrl.replaceAll(RegExp(r'/$'), '')),
        _client = client ?? http.Client(),
        _apiKey = (apiKey == null || apiKey.trim().isEmpty)
            ? null
            : apiKey.trim();

  final Uri _base;
  final http.Client _client;

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
  Future<bool> ping() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/health'), headers: _headers)
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<RpiHealthData?> health() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/health'), headers: _headers)
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

  // POST /dnd — DND 설정 (minutes: 30, 60, 120)
  Future<void> setDnd(int minutes) async {
    final res = await _client
        .post(
          _base.replace(path: '/dnd'),
          headers: _jsonHeaders,
          body: jsonEncode({'duration_minutes': minutes}),
        )
        .timeout(_timeout);
    _checkStatus(res);
  }

  // DELETE /dnd — DND 해제
  Future<void> clearDnd() async {
    final res = await _client
        .delete(_base.replace(path: '/dnd'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
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
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final rawButtons = body['last_buttons'] as List<dynamic>?;
    return RpiStatusResult(
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
      jobId: body['job_id'] as String?,
      lastJobId: body['last_job_id'] as String?,
    );
  }

  // POST /stop
  Future<void> stop() async {
    final res = await _client
        .post(_base.replace(path: '/stop'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
  }

  // GET /suggestions
  Future<List<RpiSuggestion>> suggestions() async {
    final res = await _client
        .get(_base.replace(path: '/suggestions'), headers: _headers)
        .timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(res.body) as List<dynamic>;
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
    final body = jsonDecode(res.body) as List<dynamic>;
    return body
        .cast<Map<String, dynamic>>()
        .map(RpiHistoryEntry.fromJson)
        .toList();
  }

  // GET /nodes — 등록된 ESP32 노드 목록
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
              'name': appliance.name,
              'icon': appliance.isCustom ? 'custom' : appliance.id,
              'rows': appliance.rows,
              'cols': appliance.cols,
              'buttons': [
                for (final b in appliance.buttons)
                  {'id': b.id, 'label': b.label, 'x': b.x, 'y': b.y},
              ],
            }),
          )
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // DELETE /appliances/{id} — 서버 목록에서도 제거
  Future<bool> deleteAppliance(String applianceId) async {
    try {
      final res = await _client
          .delete(
            _base.replace(path: '/appliances/$applianceId'),
            headers: _headers,
          )
          .timeout(_timeout);
      return res.statusCode == 200 || res.statusCode == 404;
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

  void _checkStatus(http.Response res) {
    if (res.statusCode >= 400) {
      String detail = res.body;
      try {
        detail = (jsonDecode(res.body) as Map<String, dynamic>)['detail']
                as String? ??
            res.body;
      } catch (_) {}
      throw RpiApiException(res.statusCode, detail);
    }
  }

  void dispose() => _client.close();
}
