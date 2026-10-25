// 제안 알림음(2026-10-25 사용자 요청) — 알림음 뒤에 말한다. 음성 안내가 꺼져 있으면 둘 다 없다.
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_tts_service.dart';

void main() {
  test('announce는 알림음이 끝난 뒤 말한다', () async {
    final order = <String>[];
    final tts = KioskTtsService(
      runner: (cmd) async => order.add('speak:${cmd.last}'),
      chimeRunner: () async => order.add('chime'),
    );
    await tts.announce('공기청정기 바람 세게, 지금 할까요?');
    expect(order, ['chime', 'speak:공기청정기 바람 세게, 지금 할까요?']);
  });

  test('음성 안내를 끄면 알림음만, 소리 끄기면 아무 소리도 없다', () async {
    final order = <String>[];
    final tts = KioskTtsService(runner: (cmd) async => order.add('speak'), chimeRunner: () async => order.add('chime'))
      ..enabled = false;
    await tts.announce('안녕');
    expect(order, ['chime']);
    order.clear();
    tts
      ..enabled = true
      ..muted = true;
    await tts.announce('안녕');
    await tts.speak('안녕');
    expect(order, isEmpty);
  });
}
