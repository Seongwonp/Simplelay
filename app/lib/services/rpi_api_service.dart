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

class RpiApiService {
  RpiApiService(String baseUrl, {http.Client? client})
      : _base = Uri.parse(baseUrl.replaceAll(RegExp(r'/$'), '')),
        _client = client ?? http.Client();

  final Uri _base;
  final http.Client _client;

  static const _timeout = Duration(seconds: 8);

  // GET /health — 연결 확인용
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

  // POST /execute
  Future<RpiExecuteResult> execute(String text, {String source = 'voice'}) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'text': text, 'source': source}),
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
  Future<RpiExecuteResult> executeButtons(List<String> buttons) async {
    final res = await _client
        .post(
          _base.replace(path: '/execute-buttons'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'buttons': buttons}),
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
