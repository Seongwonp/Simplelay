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
