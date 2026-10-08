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
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  BluetoothDevice? _device;
  BluetoothCharacteristic? _characteristic;
  bool _isSimulated = false;

  Stream<Map<String, dynamic>> get messages => _messages.stream;
  Stream<BleConnectionState> get connectionState => _state.stream;
  BluetoothDevice? get connectedDevice => _device;

  Stream<List<ScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    yield const []; // 즉시 빈 목록 emit → 로딩 스피너 방지
    _state.add(BleConnectionState.scanning);
    FlutterBluePlus.startScan(timeout: timeout).catchError((_) {
      _state.add(BleConnectionState.disconnected);
    });
    Future<void>.delayed(timeout, () {
      // 서비스 dispose 후에도 이 지연 콜백은 살아있을 수 있다 — 닫힌
      // 컨트롤러에 add하면 StateError가 나므로 반드시 확인.
      if (_device == null && !_state.isClosed) {
        _state.add(BleConnectionState.disconnected);
      }
    });
    yield* FlutterBluePlus.scanResults;
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  Future<void> connect(BluetoothDevice device) async {
    // 시뮬레이션(데모) 상태에서 실기기로 넘어올 때 반드시 해제 — 안 하면
    // send()가 예외 없이 조용히 no-op이 되어 실제 전송이 전부 사라진다.
    _isSimulated = false;
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
    // 재연결 때마다 리스너가 누적되지 않도록 이전 구독을 먼저 정리한다.
    await _connectionSubscription?.cancel();
    _connectionSubscription = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _device = null;
        _characteristic = null;
        if (!_state.isClosed) _state.add(BleConnectionState.disconnected);
      }
    });
    _state.add(BleConnectionState.connected);
  }

  Future<void> disconnect() async {
    await _notificationSubscription?.cancel();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    await _device?.disconnect();
    _device = null;
    _characteristic = null;
    _state.add(BleConnectionState.disconnected);
  }

  Future<void> send(Map<String, dynamic> message) async {
    if (_isSimulated) return;
    final characteristic = _characteristic;
    if (characteristic == null) throw StateError('BLE 기기가 연결되지 않았어요.');
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

  /// 정지 프레임을 보낸다. **실제로 보냈을 때만 true** — 모의 연결은 아무것도
  /// 보내지 않으므로 false다(음성 '멈춰'가 보낸 것으로 치지 않게, 10/8 리뷰).
  Future<bool> emergencyStop() async {
    if (_isSimulated) return false;
    await send({'type': 'emergency_stop'});
    return true;
  }

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
    await _connectionSubscription?.cancel();
    await _messages.close();
    await _state.close();
  }
}
