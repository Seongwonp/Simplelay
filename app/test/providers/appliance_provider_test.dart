import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/appliance_provider.dart';

ProviderContainer makeContainer() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

const _customGrill = ApplianceMap(
  id: 'custom_grill_001',
  name: '그릴',
  icon: Icons.widgets_outlined,
  rows: 2,
  cols: 2,
  isCustom: true,
  buttons: [
    ApplianceButton(id: 'g1', label: '전원', x: 0, y: 0),
    ApplianceButton(id: 'g2', label: '시작', x: 1, y: 0),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('CustomAppliancesNotifier', () {
    test('initially empty', () async {
      final c = makeContainer();
      await c.read(customAppliancesProvider.notifier).ensureLoaded();
      expect(c.read(customAppliancesProvider), isEmpty);
    });

    test('add() appends and persists', () async {
      final c = makeContainer();
      await c.read(customAppliancesProvider.notifier).ensureLoaded();

      await c.read(customAppliancesProvider.notifier).add(_customGrill);

      expect(c.read(customAppliancesProvider), [_customGrill]);

      // 새 컨테이너(=앱 재시작 시뮬레이션)에서도 저장된 값을 읽어온다.
      final c2 = makeContainer();
      await c2.read(customAppliancesProvider.notifier).ensureLoaded();
      final reloaded = c2.read(customAppliancesProvider);
      expect(reloaded.length, 1);
      expect(reloaded.first.id, 'custom_grill_001');
      expect(reloaded.first.name, '그릴');
      expect(reloaded.first.buttons.map((b) => b.label), ['전원', '시작']);
    });

    test('remove() drops it from state and persistence', () async {
      final c = makeContainer();
      await c.read(customAppliancesProvider.notifier).ensureLoaded();
      await c.read(customAppliancesProvider.notifier).add(_customGrill);

      await c.read(customAppliancesProvider.notifier).remove('custom_grill_001');

      expect(c.read(customAppliancesProvider), isEmpty);

      final c2 = makeContainer();
      await c2.read(customAppliancesProvider.notifier).ensureLoaded();
      expect(c2.read(customAppliancesProvider), isEmpty);
    });
  });

  group('allAppliancesProvider', () {
    test('내장 가전 + 커스텀 가전을 합쳐서 보여준다', () async {
      final c = makeContainer();
      await c.read(customAppliancesProvider.notifier).ensureLoaded();
      await c.read(customAppliancesProvider.notifier).add(_customGrill);

      final all = c.read(allAppliancesProvider);
      expect(all.map((a) => a.id), [...kAppliances.map((a) => a.id), 'custom_grill_001']);
    });
  });

  group('selectedApplianceProvider', () {
    test('저장된 선택값이 커스텀 가전이어도 로딩 레이스 없이 정확히 복원된다', () async {
      // 1번째 컨테이너: 커스텀 가전 추가 + 선택 저장.
      final c1 = makeContainer();
      await c1.read(customAppliancesProvider.notifier).ensureLoaded();
      await c1.read(customAppliancesProvider.notifier).add(_customGrill);
      await c1.read(selectedApplianceProvider.notifier).select(_customGrill);

      // 2번째 컨테이너: 앱 재시작 시뮬레이션 — SelectedApplianceNotifier의 _load()가
      // CustomAppliancesNotifier의 로딩을 기다리지 않으면 kAppliances.first로
      // 잘못 되돌아갈 수 있다(레이스 컨디션 회귀 테스트).
      final c2 = makeContainer();
      // selectedApplianceProvider 생성 즉시 읽되, 비동기 _load()가 끝날 때까지 기다린다.
      c2.read(selectedApplianceProvider);
      await c2.read(customAppliancesProvider.notifier).ensureLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(c2.read(selectedApplianceProvider).id, 'custom_grill_001');
    });
  });
}
