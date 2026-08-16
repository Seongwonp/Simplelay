import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class KioskSuggestion {
  const KioskSuggestion({
    required this.id,
    required this.purpose,
    required this.occurrences,
  });

  final String id;
  final String purpose;
  final int occurrences;

  factory KioskSuggestion.fromJson(Map<String, dynamic> json) =>
      KioskSuggestion(
        id: json['id'] as String,
        purpose: json['purpose'] as String,
        occurrences: (json['occurrences'] as num?)?.toInt() ?? 1,
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
    this.currentMa,
    this.soundDb,
  });

  final bool running;
  final String? lastStatus;
  final List<KioskButtonResult>? lastButtons;
  final double? currentMa;
  final double? soundDb;

  factory KioskStatus.fromJson(Map<String, dynamic> json) => KioskStatus(
        running: json['running'] as bool? ?? false,
        lastStatus: json['last_status'] as String?,
        lastButtons: (json['last_buttons'] as List<dynamic>?)
            ?.cast<Map<String, dynamic>>()
            .map(KioskButtonResult.fromJson)
            .toList(),
        currentMa: (json['current_ma'] as num?)?.toDouble(),
        soundDb: (json['sound_db'] as num?)?.toDouble(),
      );
}

class KioskExecuteResult {
  const KioskExecuteResult({required this.status, required this.buttons});
  final String status;
  final List<KioskButtonResult> buttons;

  factory KioskExecuteResult.fromJson(Map<String, dynamic> json) =>
      KioskExecuteResult(
        status: json['status'] as String,
        buttons: (json['buttons'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(KioskButtonResult.fromJson)
            .toList(),
      );
}

// RPi5에서 로컬로 도는 rpi/api FastAPI 서버(localhost:8000)를 호출한다.
// 원래 rpi/touchscreen/index.html의 raw fetch() 호출과 동일한 엔드포인트를 쓴다.
class KioskApiService {
  KioskApiService({String baseUrl = 'http://localhost:8000'})
      : _base = Uri.parse(baseUrl.replaceAll(RegExp(r'/$'), ''));

  final Uri _base;
  final _client = http.Client();
  static const _timeout = Duration(seconds: 4);

  Future<bool> checkHealth() async {
    try {
      final res =
          await _client.get(_base.replace(path: '/health')).timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
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

  Future<KioskExecuteResult> approveSuggestion(String id) async {
    final res = await _client
        .post(_base.replace(path: '/suggestions/$id/approve'))
        .timeout(_timeout);
    return KioskExecuteResult.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  Future<void> rejectSuggestion(String id) async {
    await _client
        .post(_base.replace(path: '/suggestions/$id/reject'))
        .timeout(_timeout);
  }

  Future<void> stop() async {
    await _client.post(_base.replace(path: '/stop')).timeout(_timeout);
  }

  void dispose() => _client.close();
}
