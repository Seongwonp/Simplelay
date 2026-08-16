import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/rpi_api_service.dart';

// ── RPi 서버 URL 저장 ─────────────────────────────────────────────────────

class RpiUrlNotifier extends StateNotifier<String?> {
  RpiUrlNotifier() : super(null) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString('rpi_base_url');
  }

  Future<void> save(String url) async {
    final trimmed = url.trim().isEmpty ? null : url.trim();
    state = trimmed;
    final prefs = await SharedPreferences.getInstance();
    if (trimmed == null) {
      await prefs.remove('rpi_base_url');
    } else {
      await prefs.setString('rpi_base_url', trimmed);
    }
  }

  Future<void> clear() async {
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('rpi_base_url');
  }
}

final rpiUrlProvider = StateNotifierProvider<RpiUrlNotifier, String?>(
  (ref) => RpiUrlNotifier(),
);

// ── RpiApiService 인스턴스 (URL 설정 시만 non-null) ──────────────────────

final rpiApiServiceProvider = Provider<RpiApiService?>((ref) {
  final url = ref.watch(rpiUrlProvider);
  if (url == null || url.isEmpty) return null;
  final service = RpiApiService(url);
  ref.onDispose(service.dispose);
  return service;
});

// ── RPi 연결 상태 (ping 결과) ─────────────────────────────────────────────

enum RpiConnectionState { unconfigured, checking, connected, unreachable }

class RpiConnectionNotifier extends StateNotifier<RpiConnectionState> {
  RpiConnectionNotifier(this._ref) : super(RpiConnectionState.unconfigured);

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
