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

  test('쓰기 실패는 예외 없이 false를 반환한다 (읽기 전용 파일시스템)', () {
    final store = KioskSettingsStore(
      path: '${tempDir.path}${Platform.pathSeparator}no-such-dir'
          '${Platform.pathSeparator}settings.json',
    );

    expect(store.save(const KioskSettings()), false);
    // 조용히 삼키지 않고 실패 사실을 남긴다 — 사용자에게 알릴 수 있어야 한다
    expect(store.lastSaveFailed, true);
  });

  test('저장 성공 시 lastSaveFailed는 false로 회복된다', () {
    final store = KioskSettingsStore(path: path('ok.json'));

    expect(store.save(const KioskSettings(largeText: true)), true);
    expect(store.lastSaveFailed, false);
  });

  test('저장은 원자적이다 — 임시 파일을 남기지 않고 교체한다', () {
    final store = KioskSettingsStore(path: path('atomic.json'));

    store.save(const KioskSettings(largeText: true));

    expect(File(path('atomic.json')).existsSync(), true);
    expect(File('${path('atomic.json')}.tmp').existsSync(), false);
  });

  test('본 파일이 손상돼도 직전 저장분(.bak)으로 복구한다', () {
    // 쓰기 도중 정전 시나리오: .bak은 온전하고 본 파일만 잘린 상태
    final store = KioskSettingsStore(path: path('recover.json'));
    store.save(const KioskSettings(largeText: true, applianceId: 'induction'));
    store.save(const KioskSettings(largeText: true, applianceId: 'induction'));
    File(path('recover.json')).writeAsStringSync('{"large_text": tr');

    final recovered = KioskSettingsStore(path: path('recover.json')).load();

    expect(recovered.largeText, true);
    expect(recovered.applianceId, 'induction');
  });

  test('본 파일과 백업이 모두 손상되면 기본값으로 떨어진다', () {
    File(path('both.json')).writeAsStringSync('{broken');
    File('${path('both.json')}.bak').writeAsStringSync('also broken');

    final settings = KioskSettingsStore(path: path('both.json')).load();

    expect(settings.ttsEnabled, true);
    expect(settings.largeText, false);
  });
}
