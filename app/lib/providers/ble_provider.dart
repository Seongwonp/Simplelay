import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ble_service.dart';

final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService();
  ref.onDispose(service.dispose);
  return service;
});

final bleConnectionProvider = StreamProvider<BleConnectionState>((ref) async* {
  yield BleConnectionState.disconnected;
  yield* ref.watch(bleServiceProvider).connectionState;
});

final bleMessagesProvider = StreamProvider<Map<String, dynamic>>(
  (ref) => ref.watch(bleServiceProvider).messages,
);

final scanResultsProvider = StreamProvider.autoDispose<List<ScanResult>>((ref) {
  final service = ref.watch(bleServiceProvider);
  ref.onDispose(service.stopScan);
  return service.scan();
});

class SavedDeviceNameNotifier extends StateNotifier<String> {
  SavedDeviceNameNotifier() : super('SimpleLay') {
    _load();
  }

  Future<void> _load() async {
    final preferences = await SharedPreferences.getInstance();
    state = preferences.getString('device_name') ?? 'SimpleLay';
  }

  Future<void> save(String value) async {
    state = value.trim();
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('device_name', state);
  }
}

final savedDeviceNameProvider =
    StateNotifierProvider<SavedDeviceNameNotifier, String>(
  (ref) => SavedDeviceNameNotifier(),
);

class SavedDeviceNotifier extends StateNotifier<({String id, String name})?> {
  SavedDeviceNotifier() : super(null) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('saved_device_id');
    final name = prefs.getString('saved_device_display_name');
    if (id != null && name != null) state = (id: id, name: name);
  }

  Future<void> save(String id, String name) async {
    state = (id: id, name: name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_device_id', id);
    await prefs.setString('saved_device_display_name', name);
  }

  Future<void> clear() async {
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_device_id');
    await prefs.remove('saved_device_display_name');
  }
}

final savedDeviceProvider =
    StateNotifierProvider<SavedDeviceNotifier, ({String id, String name})?>(
  (ref) => SavedDeviceNotifier(),
);
