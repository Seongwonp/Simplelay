import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// 개발자 API 호출 실패.
///
/// [code]는 서버 `detail.code` 그대로다(`session_expired`·`stopping`·`fault`
/// 등). 화면은 code로 분기하고, 사람에게 보일 문장은 따로 정한다 -- 서버
/// 문구를 잘라 쓰면 문구가 바뀔 때 조용히 깨진다. 서버에 닿지 않은 경우는
/// statusCode 0, code `network`다.
class DevApiException implements Exception {
  DevApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  bool get isNetwork => statusCode == 0;

  @override
  String toString() => 'DevApiException($statusCode, $code): $message';
}

class DevSessionInfo {
  const DevSessionInfo({
    required this.sessionId,
    required this.applianceId,
    required this.nodeId,
  });

  final String sessionId;
  final String applianceId;
  final String nodeId;

  factory DevSessionInfo.fromJson(Map<String, dynamic> json) => DevSessionInfo(
        sessionId: json['session_id'] as String,
        applianceId: json['appliance_id'] as String,
        nodeId: json['node_id'] as String,
      );
}

/// 서버가 말하는 개발자 제어 국면. 비밀값은 여기 오지 않는다.
class DevState {
  const DevState({
    required this.phase,
    required this.mock,
    required this.shuttingDown,
    required this.heartbeatTtlS,
    required this.maxJogMm,
    this.session,
    this.faultReason,
  });

  /// idle · active · stopping · fault · execution_busy
  final String phase;

  /// false면 모의 서버가 아니다 -- 이 앱은 그 서버를 조작하지 않는다.
  final bool mock;
  final bool shuttingDown;
  final double heartbeatTtlS;
  final double maxJogMm;
  final DevSessionInfo? session;
  final String? faultReason;

  factory DevState.fromJson(Map<String, dynamic> json) => DevState(
        phase: json['phase'] as String,
        // 필드가 없으면 모의라고 믿지 않는다.
        mock: json['mock'] == true,
        shuttingDown: json['shutting_down'] == true,
        heartbeatTtlS: (json['heartbeat_ttl_s'] as num?)?.toDouble() ?? 2.0,
        maxJogMm: (json['max_jog_mm'] as num?)?.toDouble() ?? 0,
        session: json['session'] == null
            ? null
            : DevSessionInfo.fromJson(json['session'] as Map<String, dynamic>),
        faultReason: json['fault_reason'] as String?,
      );
}

class DevSessionStart {
  const DevSessionStart({
    required this.sessionId,
    required this.sessionSecret,
    required this.state,
  });

  final String sessionId;

  /// 이 세션을 쓰는 유일한 열쇠. 서버는 다시 알려주지 않는다 -- 기기에
  /// 저장하지 않고 화면이 살아 있는 동안만 쥔다.
  final String sessionSecret;
  final DevState state;
}

class DevCommandResult {
  const DevCommandResult({
    required this.requestId,
    required this.state,
    this.normalized,
    this.sensor,
  });

  final String requestId;
  final String? normalized;
  final Map<String, double>? sensor;
  final DevState state;
}

/// 정지·세션 종료 결과. [confirmed]가 false면 **정지되지 않았을 수 있다.**
class DevStopResult {
  const DevStopResult({
    required this.confirmed,
    required this.message,
    required this.state,
  });

  final bool confirmed;
  final String message;
  final DevState state;
}

class DevLogLine {
  const DevLogLine({
    required this.at,
    required this.event,
    required this.detail,
    this.requestId,
  });

  final DateTime at;
  final String event;
  final String detail;
  final String? requestId;

  factory DevLogLine.fromJson(Map<String, dynamic> json) => DevLogLine(
        at: DateTime.parse(json['at'] as String).toLocal(),
        event: json['event'] as String,
        detail: json['detail'] as String,
        requestId: json['request_id'] as String?,
      );
}

/// `/dev/*` 클라이언트. 일반 조작(`RpiApiService`)과 분리한 이유: 권한이
/// 다르다(개발자 토큰). 한 서비스에 섞으면 일반 화면의 요청에도 개발자
/// 토큰이 실리게 된다.
class DevApiService {
  DevApiService(
    String baseUrl, {
    required String devToken,
    http.Client? client,
    String? apiKey,
  })  : _base = Uri.parse(baseUrl.replaceAll(RegExp(r'/$'), '')),
        _devToken = devToken,
        _apiKey =
            (apiKey == null || apiKey.trim().isEmpty) ? null : apiKey.trim(),
        _ownsClient = client == null,
        _client = client ?? http.Client();

  final Uri _base;
  final String _devToken;
  final String? _apiKey;
  final bool _ownsClient;
  final http.Client _client;

  // 일반 호출 기한. heartbeat는 별도로 TTL의 1/3 이내에 확인한다.
  static const _timeout = Duration(seconds: 5);

  void dispose() {
    if (_ownsClient) _client.close();
  }

  Map<String, String> _headers({String? secret, bool json = false}) => {
        'X-Dev-Token': _devToken,
        if (_apiKey != null) 'X-API-Key': _apiKey,
        if (secret != null) 'X-Dev-Session-Secret': secret,
        if (json) 'Content-Type': 'application/json',
      };

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? secret,
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    final uri = _base.replace(path: path, queryParameters: query);
    final http.Response res;
    try {
      res = await (method == 'GET'
              ? _client.get(uri, headers: _headers(secret: secret))
              : _client.post(
                  uri,
                  headers: _headers(secret: secret, json: body != null),
                  body: body == null ? null : jsonEncode(body),
                ))
          .timeout(timeout ?? _timeout);
    } catch (_) {
      throw DevApiException(0, 'network', '서버 응답을 확인하지 못했어요');
    }
    final text = utf8.decode(res.bodyBytes);
    dynamic decoded;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return decoded;
    final detail = decoded is Map<String, dynamic> ? decoded['detail'] : null;
    if (detail is Map<String, dynamic>) {
      throw DevApiException(
        res.statusCode,
        detail['code'] as String? ?? 'http_${res.statusCode}',
        detail['message'] as String? ?? '요청이 거절됐어요',
      );
    }
    throw DevApiException(
      res.statusCode,
      'http_${res.statusCode}',
      detail?.toString() ?? '요청이 거절됐어요',
    );
  }

  Future<DevState> state() async => DevState.fromJson(
      await _send('GET', '/dev/state') as Map<String, dynamic>);

  Future<DevSessionStart> start(String applianceId,
      {required String nodeId}) async {
    final json = await _send(
      'POST',
      '/dev/sessions',
      body: {'appliance_id': applianceId, 'node_id': nodeId},
    ) as Map<String, dynamic>;
    return DevSessionStart(
      sessionId: json['session_id'] as String,
      sessionSecret: json['session_secret'] as String,
      state: DevState.fromJson(json['state'] as Map<String, dynamic>),
    );
  }

  Future<DevState> heartbeat(String sessionId, String secret,
          {double ttlS = 2}) async =>
      DevState.fromJson(
        await _send('POST', '/dev/sessions/$sessionId/heartbeat',
            secret: secret,
            timeout: Duration(
                microseconds:
                    ((ttlS.isFinite && ttlS > 0 ? ttlS : 2) * 1000000 / 3)
                        .round()
                        .clamp(1, 1000000))) as Map<String, dynamic>,
      );

  Future<DevCommandResult> command(
    String sessionId,
    String secret, {
    required String applianceId,
    required String text,
    String? requestId,
  }) async {
    final json = await _send(
      'POST',
      '/dev/sessions/$sessionId/commands',
      secret: secret,
      body: {
        'appliance_id': applianceId,
        'text': text,
        if (requestId != null) 'request_id': requestId,
      },
    ) as Map<String, dynamic>;
    final sensor = json['sensor'] as Map<String, dynamic>?;
    return DevCommandResult(
      requestId: json['request_id'] as String,
      normalized: json['normalized'] as String?,
      sensor: sensor?.map((k, v) => MapEntry(k, (v as num).toDouble())),
      state: DevState.fromJson(json['state'] as Map<String, dynamic>),
    );
  }

  Future<DevStopResult> end(String sessionId, String secret) async =>
      _stopResult(
          await _send('POST', '/dev/sessions/$sessionId/end', secret: secret));

  Future<DevStopResult> stop() async =>
      _stopResult(await _send('POST', '/dev/stop'));

  Future<List<DevLogLine>> log({int limit = 20}) async {
    final list = await _send('GET', '/dev/log', query: {'limit': '$limit'})
        as List<dynamic>;
    return [
      for (final e in list) DevLogLine.fromJson(e as Map<String, dynamic>)
    ];
  }

  DevStopResult _stopResult(dynamic raw) {
    final json = raw as Map<String, dynamic>;
    return DevStopResult(
      confirmed: json['confirmed'] == true,
      message: json['message'] as String? ?? '',
      state: DevState.fromJson(json['state'] as Map<String, dynamic>),
    );
  }
}
