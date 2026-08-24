// 키오스크 설정 영속화(KioskSettingsStore) — 라운드트립·손상 폴백 계약.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_settings_store.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('kiosk-settings-test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String path(String name) => '${tempDir.path}${Platform.pathSeparator}$name';

  test('저장 후 다시 로드하면 같은 값이 나온다 (재부팅 시나리오)', () {
    final store = KioskSettingsStore(path: path('settings.json'));
    store.save(const KioskSettings(
      ttsEnabled: false,
      largeText: true,
      applianceId: 'induction',
    ));

    // 새 인스턴스 = 프로세스 재시작과 동일
    final reloaded =
        KioskSettingsStore(path: path('settings.json')).load();

    expect(reloaded.ttsEnabled, false);
    expect(reloaded.largeText, true);
    expect(reloaded.applianceId, 'induction');
  });

  test('파일이 없으면 기본값 — 음성 안내 켜짐, 큰 글씨 꺼짐', () {
    final settings = KioskSettingsStore(path: path('missing.json')).load();

    expect(settings.ttsEnabled, true);
    expect(settings.largeText, false);
    expect(settings.applianceId, isNull);
  });

  test('손상된 JSON이면 기본값으로 폴백한다 (키오스크는 반드시 떠야 함)', () {
    File(path('broken.json')).writeAsStringSync('{not json!!');

    final settings = KioskSettingsStore(path: path('broken.json')).load();

    expect(settings.ttsEnabled, true);
    expect(settings.largeText, false);
  });

  test('필드 타입이 틀려도 해당 필드만 기본값으로 폴백한다', () {
    File(path('partial.json')).writeAsStringSync(
      '{"tts_enabled": "yes", "large_text": true, "appliance_id": 3}',
    );

    final settings = KioskSettingsStore(path: path('partial.json')).load();

    expect(settings.ttsEnabled, true); // 문자열 "yes" → 기본값
    expect(settings.largeText, true); // 올바른 필드는 유지
    expect(settings.applianceId, isNull); // 숫자 → 기본값
  });

  test('쓰기 실패는 조용히 무시된다 (읽기 전용 파일시스템)', () {
    final store = KioskSettingsStore(
      path: '${tempDir.path}${Platform.pathSeparator}no-such-dir'
          '${Platform.pathSeparator}settings.json',
    );

    store.save(const KioskSettings()); // 예외가 새어 나오면 여기서 실패
  });
}
