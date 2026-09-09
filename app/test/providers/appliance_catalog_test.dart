// 가전 **템플릿**과 **실제 설치된 가전**이 섞여 있는 문제를 고정한다.
//
// 지금 코드는 `kAppliances`(전자레인지·인덕션·에어컨)를 사용자가 소유한
// 가전처럼 목록에 넣고, 선택값이 없으면 전자레인지로 되돌린다. 그래서
// 백엔드가 다중 가전을 지원해도 사용자에게는 **전자레인지 데모 앱**으로
// 보인다.
//
// 아래는 그 동작을 **재현**해서 못 박는 테스트다. 계약을 바꾸면 여기가
// 먼저 깨지고, 무엇이 달라졌는지 이름으로 읽힌다.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/appliance_provider.dart';

/// 선택 provider의 비동기 로드가 끝난 뒤의 값. 그냥 읽으면 로드 전
/// 초기값을 보게 되고, 기다리지 않으면 컨테이너가 먼저 정리돼 버린다.
Future<String> _settledSelection(ProviderContainer c) async {
  c.read(selectedApplianceProvider);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return c.read(selectedApplianceProvider).id;
}

Future<ProviderContainer> _container() async {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  await c.read(customAppliancesProvider.notifier).ensureLoaded();
  return c;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('감사 — 템플릿이 설치 목록 행세를 한다', () {
    test('아무것도 등록하지 않아도 가전 세 대가 있는 것처럼 보인다', () async {
      final c = await _container();

      final all = c.read(allAppliancesProvider);

      // 사용자는 한 대도 등록하지 않았다.
      expect(c.read(customAppliancesProvider), isEmpty);
      // 그런데 목록에는 세 대가 있다.
      expect(all.map((a) => a.id),
          containsAll(<String>['microwave', 'induction', 'aircon']));
    });

    test('선택값이 없으면 전자레인지가 자동으로 선택된다', () async {
      final c = await _container();
      // 저장값 읽기가 끝나야 최종 선택이 정해진다.
      final id = await _settledSelection(c);

      // 저장된 선택값이 없는데도 전자레인지가 골라져 있다.
      expect(id, 'microwave');
    });

    test('없는 가전을 선택값으로 두면 조용히 전자레인지로 바뀐다', () async {
      SharedPreferences.setMockInitialValues(
        {'selected_appliance': '지워진_가전'},
      );
      final c = await _container();
      final id = await _settledSelection(c);

      // 지운 가전을 고르고 있었다는 사실을 알리지 않고 대체한다.
      expect(id, 'microwave');
    });
  });

  group('감사 — 종류(category)가 없다', () {
    test('커스텀 가전은 저장·복원에서 아이콘이 하나로 뭉개진다', () {
      final saved = ApplianceMap(
        id: 'custom_1',
        name: '거실 에어컨',
        icon: Icons.ac_unit, // 사용자가 에어컨으로 등록했다고 치자
        rows: 2,
        cols: 2,
        buttons: const [],
        isCustom: true,
      );

      final restored = ApplianceMap.fromJson(saved.toJson());

      // 이름은 살아남지만 **무슨 종류인지는 사라진다**.
      expect(restored.name, '거실 에어컨');
      expect(restored.icon, Icons.widgets_outlined);
      // 직렬화 자체에 종류를 담을 자리가 없다.
      expect(saved.toJson().containsKey('category'), isFalse);
    });

    test('같은 종류 두 대는 id로는 공존하지만 서로 구분할 근거가 없다', () {
      final living = ApplianceMap.fromJson({
        'id': 'custom_1',
        'name': '거실 에어컨',
        'rows': 2,
        'cols': 2,
        'buttons': <Map<String, dynamic>>[],
      });
      final bed = ApplianceMap.fromJson({
        'id': 'custom_2',
        'name': '안방 에어컨',
        'rows': 2,
        'cols': 2,
        'buttons': <Map<String, dynamic>>[],
      });

      // id는 다르다 -- 여기까지는 맞다.
      expect(living.id, isNot(bed.id));
      // 그런데 둘 다 같은 일반 아이콘이라, 화면에서 종류를 알 수 없다.
      expect(living.icon, bed.icon);
      expect(living.icon, Icons.widgets_outlined);
    });
  });

  group('감사 — 폰과 백엔드의 내장 목록이 다르다', () {
    test('폰에는 에어컨이 있는데 백엔드·키오스크에는 없다', () {
      // 백엔드 내장은 microwave·induction 둘뿐이다
      // (rpi/services/appliance_registry.py). 키오스크도 같다.
      // 폰만 셋을 들고 있어서, 사용자가 고른 에어컨은 서버가 모른다.
      expect(kAppliances.map((a) => a.id),
          containsAll(<String>['microwave', 'induction', 'aircon']));
      expect(kAppliances.length, 3);
    });
  });
}
