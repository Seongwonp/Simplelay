import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/services/rpi_api_service.dart';

/// 안전 보고 G7(2026-10-16): 서버는 /execute의 정지어를 /stop의 뜻으로 받고 `status: "stopped"`와 정지 결과(`stop`,
/// /stop 응답과 같은 모양)를 돌려준다. 옛 서버는 `status: "accepted"`(또는 없음)뿐이다.
void main() {
  test('접수 응답의 stopped·정지 결과를 읽는다', () {
    final stopped = RpiJobAccepted.fromJson({
      'job_id': 'job-9',
      'status': 'stopped',
      'stop': {'was_running': true, 'stop_level': 'mcu_ack', 'stop_job_id': 'job-9'},
    });
    expect(stopped.stopped, isTrue);
    expect(stopped.stop?.stopLevel, 'mcu_ack');
    expect(stopped.stop?.wasRunning, isTrue);
  });

  test('옛 서버·일반 접수는 stopped가 아니다', () {
    final old = RpiJobAccepted.fromJson({'job_id': 'job-1'});
    expect(old.stopped, isFalse);
    expect(old.stop, isNull);
    final accepted = RpiJobAccepted.fromJson({'job_id': 'job-2', 'status': 'accepted', 'stop': null});
    expect(accepted.stopped, isFalse);
    expect(accepted.stop, isNull);
  });

  test('/stop 응답의 was_running을 읽는다(옛 서버는 모름 = 거짓)', () {
    expect(StopOutcome.fromJson({'was_running': true}).wasRunning, isTrue);
    expect(StopOutcome.fromJson({'ok': true}).wasRunning, isFalse);
  });
}
