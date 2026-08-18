import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/rpi_api_service.dart';

// ── 기본 URL (mDNS — 라우터 없이도 simplelay.local로 자동 연결) ─────────────
const _kDefaultUrl = 'http://simplelay.local:8000';

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
    final trimmed = url.trim().isEmpty ? _kDefaultUrl : url.trim();
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
    state = ok ? RpiConnectionState.connected : RpiConnectionState.unreachable;
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
