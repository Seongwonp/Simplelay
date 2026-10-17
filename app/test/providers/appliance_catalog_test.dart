// 가전 **템플릿**과 **실제 설치된 가전**의 계약.
//
// 앞 커밋(`ea92f02`)에서 나는 지금의 잘못된 동작을 그대로 expect 해두었다.
// "재현 테스트"라고 이름 붙였지만, 남겨두면 결함을 명세로 못 박는 회귀
// 검사가 된다 -- 이 저장소에서 이미 두 번 겪은 형태다. 여기서는 **목표
// 계약**을 적는다. 구현 전에는 빨갛고, 구현 후에 초록이 된다.
//
// 계약:
// - `kApplianceTemplates`는 **고를 수 있는 종류**지 소유한 가전이 아니다.
// - 설치 가전이 0대면 목록은 비고, 선택은 없음(null)이다.
// - 지운 가전을 고르고 있었다면 **내가 가진 것 안에서만** 다시 고른다.
//   남은 것이 없으면 없음(null)이지, 템플릿을 세우는 것이 아니다.
// - `category`는 종류를 나타내는 안정적인 값이고 저장·복원·동기화된다.
// - 종류를 모르면 오류가 아니라 `other`와 일반 아이콘이다.
// - 같은 종류를 여러 대 등록할 수 있다(거실/안방 에어컨).

import 'dart:convert';


import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/demo_provider.dart';

/// 초기화가 **실제로 끝난** 컨테이너.
///
/// 임의의 `Future.delayed`로 맞추지 않는다 -- 느린 기기에서 흔들리고,
/// 시작 화면도 같은 신호를 기다려야 하므로 명시적인 완료 Future가 있어야
/// 한다.
Future<ProviderContainer> _ready() async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  await c.read(applianceStartupProvider.future);
  return c;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('설치 목록은 사용자가 등록한 것만 담는다', () {
    test('0대면 목록이 비어 있다', () async {
      final c = await _ready();

      expect(c.read(installedAppliancesProvider), isEmpty);
    });

    test('0대면 선택된 가전이 없다 — 전자레인지로 채우지 않는다', () async {
      final c = await _ready();

      expect(c.read(selectedApplianceProvider), isNull);
    });

    test('템플릿은 고를 수 있는 종류지 소유한 가전이 아니다', () {
      // 종류 목록에는 전자레인지가 있지만,
      expect(
        kApplianceTemplates.map((t) => t.category),
        contains(ApplianceCategory.microwave),
      );
      // 그것이 곧 "이 사용자가 전자레인지를 가지고 있다"는 뜻은 아니다.
      // 설치 목록은 위 테스트대로 비어 있다.
      expect(kApplianceTemplates.length, greaterThan(1));
    });
  });

  group('선택값 복원', () {
    test('저장된 선택이 설치 목록에 있을 때만 복원한다', () async {
      final aircon = _installed(id: 'a1', category: ApplianceCategory.airConditioner);
      SharedPreferences.setMockInitialValues({
        'custom_appliances': [aircon.toJsonString()],
        'selected_appliance': 'a1',
      });
      final c = await _ready();

      expect(c.read(selectedApplianceProvider)?.id, 'a1');
    });

    test('지운 가전 하나뿐이었으면 선택은 없음이 된다', () async {
      SharedPreferences.setMockInitialValues({
        'custom_appliances': <String>[],
        'selected_appliance': '지워진_가전',
      });
      final c = await _ready();

      // 전자레인지로 슬쩍 대체하지 않는다. 고를 것이 없으면 없는 것이다.
      expect(c.read(selectedApplianceProvider), isNull);
    });

    test('다른 가전이 남아 있으면 남은 것 중에서 고른다', () async {
      // 세 대 중 한 대를 지웠는데 홈이 '등록한 가전이 없어요'라고 말하면
      // 그것도 거짓말이다. 대체는 하되 **내가 실제로 가진 것** 안에서만
      // 한다 -- 가진 적 없는 템플릿을 세우는 것과는 다른 얘기다.
      final other = _installed(id: 'a2', category: ApplianceCategory.induction);
      SharedPreferences.setMockInitialValues({
        'custom_appliances': [other.toJsonString()],
        'selected_appliance': '지워진_가전',
      });
      final c = await _ready();

      expect(c.read(selectedApplianceProvider)?.id, 'a2');
    });

    test('쓰는 중에 지우면 선택도 같이 옮겨간다', () async {
      final a1 = _installed(id: 'a1', category: ApplianceCategory.microwave);
      final a2 = _installed(id: 'a2', category: ApplianceCategory.induction);
      SharedPreferences.setMockInitialValues({
        'custom_appliances': [a1.toJsonString(), a2.toJsonString()],
        'selected_appliance': 'a1',
      });
      final c = await _ready();
      expect(c.read(selectedApplianceProvider)?.id, 'a1');

      await c.read(customAppliancesProvider.notifier).remove('a1');

      // 이미 사라진 가전을 계속 가리키고 있으면, 조작은 매번 실패하는데
      // 화면은 멀쩡해 보인다.
      expect(c.read(selectedApplianceProvider)?.id, 'a2');
    });

    test('첫 가전을 추가하면 그것이 선택된다', () async {
      final c = await _ready();
      expect(c.read(selectedApplianceProvider), isNull);

      final first = _installed(id: 'a1', category: ApplianceCategory.riceCooker);
      await c.read(customAppliancesProvider.notifier).add(first);

      expect(c.read(selectedApplianceProvider)?.id, 'a1');
    });
  });

  group('저장소를 읽는 중에 고쳐도 잃지 않는다', () {
    test('켜자마자 추가해도 뒤늦게 끝난 읽기가 덮어쓰지 않는다', () async {
      final existing =
          _installed(id: 'a1', category: ApplianceCategory.microwave);
      SharedPreferences.setMockInitialValues({
        'custom_appliances': [existing.toJsonString()],
      });
      // **초기화를 기다리지 않고** 바로 추가한다 -- 앱을 켜자마자 '가전
      // 추가'로 들어가 저장하는 실제 경로다.
      final c = ProviderContainer();
      addTearDown(c.dispose);

      final added = _installed(id: 'a2', category: ApplianceCategory.induction);
      await c.read(customAppliancesProvider.notifier).add(added);

      // 방금 등록한 것도, 원래 있던 것도 살아 있다.
      expect(c.read(customAppliancesProvider).map((a) => a.id), ['a1', 'a2']);
    });
  });

  group('데모 표본과 프로덕션 빈 상태', () {
    test('데모를 켜지 않으면 표본을 세우지 않는다', () async {
      // 표본을 항상 세우면 실제 사용자가 겪는 첫 화면을 아무도 못 본다.
      final c = await _ready();

      expect(c.read(demoModeProvider), isFalse);
      expect(c.read(installedAppliancesProvider), isEmpty);
    });

    test('데모를 켜면 표본이 서고, 표본은 데모라고 적혀 있다', () async {
      final c = await _ready();

      c.read(demoModeProvider.notifier).state = true;

      final installed = c.read(installedAppliancesProvider);
      expect(installed, isNotEmpty);
      expect(installed.map((a) => a.isDemo), everyElement(isTrue));
      // 뱃지를 못 그리는 자리도 있으므로 이름에도 적는다.
      expect(installed.map((a) => a.name), everyElement(startsWith('연습')));
    });

    test('내가 등록한 가전이 있으면 데모라도 표본을 섞지 않는다', () async {
      final mine = _installed(id: 'a1', category: ApplianceCategory.riceCooker);
      SharedPreferences.setMockInitialValues({
        'custom_appliances': [mine.toJsonString()],
      });
      final c = await _ready();

      c.read(demoModeProvider.notifier).state = true;

      expect(c.read(installedAppliancesProvider).map((a) => a.id), ['a1']);
    });

    test('표본은 기기에 저장되지 않는다', () {
      // 데모를 껐다 켜는 것으로 진짜 등록 목록이 늘어나면 안 된다.
      for (final demo in kDemoAppliances) {
        expect(demo.toJson().containsKey('is_demo'), isFalse);
        expect(ApplianceMap.fromJson(demo.toJson()).isDemo, isFalse);
      }
    });
  });

  group('종류(category)', () {
    test('저장하고 복원해도 종류가 살아남는다', () {
      final saved = _installed(id: 'a1', category: ApplianceCategory.airConditioner);

      final restored = ApplianceMap.fromJson(saved.toJson());

      expect(restored.category, ApplianceCategory.airConditioner);
      expect(saved.toJson()['category'], 'air_conditioner');
    });

    test('종류가 없는 예전 데이터는 other로 살아남는다', () {
      // 앞 버전이 저장한 모양 -- category 자리가 아예 없다.
      final old = {
        'id': 'custom_1',
        'name': '우리집 에어컨',
        'rows': 2,
        'cols': 2,
        'buttons': [
          {'id': 'b1', 'label': '전원', 'x': 0, 'y': 0},
        ],
      };

      final migrated = ApplianceMap.fromJson(old);

      // 데이터는 하나도 잃지 않는다.
      expect(migrated.name, '우리집 에어컨');
      expect(migrated.buttons.single.label, '전원');
      // 종류만 모르는 것으로 채운다.
      expect(migrated.category, ApplianceCategory.other);
    });

    test('모르는 종류는 오류가 아니라 other로 떨어진다', () {
      final future = ApplianceMap.fromJson({
        'id': 'x',
        'name': '미래의 가전',
        'category': '아직_없는_종류',
        'rows': 1,
        'cols': 1,
        'buttons': <Map<String, dynamic>>[],
      });

      expect(future.category, ApplianceCategory.other);
      expect(future.icon, ApplianceCategory.other.icon);
    });

    test('같은 종류를 여러 대 등록할 수 있다', () async {
      final living = _installed(
          id: 'a1', name: '거실 에어컨', category: ApplianceCategory.airConditioner);
      final bed = _installed(
          id: 'a2', name: '안방 에어컨', category: ApplianceCategory.airConditioner);
      SharedPreferences.setMockInitialValues({
        'custom_appliances': [living.toJsonString(), bed.toJsonString()],
      });
      final c = await _ready();

      final installed = c.read(installedAppliancesProvider);
      expect(installed.map((a) => a.id), ['a1', 'a2']);
      // 종류는 같고 식별자만 다르다 -- 그게 정상이다.
      expect(installed.map((a) => a.category),
          everyElement(ApplianceCategory.airConditioner));
      expect(installed.map((a) => a.name), ['거실 에어컨', '안방 에어컨']);
    });

    test('아이콘은 종류에서 나온다 — 저장하지 않는다', () {
      // 아이콘 코드포인트를 저장하면 릴리즈 빌드의 아이콘 트리셰이킹이
      // 깨진다. 종류만 저장하고 그림은 거기서 고른다.
      final a = _installed(id: 'a1', category: ApplianceCategory.washingMachine);

      expect(a.icon, ApplianceCategory.washingMachine.icon);
      expect(a.toJson().containsKey('icon'), isFalse);
    });
  });
}

ApplianceMap _installed({
  required String id,
  required ApplianceCategory category,
  String name = '테스트 가전',
}) =>
    ApplianceMap(
      id: id,
      name: name,
      category: category,
      rows: 2,
      cols: 2,
      buttons: const [],
      isCustom: true,
    );

extension on ApplianceMap {
  /// prefs에 넣을 때 쓰는 문자열. 테스트 가독성용.
  String toJsonString() => jsonEncode(toJson());
}
