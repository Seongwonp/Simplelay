// 폰에서 등록한 **종류**가 서버를 거쳐 키오스크까지 이어지는지.
//
// 예전에는 파서가 종류를 읽어 아이콘만 뽑고 버렸다. 그러면 파서 밖에서
// 종류를 다시 볼 수 없어서, 왕복이 아이콘 수준에서만 성립했다 -- 두
// 화면이 같은 가전을 같은 종류로 이해하는지 확인할 방법이 없었다.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';

Map<String, dynamic> _json({String? category, String? icon}) => {
      'id': 'a1',
      'name': '거실 에어컨',
      if (category != null) 'category': category,
      if (icon != null) 'icon': icon,
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'b1', 'label': '전원', 'x': 0, 'y': 0},
      ],
    };

void main() {
  group('서버 응답 → 키오스크 모델', () {
    test('종류를 보관한다 — 아이콘만 뽑고 버리지 않는다', () {
      final a = applianceFromServerJson(_json(category: 'air_conditioner'));

      expect(a.category, 'air_conditioner');
      expect(a.icon, Icons.ac_unit);
    });

    test('종류마다 다른 그림을 고른다', () {
      const expected = {
        'microwave': Icons.microwave,
        'induction': Icons.soup_kitchen,
        'air_conditioner': Icons.ac_unit,
        'washing_machine': Icons.local_laundry_service,
        'rice_cooker': Icons.rice_bowl,
        'intercom': Icons.doorbell, // 시연 v3 갭 S6 — ③ 방문자 문 열기
      };
      for (final entry in expected.entries) {
        final a = applianceFromServerJson(_json(category: entry.key));
        expect(a.category, entry.key);
        expect(a.icon, entry.value, reason: entry.key);
      }
    });

    test('모르는 종류는 거절하지 않고 other로 떨어진다', () {
      // 앞선 버전의 서버가 새 종류를 알고 있을 수 있다. 던지면 목록 전체를
      // 못 읽게 된다.
      final a = applianceFromServerJson(_json(category: '아직_없는_종류'));

      expect(a.category, 'other');
      // 앱 모음 격자는 '앱 목록'으로 읽혔다 — 모르는 종류는 콘센트(평가 6차 10/18).
      expect(a.icon, Icons.power_outlined);
      // 나머지 정보는 그대로 살아 있다.
      expect(a.name, '거실 에어컨');
      expect(a.buttons.single.label, '전원');
    });
  });

  group('구버전 서버 호환', () {
    test('category가 없으면 icon 힌트에서 명시적인 표로만 되살린다', () {
      expect(applianceFromServerJson(_json(icon: 'microwave')).category,
          'microwave');
      expect(applianceFromServerJson(_json(icon: 'induction')).category,
          'induction');
      expect(applianceFromServerJson(_json(icon: 'aircon')).category,
          'air_conditioner');
    });

    test('"custom"은 종류를 담은 적이 없다 — other다', () {
      // 이름이 '거실 에어컨'이어도 추측하지 않는다.
      final a = applianceFromServerJson(_json(icon: 'custom'));

      expect(a.category, 'other');
      expect(a.name, '거실 에어컨');
    });

    test('둘 다 없어도 깨지지 않는다', () {
      expect(applianceFromServerJson(_json()).category, 'other');
    });

    test('category가 있으면 icon과 어긋나도 category가 이긴다', () {
      // 진실원천은 하나여야 한다. 두 값이 다를 때 무엇을 믿을지 정해두지
      // 않으면 화면마다 다른 그림이 나온다.
      final a = applianceFromServerJson(
        _json(category: 'washing_machine', icon: 'microwave'),
      );

      expect(a.category, 'washing_machine');
      expect(a.icon, Icons.local_laundry_service);
    });
  });
}
