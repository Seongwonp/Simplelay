import 'dart:convert';

import 'package:http/http.dart' as http;

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

class RpiStatusResult {
  const RpiStatusResult({
    required this.running,
    this.lastStatus,
    this.lastButtons,
  });
  final bool running;
  final String? lastStatus;
  final List<RpiButtonStep>? lastButtons;
}

class RpiSuggestion {
  const RpiSuggestion({
    required this.id,
    required this.purpose,
    required this.timeBand,
    required this.occurrences,
    this.steps = const [],
  });
  final String id;
  final String purpose;
  final String timeBand;
  final int occurrences;

  // 승인 시 실행될 버튼 시퀀스 미리보기(라벨 문자열). 해석 실패 시 서버가 빈 리스트를 준다.
  final List<String> steps;

  factory RpiSuggestion.fromJson(Map<String, dynamic> json) => RpiSuggestion(
        id: json['id'] as String,
        purpose: json['purpose'] as String,
        timeBand: json['time_band'] as String,
        occurrences: json['occurrences'] as int,
        steps: (json['steps'] as List<dynamic>?)?.cast<String>() ?? const [],
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
  RpiApiService(String baseUrl, {http.Client? client})
      : _base = Uri.parse(baseUrl.replaceAll(RegExp(r'/$'), '')),
        _client = client ?? http.Client();

  final Uri _base;
  final http.Client _client;

  static const _timeout = Duration(seconds: 8);

  // GET /health — 연결 확인 + DND 상태 + actuator 상태
  Future<bool> ping() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/health'))
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<RpiHealthData?> health() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/health'))
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
          .get(_base.replace(path: '/sensors'))
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
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'duration_minutes': minutes}),
        )
        .timeout(_timeout);
    _checkStatus(res);
  }

  // DELETE /dnd — DND 해제
  Future<void> clearDnd() async {
    final res = await _client
        .delete(_base.replace(path: '/dnd'))
        .timeout(_timeout);
    _checkStatus(res);
  }

  // POST /execute
  Future<RpiExecuteResult> execute(
    String text, {
    String source = 'voice',
    String? applianceId,
  }) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'text': text,
            'source': source,
            if (applianceId != null) 'appliance_id': applianceId,
          }),
        )
        .timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return RpiExecuteResult(
      status: body['status'] as String,
      buttons: (body['buttons'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(RpiButtonStep.fromJson)
          .toList(),
    );
  }

  // POST /execute-buttons — 의도 해석 우회, 사용자 정의 가전의 수동 버튼 실행용
  Future<RpiExecuteResult> executeButtons(
    List<String> buttons, {
    String? applianceId,
  }) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute-buttons'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'buttons': buttons,
            if (applianceId != null) 'appliance_id': applianceId,
          }),
        )
        .timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return RpiExecuteResult(
      status: body['status'] as String,
      buttons: (body['buttons'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(RpiButtonStep.fromJson)
          .toList(),
    );
  }

  // POST /execute-for-appliance — 사용자 정의 가전용 음성 명령. 서버 고정 규칙이
  // 아니라 이 가전의 실제 버튼 라벨 어휘를 넘겨서 LLM이 그 안에서만 해석하게 한다.
  // LLM이 서버에 설정 안 돼 있으면 503(RpiApiException)으로 실패한다.
  Future<RpiExecuteResult> executeForAppliance(
    String text,
    List<String> knownButtons, {
    String? applianceId,
  }) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute-for-appliance'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'text': text,
            'known_buttons': knownButtons,
            if (applianceId != null) 'appliance_id': applianceId,
          }),
        )
        .timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return RpiExecuteResult(
      status: body['status'] as String,
      buttons: (body['buttons'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(RpiButtonStep.fromJson)
          .toList(),
    );
  }

  // GET /status
  Future<RpiStatusResult> status() async {
    final res =
        await _client.get(_base.replace(path: '/status')).timeout(_timeout);
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
    );
  }

  // POST /stop
  Future<void> stop() async {
    final res = await _client
        .post(_base.replace(path: '/stop'))
        .timeout(_timeout);
    _checkStatus(res);
  }

  // GET /suggestions
  Future<List<RpiSuggestion>> suggestions() async {
    final res = await _client
        .get(_base.replace(path: '/suggestions'))
        .timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(res.body) as List<dynamic>;
    return body
        .cast<Map<String, dynamic>>()
        .map(RpiSuggestion.fromJson)
        .toList();
  }

  // POST /suggestions/{id}/approve
  Future<RpiExecuteResult> approveSuggestion(String id) async {
    final res = await _client
        .post(_base.replace(path: '/suggestions/$id/approve'))
        .timeout(_timeout);
    _checkStatus(res);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return RpiExecuteResult(
      status: body['status'] as String,
      buttons: (body['buttons'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(RpiButtonStep.fromJson)
          .toList(),
    );
  }

  // POST /suggestions/{id}/reject
  Future<void> rejectSuggestion(String id) async {
    final res = await _client
        .post(_base.replace(path: '/suggestions/$id/reject'))
        .timeout(_timeout);
    _checkStatus(res);
  }

  // GET /nodes — 등록된 ESP32 노드 목록
  Future<List<RpiNodeInfo>> listNodes() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/nodes'))
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

  // POST /nodes/{id} — ESP32 노드 등록 (이미 있으면 덮어씀)
  Future<bool> registerNode(String applianceId, String baseUrl) async {
    try {
      final res = await _client
          .post(
            _base.replace(path: '/nodes/$applianceId'),
            headers: {'Content-Type': 'application/json'},
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
          .delete(_base.replace(path: '/nodes/$applianceId'))
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
