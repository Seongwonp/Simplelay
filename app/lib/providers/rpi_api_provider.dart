import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/mdns_resolver.dart';
import '../services/rpi_api_service.dart';

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
    _load();
  }

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

// ── RpiApiService 인스턴스 ────────────────────────────────────────────────

final rpiApiServiceProvider = Provider<RpiApiService?>((ref) {
  final url = ref.watch(rpiUrlProvider);
  if (url == null || url.isEmpty) return null;
  final service = RpiApiService(url);
  ref.onDispose(service.dispose);
  return service;
});

// ── RPi 연결 상태 ─────────────────────────────────────────────────────────

enum RpiConnectionState { unconfigured, checking, connected, unreachable }

class RpiConnectionNotifier extends StateNotifier<RpiConnectionState> {
  RpiConnectionNotifier(this._ref) : super(RpiConnectionState.unconfigured) {
    // URL이 로드되면 자동으로 한 번 연결 확인
    _ref.listen(rpiUrlProvider, (_, next) {
      if (next != null) check();
    });
  }

  final Ref _ref;

  Future<void> check() async {
    final service = _ref.read(rpiApiServiceProvider);
    if (service == null) {
      state = RpiConnectionState.unconfigured;
      return;
    }
    state = RpiConnectionState.checking;
    final ok = await service.ping();
    if (!mounted) return; // dispose 후 state 대입 방지
    if (ok) {
      state = RpiConnectionState.connected;
      return;
    }
    // Android는 .local(mDNS) 호스트명을 시스템 DNS로 해석 못 한다 — 앱이
    // 직접 mDNS 질의를 보내 IP를 알아내고 URL을 교체한다. 교체 저장이
    // rpiUrlProvider listen을 통해 재확인을 자동으로 트리거한다.
    final resolved = await _tryResolveMdns();
    if (!mounted) return;
    if (!resolved) state = RpiConnectionState.unreachable;
  }

  Future<bool> _tryResolveMdns() async {
    // flutter test 환경에서는 실제 멀티캐스트 소켓/타이머를 만들지 않는다
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    final url = _ref.read(rpiUrlProvider);
    if (url == null) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.host.endsWith('.local')) return false;
    final ip = await _ref.read(mdnsResolverProvider).resolveIPv4(uri.host);
    if (ip == null || !mounted) return false;
    await _ref.read(rpiUrlProvider.notifier).save(uri.replace(host: ip).toString());
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
    state = health?.dndUntil;
  }

  Future<void> set(int minutes) async {
    final service = _ref.read(rpiApiServiceProvider);
    if (service == null) return;
    await service.setDnd(minutes);
    await refresh();
  }

  Future<void> clear() async {
    final service = _ref.read(rpiApiServiceProvider);
    if (service == null) return;
    await service.clearDnd();
    state = null;
  }
}

final dndProvider = StateNotifierProvider<DndNotifier, DateTime?>(
  (ref) => DndNotifier(ref),
);

// ── 노드 레지스트리 (ESP32 IP 등록 목록) ─────────────────────────────────

// applianceId → baseUrl 맵. RPi 연결 상태가 바뀌면 자동 재조회.
final nodeRegistryProvider =
    FutureProvider.autoDispose<Map<String, String>>((ref) async {
  final service = ref.watch(rpiApiServiceProvider);
  if (service == null) return {};
  final nodes = await service.listNodes();
  return {for (final n in nodes) n.applianceId: n.baseUrl};
});
