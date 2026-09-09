
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
  category: ApplianceCategory.other,
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

  group('installedAppliancesProvider', () {
    test('사용자가 추가한 것만 설치 목록이다 — 예시 템플릿은 섞지 않는다', () async {
      // 템플릿을 섞어 세면, 아직 아무것도 등록하지 않은 사람의 홈에 남의
      // 전자레인지가 놓인다. 그 순간 앱이 말하는 다른 상태도 못 믿게 된다.
      final c = makeContainer();
      await c.read(customAppliancesProvider.notifier).ensureLoaded();

      expect(c.read(installedAppliancesProvider), isEmpty);

      await c.read(customAppliancesProvider.notifier).add(_customGrill);

      expect(c.read(installedAppliancesProvider).map((a) => a.id),
          ['custom_grill_001']);
    });
  });

  group('selectedApplianceProvider', () {
    test('저장된 선택값이 커스텀 가전이어도 로딩 레이스 없이 정확히 복원된다', () async {
      // 1번째 컨테이너: 커스텀 가전 추가 + 선택 저장.
      final c1 = makeContainer();
      await c1.read(customAppliancesProvider.notifier).ensureLoaded();
      await c1.read(customAppliancesProvider.notifier).add(_customGrill);
      await c1.read(selectedApplianceProvider.notifier).select(_customGrill);

      // 2번째 컨테이너: 앱 재시작 시뮬레이션 — 선택 복원이 커스텀 목록
      // 로딩을 기다리지 않으면 저장한 가전을 못 찾고 null로 남는다.
      final c2 = makeContainer();
      // 임의 지연으로 맞추지 않는다. 초기화 완료 신호를 그대로 기다린다.
      await c2.read(applianceStartupProvider.future);

      expect(c2.read(selectedApplianceProvider)?.id, 'custom_grill_001');
    });
  });
}
