import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'kiosk_api_service.dart';

/// SSE 이벤트 1건.
class SseEvent {
  const SseEvent(this.name, this.data);
  final String name;
  final Map<String, dynamic> data;
}

/// SSE 라인 파서 — 스트림에서 한 줄씩 받아 이벤트를 조립한다.
/// 순수 로직으로 분리해 네트워크 없이 단위 테스트한다.
class SseLineParser {
  String? _pendingEvent;

  SseEvent? feed(String line) {
    if (line.startsWith('event: ')) {
      _pendingEvent = line.substring('event: '.length);
      return null;
    }
    if (line.startsWith('data: ') && _pendingEvent != null) {
      final name = _pendingEvent!;
      _pendingEvent = null;
      try {
        final data = jsonDecode(line.substring('data: '.length));
        if (data is Map<String, dynamic>) return SseEvent(name, data);
      } catch (_) {
        // 손상된 이벤트는 버리고 다음 이벤트로
      }
      return null;
    }
    if (line.isEmpty) _pendingEvent = null; // 이벤트 경계(빈 줄)
    return null; // keepalive 주석(':') 포함 — 무시
  }
}

/// GET /events SSE 구독 — 위험 경보를 폴링(3초) 지연 없이 즉시 받는다.
///
/// 폴링의 대체가 아니라 상위 채널: 스트림이 끊겨도 키오스크는 기존 폴링으로
/// 계속 동작하고, 이 클래스는 백오프(1→15초)로 조용히 재접속을 시도한다.
class KioskEventStream {
  KioskEventStream({String baseUrl = 'http://localhost:8000'})
      : _base = baseUrl.replaceAll(RegExp(r'/$'), '');

  final String _base;
  bool _running = false;
  http.Client? _client;

  void start({
    required void Function(AlertState alert) onAlert,
    void Function()? onStatusChanged,
  }) {
    if (_running) return;
    _running = true;
    _loop(onAlert, onStatusChanged);
  }

  Future<void> _loop(
    void Function(AlertState) onAlert,
    void Function()? onStatusChanged,
  ) async {
    var backoffSeconds = 1;
    while (_running) {
      final client = http.Client();
      _client = client;
      try {
        final request = http.Request('GET', Uri.parse('$_base/events'));
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw http.ClientException('events ${response.statusCode}');
        }
        backoffSeconds = 1; // 연결 성공 — 백오프 리셋
        final parser = SseLineParser();
        await for (final line in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (!_running) return;
          final event = parser.feed(line);
          if (event == null) continue;
          if (event.name == 'alert') {
            onAlert(AlertState.fromJson(event.data));
          } else if (event.name == 'status') {
            // 상세는 기존 /status 경로가 이미 다루므로, 즉시 폴링 트리거만
            onStatusChanged?.call();
          }
        }
      } catch (_) {
        // 서버 미기동·네트워크 단절 — 폴링이 커버하는 동안 조용히 재시도
      } finally {
        client.close();
      }
      if (!_running) return;
      await Future<void>.delayed(Duration(seconds: backoffSeconds));
      backoffSeconds = (backoffSeconds * 2).clamp(1, 15);
    }
  }

  void stop() {
    _running = false;
    _client?.close();
  }
}
