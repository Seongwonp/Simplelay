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
    'label': '에어컨 켜기',
    'steps': ['AC-01', 'AC-02', 'AC-04'],
  };

  void injectSuggestion() {
    _ble.simulateConnected();
    _ble.injectMessage(_suggestion);
  }

  /// 승인 직후 호출 — 센서 피드백 3회 후 성공 결과를 순차 주입한다.
  ///
  /// 모든 프레임에 `sequence_id`를 넣는다. 넣지 않으면 추적기의 '내
  /// 실행인가' 검사를 통과해버려서, 4초 뒤 도착한 데모 센서 값이 그
  /// 사이 시작된 **진짜 실행**의 진행을 덮어쓴다.
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
          'sequence_id': _suggestion['sequence_id'],
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
