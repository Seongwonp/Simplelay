import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

enum BleConnectionState { disconnected, scanning, connecting, connected }

class BleService {
  static final Guid serviceUuid = Guid('0000FFE0-0000-1000-8000-00805F9B34FB');
  static final Guid characteristicUuid = Guid(
    '0000FFE1-0000-1000-8000-00805F9B34FB',
  );

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _state = StreamController<BleConnectionState>.broadcast();
  final _buffer = StringBuffer();
  StreamSubscription<List<int>>? _notificationSubscription;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  bool _isSimulated = false;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<BleConnectionState> get connectionState => _state.stream;
  BluetoothDevice? get connectedDevice => _device;

  Stream<List<ScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) {
    _state.add(BleConnectionState.scanning);
    FlutterBluePlus.startScan(timeout: timeout).catchError((_) {
      _state.add(BleConnectionState.disconnected);
    });
    Future<void>.delayed(timeout, () {
      if (_device == null) _state.add(BleConnectionState.disconnected);
    });
    return FlutterBluePlus.scanResults;
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  Future<void> connect(BluetoothDevice device) async {
    _state.add(BleConnectionState.connecting);
    await FlutterBluePlus.stopScan();
    try {
      await device.connect(timeout: const Duration(seconds: 12));
    } catch (_) {
      if (!device.isConnected) rethrow;
    }
    final services = await device.discoverServices();
    final service = services.firstWhere((item) => item.uuid == serviceUuid);
    final characteristic = service.characteristics.firstWhere(
      (item) => item.uuid == characteristicUuid,
    );
    _device = device;
    _characteristic = characteristic;
    await characteristic.setNotifyValue(true);
    await _notificationSubscription?.cancel();
    _notificationSubscription = characteristic.onValueReceived.listen(_decode);
    device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _device = null;
        _characteristic = null;
        _state.add(BleConnectionState.disconnected);
      }
    });
    _state.add(BleConnectionState.connected);
  }

  Future<void> disconnect() async {
    await _notificationSubscription?.cancel();
    await _device?.disconnect();
    _device = null;
    _characteristic = null;
    _state.add(BleConnectionState.disconnected);
  }

  Future<void> send(Map<String, dynamic> message) async {
    if (_isSimulated) return;
    final characteristic = _characteristic;
    if (characteristic == null) throw StateError('BLE 기기가 연결되지 않았습니다.');
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    await characteristic.write(bytes, withoutResponse: false);
  }

  Future<void> sendCommand(String text, {required String source}) =>
      send({'type': 'command', 'text': text, 'source': source});

  Future<void> sendConfirmation(String sequenceId, bool approved) => send({
        'type': 'confirm',
        'sequence_id': sequenceId,
        'approved': approved,
      });

  Future<void> emergencyStop() => send({'type': 'emergency_stop'});

  void _decode(List<int> data) {
    _buffer.write(utf8.decode(data, allowMalformed: true));
    var buffered = _buffer.toString();
    while (buffered.contains('\n')) {
      final split = buffered.indexOf('\n');
      final line = buffered.substring(0, split).trim();
      buffered = buffered.substring(split + 1);
      if (line.isNotEmpty) {
        try {
          _messages.add(jsonDecode(line) as Map<String, dynamic>);
        } catch (_) {
          // Ignore malformed packets and continue with the next framed message.
        }
      }
    }
    _buffer.clear();
    _buffer.write(buffered);
  }

  /// 하드웨어 없이 UI 흐름을 검증할 때만 사용. 릴리즈 빌드에서는 호출하지 말 것.
  void simulateConnected() {
    _isSimulated = true;
    _state.add(BleConnectionState.connected);
  }

  void simulateDisconnected() {
    _isSimulated = false;
    _state.add(BleConnectionState.disconnected);
  }

  void injectMessage(Map<String, dynamic> message) {
    _messages.add(message);
  }

  Future<void> dispose() async {
    await _notificationSubscription?.cancel();
    await _messages.close();
    await _state.close();
  }
}
