import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/quiet_hours.dart';
import '../models/scenario_run.dart';
import '../services/mdns_resolver.dart';
import '../services/rpi_api_service.dart';
import '../services/simulated_execution_service.dart';
import 'demo_provider.dart';

// ── 기본 URL (mDNS — 라우터 없이도 simplelay.local로 자동 연결) ─────────────
const _kDefaultUrl = 'http://simplelay.local:8000';

/// 사용자가 입력한 서버 주소를 완전한 URL로 정규화한다.
/// "192.168.0.5"처럼 스킴·포트 없이 입력해도 조용히 unreachable이 되지 않게
/// http:// 와 기본 포트 8000을 채워준다. 빈 입력은 그대로 돌려준다(호출자 판단).
String normalizeRpiUrl(String input) {
  var v = input.trim();
  if (v.isEmpty) return v;
  if (!v.startsWith('http://') && !v.startsWith('https://')) {
    v = 'http://$v';
  }
  final uri = Uri.tryParse(v);
  if (uri == null) return v;
  if (!uri.hasPort) {
    v = '${uri.scheme}://${uri.host}:8000${uri.path}';
  }
  return v.replaceAll(RegExp(r'/+$'), '');
}

// ── RPi 서버 URL 저장 ─────────────────────────────────────────────────────

class RpiUrlNotifier extends StateNotifier<String?> {
  RpiUrlNotifier() : super(null) {
    _loaded = _load();
  }

  late final Future<void> _loaded;

  /// 주소가 기기에서 올라올 때까지 기다린다.
  ///
  /// 앱을 열자마자 동기화를 누르면 아직 null이라 "서버 주소를 먼저
  /// 설정해 주세요"가 뜬다 — 설정은 이미 돼 있는데도 그렇다.
  Future<void> ensureLoaded() => _loaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    final saved = prefs.getString('rpi_base_url');
    if (saved == null) {
      // 처음 실행: simplelay.local을 기본값으로 저장
      await prefs.setString('rpi_base_url', _kDefaultUrl);
      if (!mounted) return;
      state = _kDefaultUrl;
    } else {
      state = saved;
    }
  }

  Future<void> save(String url) async {
    final trimmed =
        url.trim().isEmpty ? _kDefaultUrl : normalizeRpiUrl(url);
    state = trimmed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rpi_base_url', trimmed);
  }

  Future<void> resetToDefault() async {
    state = _kDefaultUrl;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('rpi_base_url', _kDefaultUrl);
  }
}

final rpiUrlProvider = StateNotifierProvider<RpiUrlNotifier, String?>(
  (ref) => RpiUrlNotifier(),
);

// 테스트에서 fake로 교체할 수 있게 provider로 노출
final mdnsResolverProvider = Provider<MdnsResolver>((_) => MdnsResolver());

// ── API 키 (서버 SIMPLELAY_API_KEY와 짝 — 시연장 공유 Wi-Fi 방어) ──────────

class RpiApiKeyNotifier extends StateNotifier<String?> {
  RpiApiKeyNotifier() : super(null) {
    _loaded = _load();
  }

  late final Future<void> _loaded;

  /// 저장된 키가 기기에서 올라올 때까지 기다린다. 올라오기 전의 null은
  /// "키 없음"이 아니라 "아직 모름"이다(2026-10-01 키가 지워지던 결함).
  Future<void> ensureLoaded() => _loaded;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = prefs.getString('rpi_api_key');
  }

  Future<void> save(String key) async {
    final trimmed = key.trim();
    state = trimmed.isEmpty ? null : trimmed;
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove('rpi_api_key');
    } else {
      await prefs.setString('rpi_api_key', trimmed);
    }
  }
}

final rpiApiKeyProvider = StateNotifierProvider<RpiApiKeyNotifier, String?>(
  (ref) => RpiApiKeyNotifier(),
);

// ── RpiApiService 인스턴스 ────────────────────────────────────────────────

/// HTTP 클라이언트 주입점 — 테스트에서 이 provider를 갈아끼워 **실제
/// 전송이 있었는지**를 센다. 서비스 자체를 통째로 교체해버리면 데모
/// 분기(아래)를 건너뛰어 정작 검증하려던 것을 못 본다.
final rpiHttpClientProvider = Provider<http.Client?>((_) => null);

// 발견한 주소는 현재 세션에서만 쓰고 사용자가 저장한 이름을 보존한다.
final resolvedRpiUrlProvider = StateProvider<(String, String)?>((_) => null);

final rpiApiServiceProvider = Provider<RpiApiService?>((ref) {
  final savedUrl = ref.watch(rpiUrlProvider);
  final resolved = ref.watch(resolvedRpiUrlProvider);
  final url = resolved?.$1 == savedUrl ? resolved?.$2 : savedUrl;
  if (url == null || url.isEmpty) return null;
  final apiKey = ref.watch(rpiApiKeyProvider);
  final client = ref.watch(rpiHttpClientProvider);
  // 데모(모의) 실행은 **전송 경로에서** 갈라진다. 화면 배너만 바꾸면
  // "실제 조작이 아닙니다"라고 말하면서 실제로 갠트리를 움직인다.
  final demo = ref.watch(demoModeProvider);
  final service = demo
      ? SimulatedExecutionService(url, client: client, apiKey: apiKey)
      : RpiApiService(url, client: client, apiKey: apiKey);
  ref.onDispose(service.dispose);
  return service;
});

// ── RPi 연결 상태 ─────────────────────────────────────────────────────────

enum RpiConnectionState { unconfigured, checking, connected, keyRequired, unreachable }

class RpiConnectionNotifier extends StateNotifier<RpiConnectionState> {
  RpiConnectionNotifier(this._ref) : super(RpiConnectionState.unconfigured) {
    // URL이 로드되거나 바뀌면 자동으로 연결 확인.
    //
    // 확인은 **마이크로태스크로 미룬다.** Riverpod는 listen 콜백을 의존
    // provider(rpiApiServiceProvider)를 무효화하기 **전에** 부른다. 여기서
    // 바로 check()하면 캐시에 남은 옛 주소의 서비스(또는 주소가 없던 때의
    // null)로 ping을 보내, 새 주소가 닿는데도 '닿지 않음'·'미설정'이 된다
    // (2026-09-30 에뮬레이터: 주소 저장 뒤 '재시도'를 눌러야만 연결됨).
    _ref.listen(rpiApiKeyProvider, (_, next) {
      scheduleMicrotask(() => mounted ? check() : null);
    });
    _ref.listen(rpiUrlProvider, (_, next) {
      if (next != null) scheduleMicrotask(() => mounted ? check() : null);
    });
    // 주소가 이 알림자보다 먼저 올라와 있으면 위 listen은 다시 불리지 않는다.
    // 그러면 앱을 다시 열 때마다 '미설정'에 머문다(2026-10-13 에뮬레이터:
    // 요청은 200인데 머리는 '허브 확인 중', 타일은 '허브 설정이 필요해요').
    if (_ref.read(rpiUrlProvider) != null) {
      scheduleMicrotask(() => mounted ? check() : null);
    }
  }

  final Ref _ref;

  /// 확인 세대. 확인이 겹치면(주소 저장 직후의 자동 확인 + 저장 버튼의 확인,
  /// 재시도 연타) **마지막에 시작한 확인만** 상태를 쓴다. 늦게 끝난 옛 확인의
  /// 실패가 새 확인의 '연결됨'을 덮으면 표시가 '닿지 않음'에 굳는다.
  int _generation = 0;

  Future<void> check() async {
    final generation = ++_generation;
    bool stale() => !mounted || generation != _generation;

    final checkedUrl = _ref.read(rpiUrlProvider);
    final service = _ref.read(rpiApiServiceProvider);
    if (service == null) {
      state = RpiConnectionState.unconfigured;
      return;
    }
    state = RpiConnectionState.checking;
    Future<RpiConnectionState> probe(RpiApiService api) async {
      try {
        return await api.ping()
            ? RpiConnectionState.connected
            : RpiConnectionState.unreachable;
      } on RpiApiException catch (e) {
        return e.statusCode == 401
            ? RpiConnectionState.keyRequired
            : RpiConnectionState.unreachable;
      }
    }

    var result = await probe(service);
    if (stale()) return;
    if (result == RpiConnectionState.unreachable) {
      final resolved = await _tryResolveMdns(stale, checkedUrl);
      if (stale()) return;
      if (resolved) {
        final fresh = _ref.read(rpiApiServiceProvider);
        if (fresh != null) result = await probe(fresh);
      }
    }
    if (!stale()) {
      _pollFailures = 0;
      state = result;
    }
  }

  /// 기존 주기 `/status` 조회(estopProvider, 5초)의 통신 결과(외부 평가 2026-10-13 M2).
  ///
  /// 주소·키가 그대로면 판정은 처음·주소/키 변화·사용자 확인 때만이었다 — 허브가 꺼졌다 켜져도 '연결됨'에
  /// 머물러, 연결을 듣는 확인 주행 조회가 다시 묻지 않았다. 이제 **연속 [_pollFailuresToUnreachable]번** 닿지
  /// 않으면 '닿지 않음', 닿지 않음에서 조회가 다시 성공하면 '연결됨'으로 바꾼다. 확인 중·미설정·키 필요는
  /// 건드리지 않는다(그 판정은 [check]가 한다). 허브가 오류 코드로 답한 것은 닿은 것이다(호출자가 가른다).
  void reportHubPoll({required bool reachable}) {
    if (!mounted) return;
    if (reachable) {
      _pollFailures = 0;
      if (state == RpiConnectionState.unreachable) {
        _generation++; // 늦게 끝난 옛 확인의 실패가 이 복구를 덮지 않게
        state = RpiConnectionState.connected;
      }
      return;
    }
    _pollFailures++;
    if (state == RpiConnectionState.connected &&
        _pollFailures >= _pollFailuresToUnreachable) {
      _generation++;
      state = RpiConnectionState.unreachable;
    }
  }

  int _pollFailures = 0;
  static const _pollFailuresToUnreachable = 2;

  Future<bool> _tryResolveMdns(bool Function() stale, String? checkedUrl) async {
    final url = _ref.read(rpiUrlProvider);
    // 확인하던 사이에 사용자가 주소를 바꿨으면 옛 .local 풀이로 덮지 않는다.
    if (url == null || url != checkedUrl) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.host.endsWith('.local')) return false;
    final ip = await _ref.read(mdnsResolverProvider).resolveIPv4(uri.host);
    if (ip == null || stale()) return false;
    _ref.read(resolvedRpiUrlProvider.notifier).state =
        (url, uri.replace(host: ip).toString());
    return true;
  }
}

final rpiConnectionProvider =
    StateNotifierProvider<RpiConnectionNotifier, RpiConnectionState>(
  (ref) => RpiConnectionNotifier(ref),
);

// ── 센서 데이터 (60초마다 폴링) ───────────────────────────────────────────

final sensorProvider = StreamProvider.autoDispose<SensorReading?>((ref) {
  final service = ref.watch(rpiApiServiceProvider);
  if (service == null) return Stream.value(null);

  final controller = StreamController<SensorReading?>();

  Future<void> fetch() async {
    if (controller.isClosed) return;
    final reading = await service.sensors();
    if (!controller.isClosed) controller.add(reading);
  }

  fetch();
  final timer = Timer.periodic(const Duration(seconds: 60), (_) => fetch());

  ref.onDispose(() {
    timer.cancel();
    controller.close();
  });

  return controller.stream;
});

// ── DND 상태 (health 엔드포인트 기반) ────────────────────────────────────

class DndNotifier extends StateNotifier<DateTime?> {
  DndNotifier(this._ref) : super(null);

  final Ref _ref;

  Future<void> refresh() async {
    final service = _ref.read(rpiApiServiceProvider);
    if (service == null) { state = null; return; }
    final health = await service.health();
    // 받지 못하면(401·끊김·옛 서버) 마지막으로 안 값을 둔다 — '꺼짐'으로 덮지 않는다(2026-10-14 보안 점검).
    if (health == null) return;
    _ref.read(dndScopeProvider.notifier).state = health.dndScope;
    state = health.dndUntil;
  }

  /// 서버 `persisted`를 돌려준다 — false면 이번 세션만 적용(화면이 [kSettingNotSavedNotice]로 알린다).
  Future<bool?> set(int minutes) async {
    final service = _ref.read(rpiApiServiceProvider);
    if (service == null) return null;
    final persisted = await service.setDnd(minutes);
    await refresh();
    return persisted;
  }

  Future<bool?> clear() async {
    final service = _ref.read(rpiApiServiceProvider);
    if (service == null) return null;
    final persisted = await service.clearDnd();
    _ref.read(dndScopeProvider.notifier).state = null;
    state = null;
    return persisted;
  }
}

/// 켜진 잠시 쉬기의 범위(서버 `dnd_scope`, 2026-10-14 마감 2번). `suggestions_only`면 업데이트 전에 켠 설정을
/// 이어받은 것이라 새 제안만 쉰다(자동 실행은 그대로) — 화면 문구가 범위대로 말한다.
final dndScopeProvider = StateProvider<String?>((ref) => null);

final dndProvider = StateNotifierProvider<DndNotifier, DateTime?>(
  (ref) => DndNotifier(ref),
);

/// 조용한 시간(2026-10-14, 서버 /quiet-hours). 허브가 없으면 null, 조회 실패·옛 서버(404)도 null.
/// 바꾼 뒤에는 `ref.invalidate`로 다시 받는다.
final quietHoursProvider =
    FutureProvider.autoDispose<QuietHoursStatus?>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return null;
  try {
    return await api.quietHours();
  } catch (_) {
    return null;
  }
});

// ── 노드 레지스트리 (ESP32 IP 등록 목록) ─────────────────────────────────

// applianceId → baseUrl 맵. RPi 연결 상태가 바뀌면 자동 재조회.
final nodeRegistryProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final service = ref.watch(rpiApiServiceProvider);
  if (service == null) return {};
  final nodes = await service.listNodes();
  return {for (final n in nodes) n.applianceId: n.baseUrl};
});

// ── 다단계 실행 결과(G4) ────────────────────────────────────────────────

/// 끝난 job [jobId]의 단계별 결과. GET /scenarios/last-run이 **그 job의 기록**일
/// 때만 값이 있고, 다른 실행의 기록·조회 실패·연결 없음은 null이다 -- 다른
/// 실행의 단계를 내 결과처럼 보이지 않는다.
final scenarioRunForJobProvider = FutureProvider.autoDispose
    .family<ScenarioRun?, String>((ref, jobId) async {
  final service = ref.watch(rpiApiServiceProvider);
  if (service == null) return null;
  final run = await service.scenarioLastRun();
  return run != null && run.jobId == jobId ? run : null;
});

// ── ThinQ 가전(서버 구성) ────────────────────────────────────────────────

/// GET /thinq/devices. ThinQ가 꺼져 있거나(404) 연결이 없으면 null.
final thinqOverviewProvider =
    FutureProvider.autoDispose<RpiThinqOverview?>((ref) async {
  final service = ref.watch(rpiApiServiceProvider);
  if (service == null) return null;
  return service.thinqOverview();
});

/// GET /thinq/discovered — ThinQ 계정에서 찾은 가전(추가 전 목록). 허브 주소가
/// 없으면 실패(이유 포함)로 돌려준다 — 화면이 '0대'로 말하지 않게.
final thinqDiscoveryProvider =
    FutureProvider.autoDispose<RpiThinqDiscovery>((ref) async {
  final service = ref.watch(rpiApiServiceProvider);
  if (service == null) {
    return const RpiThinqDiscovery.failed('허브 주소를 먼저 설정해 주세요.');
  }
  return service.thinqDiscovery();
});
