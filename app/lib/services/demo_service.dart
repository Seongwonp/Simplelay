import 'dart:async';

import 'ble_service.dart';

/// 하드웨어 없이 전체 UX 흐름을 시뮬레이션한다.
/// 제안 수신 → 승인 → 센서 업데이트 × 3 → 완료 순서로 메시지를 주입한다.
class DemoService {
  DemoService(this._ble);

  final BleService _ble;

  static const _suggestion = {
    'type': 'suggestion',
    'sequence_id': 'demo-001',
    'label': '무더위 감지 — 냉방 시작',
    'steps': ['AC-01', 'AC-02', 'AC-04'],
  };

  void injectSuggestion() {
    _ble.simulateConnected();
    _ble.injectMessage(_suggestion);
  }

  /// 승인 직후 호출 — 센서 피드백 3회 후 성공 결과를 순차 주입한다.
  void runExecutionFlow() {
    const delays = [500, 1500, 2800];
    final sensorFrames = [
      {'completed_steps': 0, 'status': 'running'},
      {'completed_steps': 1, 'status': 'running'},
      {'completed_steps': 2, 'status': 'running'},
    ];

    for (var i = 0; i < sensorFrames.length; i++) {
      Future<void>.delayed(Duration(milliseconds: delays[i]), () {
        _ble.injectMessage({
          'type': 'sensor',
          'current_ma': 310.0 + i * 15,
          'sound_db': 42.0 + i * 3,
          ...sensorFrames[i],
        });
      });
    }

    Future<void>.delayed(const Duration(milliseconds: 4000), () {
      _ble.injectMessage({
        'type': 'result',
        'sequence_id': 'demo-001',
        'success': true,
      });
    });
  }
}
