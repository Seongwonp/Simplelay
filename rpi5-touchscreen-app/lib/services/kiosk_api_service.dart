import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

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
