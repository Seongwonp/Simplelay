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
    this.verificationConfidence,
    this.verificationDetail,
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
  // 폐루프 검증 근거 -- 버튼이 눌렸는지 센서로 확인한 결과.
  // 이 제품의 차별점이라 화면까지 도달해야 한다.
  final double? verificationConfidence;
  final String? verificationDetail;
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
    this.applianceId,
  });
  final String id;
  final String purpose;
  final String timeBand;
  final int occurrences;

  // 환경 기반 제안 등의 "왜 지금" 근거(예: "지금 30°C · 습도 72% — 더워요").
  final String reason;

  /// 이 제안이 조작할 가전. 서버가 모르면 null -- 그때만 현재 선택 가전을 쓴다.
  final String? applianceId;

  // 승인 시 실행될 버튼 시퀀스 미리보기(라벨 문자열). 해석 실패 시 서버가 빈 리스트를 준다.
  final List<String> steps;

  factory RpiSuggestion.fromJson(Map<String, dynamic> json) => RpiSuggestion(
        id: json['id'] as String,
        purpose: json['purpose'] as String,
        timeBand: json['time_band'] as String,
        occurrences: json['occurrences'] as int,
        steps: (json['steps'] as List<dynamic>?)?.cast<String>() ?? const [],
        reason: json['reason'] as String? ?? '',
        applianceId: json['appliance_id'] as String?,
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
/// 보호자 알림 한 건 — 실패·위험소리·긴급정지·안부 신호.
/// message는 서버가 사용자 언어로 완성해 보낸다.
class RpiCareEvent {
  const RpiCareEvent({
    required this.id,
    required this.kind,
    required this.message,
    required this.occurredAt,
    this.purpose,
  });
  final int id;
  final String kind; // execution_failed | emergency_stop | danger_sound | quiet_routine
  final String message;
  final String? purpose;
  final DateTime occurredAt;

  factory RpiCareEvent.fromJson(Map<String, dynamic> json) => RpiCareEvent(
        id: json['id'] as int,
        kind: json['kind'] as String,
        message: json['message'] as String,
        purpose: json['purpose'] as String?,
        occurredAt: DateTime.parse(json['occurred_at'] as String).toLocal(),
      );
}

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
      verificationConfidence:
          (body['verification_confidence'] as num?)?.toDouble(),
      verificationDetail: body['verification_detail'] as String?,
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

  // ── 안부 확인 일시 중지 (F5) ────────────────────────────────────────
  //
  // 제안 DND(분 단위)와 다른 것이다. 이건 "며칠간 조용한 게 정상이다"이고,
  // 쉬는 동안에도 실행 실패·위험소리 알림은 그대로 간다.

  /// 쉬고 있으면 종료 날짜, 아니면 null. 조회 실패도 null이다 — 호출부가
  /// 그 구분을 필요로 하지 않는다(화면은 서버가 답할 때만 상태를 바꾼다).
  /// 쉬는 중이면 종료 날짜, 아니면 null.
  ///
  /// **쉬는 중인지는 서버의 `paused`로 판단한다.** 날짜만 보고
  /// 추측하면 이미 끝난 일시 중지의 지난 날짜를 받았을 때 화면이
  /// "7월 23일까지 쉬어요"라고 말하는데 서버는 이미 안부 신호를 다시
  /// 보내고 있는 상태가 된다.
  Future<DateTime?> wellnessPause() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/wellness-pause'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['paused'] != true) return null;
      final until = body['until'] as String?;
      return until == null ? null : DateTime.tryParse(until);
    } catch (_) {
      return null;
    }
  }

  /// 성공하면 서버가 확정한 종료 날짜, 실패하면 null.
  ///
  /// 서버가 상한(90일)과 지난 날짜를 거절한다 -- 날짜 선택기의 제한은
  /// 편의일 뿐, 규칙 자체는 서버에 있다.
  Future<DateTime?> setWellnessPause(DateTime until) async {
    try {
      final res = await _client
          .post(
            _base.replace(path: '/wellness-pause'),
            headers: _jsonHeaders,
            body: jsonEncode({
              'until': until.toIso8601String().split('T').first,
            }),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final saved = body['until'] as String?;
      return saved == null ? null : DateTime.tryParse(saved);
    } catch (_) {
      return null;
    }
  }

  Future<bool> clearWellnessPause() async {
    try {
      final res = await _client
          .delete(_base.replace(path: '/wellness-pause'), headers: _headers)
          .timeout(_timeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
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
  /// GET /care-events — 보호자 알림함(최신순).
  ///
  /// 실패는 null — 빈 목록과 구분해야 한다: 일시적 통신 실패를 "알림 0건"
  /// 으로 표현하면 보고 있던 알림이 사라지고 배지도 꺼져, 보호자가
  /// "해결됐나 보다"라고 오해한다 (교차 리뷰 #13).
  Future<List<RpiCareEvent>?> careEvents({int limit = 50}) async {
    try {
      final res = await _client
          .get(
            _base.replace(
              path: '/care-events',
              queryParameters: {'limit': '$limit'},
            ),
            headers: _headers,
          )
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body =
          jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return body
          .cast<Map<String, dynamic>>()
          .map(RpiCareEvent.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

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

  /// GET /appliances의 커스텀 가전 **정의 전체**.
  ///
  /// 동기화가 서버에만 있는 가전을 **내려받아 병합**하는 데 쓴다. 예전에는
  /// id만 받아서 "이 폰에 없으면 유령"으로 보고 지웠는데, 폰이 둘이면 그건
  /// 다른 폰의 등록이었다 -- 서버에만 있다는 것은 "지워도 된다"가 아니라
  /// "이 폰이 아직 못 받았다"는 뜻이다.
  ///
  /// 조회 실패는 **null**이다. 빈 목록으로 뭉개면 "서버에 아무것도 없다"로
  /// 읽혀 병합·삭제 판단이 통째로 뒤집힌다.
  Future<List<ApplianceMap>?> customAppliances() async {
    try {
      final res = await _client
          .get(_base.replace(path: '/appliances'), headers: _headers)
          .timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
      return [
        for (final item in body.cast<Map<String, dynamic>>())
          if (item['is_custom'] == true) ApplianceMap.fromJson(item),
      ];
    } catch (_) {
      return null;
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
              // "내가 본 판은 이거였다". 모르면(0) 밝히지 않는다 --
              // 최초 등록과 기기 저장분의 경로다.
              if (appliance.revision > 0)
                'expected_revision': appliance.revision,
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
      if (res.statusCode == 409) {
        // 다른 기기가 먼저 바꿨다. false로 뭉개면 호출부가 통신 실패로
        // 보고 계속 재시도한다 -- 같은 충돌이 영원히 반복된다.
        throw RpiApiException(409, _detailOf(res));
      }
      return res.statusCode == 200;
    } on RpiApiException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  String _detailOf(http.Response res) {
    try {
      return (jsonDecode(res.body) as Map<String, dynamic>)['detail']
              as String? ??
          res.body;
    } catch (_) {
      return res.body;
    }
  }

  // DELETE /appliances/{id} — 서버 목록에서도 제거
  Future<bool> deleteAppliance(
    String applianceId, {
    int? expectedRevision,
  }) async {
    try {
      final res = await _client
          .delete(
            _base.replace(
              path: '/appliances/$applianceId',
              queryParameters: expectedRevision == null
                  ? null
                  : {'expected_revision': '$expectedRevision'},
            ),
            headers: _headers,
          )
          .timeout(_timeout);
      if (res.statusCode == 409) {
        // 내가 본 판 이후에 다른 기기가 바꿨다. false로 뭉개면 호출부가
        // 통신 실패로 보고 계속 재시도한다 -- 같은 충돌이 영원히 반복된다.
        throw RpiApiException(409, _detailOf(res));
      }
      // 404는 성공으로 본다 -- 되돌려 놓으려던 상태(그 가전이 없음)가 이미
      // 성립했다. 실패로 치면 대기열에서 영영 안 빠진다.
      return res.statusCode == 200 || res.statusCode == 404;
    } on RpiApiException {
      rethrow;
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
