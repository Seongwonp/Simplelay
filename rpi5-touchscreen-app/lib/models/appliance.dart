import 'package:flutter/material.dart';

class ApplianceButton {
  const ApplianceButton({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
  });

  final String id;
  final String label;
  final int x;
  final int y;
}

class ApplianceMap {
  const ApplianceMap({
    required this.id,
    required this.name,
    required this.icon,
    required this.rows,
    required this.cols,
    required this.buttons,
    this.canExecute = true,
    this.readiness = 'unknown',
    this.readinessReasons = const [],
  });

  final String id;
  final String name;
  final IconData icon;
  final int rows;
  final int cols;
  final List<ApplianceButton> buttons;

  /// 이 가전을 지금 맡길 수 있나 (서버 F1 판정).
  ///
  /// **등록됐다는 것과 조작할 수 있다는 것은 다르다.** 서버 정보가 없는
  /// 하드코딩 폴백에서는 막지 않는다 — 모르는 것을 '안 됨'으로 단정하면
  /// 서버가 죽었을 때 조작 수단이 통째로 사라진다. 준비 안 된 실행은
  /// 서버가 412로 거절한다(이중 방어).
  final bool canExecute;

  /// disconnected | needs_setup | operable | unknown
  ///
  /// `unknown`은 **서버에게 물어본 적이 없다**는 뜻이다(하드코딩 폴백).
  /// 'operable'과 구분한다 -- 확인된 것과 그냥 모르는 것은 다르다.
  final String readiness;

  /// 맡길 수 없는 이유. '안 됩니다'만 말하면 할 수 있는 일이 없다.
  final List<String> readinessReasons;

  ApplianceButton? buttonAt(int x, int y) {
    try {
      return buttons.firstWhere((b) => b.x == x && b.y == y);
    } catch (_) {
      return null;
    }
  }
}

// 폰 앱(app/lib/models/appliance.dart)과 동일한 버튼 배치를 유지한다.
// (리스트 인덱싱은 const 표현식이 아니라 기본 파라미터 값으로 못 쓰므로,
// 기본값으로 참조할 항목은 이렇게 별도 top-level const로 분리해 둔다.)
const kMicrowaveAppliance = ApplianceMap(
  id: 'microwave',
  name: '전자레인지',
  icon: Icons.microwave,
  rows: 4,
  cols: 3,
  buttons: [
    ApplianceButton(id: 'BT-01', label: '10초', x: 0, y: 0),
    ApplianceButton(id: 'BT-02', label: '30초', x: 1, y: 0),
    ApplianceButton(id: 'BT-03', label: '1분', x: 2, y: 0),
    ApplianceButton(id: 'BT-04', label: '5분', x: 0, y: 1),
    ApplianceButton(id: 'BT-07', label: '해동', x: 0, y: 2),
    ApplianceButton(id: 'BT-08', label: '즉석밥', x: 1, y: 2),
    ApplianceButton(id: 'BT-09', label: '냉동식품', x: 2, y: 2),
    ApplianceButton(id: 'BT-10', label: '라면', x: 1, y: 1),
    ApplianceButton(id: 'BT-06', label: '취소', x: 1, y: 3),
    ApplianceButton(id: 'BT-05', label: '시작', x: 2, y: 3),
  ],
);

const kInductionAppliance = ApplianceMap(
  id: 'induction',
  name: '인덕션',
  icon: Icons.soup_kitchen,
  rows: 3,
  cols: 4,
  buttons: [
    ApplianceButton(id: 'IN-01', label: '전원', x: 0, y: 0),
    ApplianceButton(id: 'IN-02', label: '화력+', x: 1, y: 0),
    ApplianceButton(id: 'IN-03', label: '화력-', x: 2, y: 0),
    ApplianceButton(id: 'IN-04', label: '타이머', x: 3, y: 0),
    ApplianceButton(id: 'IN-05', label: '1단', x: 0, y: 1),
    ApplianceButton(id: 'IN-06', label: '3단', x: 1, y: 1),
    ApplianceButton(id: 'IN-07', label: '5단', x: 2, y: 1),
    ApplianceButton(id: 'IN-08', label: '보온', x: 3, y: 1),
    ApplianceButton(id: 'IN-09', label: '시작', x: 2, y: 2),
    ApplianceButton(id: 'IN-10', label: '취소', x: 3, y: 2),
  ],
);

const kAppliances = <ApplianceMap>[kMicrowaveAppliance, kInductionAppliance];

/// 서버의 icon 힌트 문자열 → 아이콘. 모르는 값(커스텀 등)은 기본 아이콘 —
/// 서버는 그림을 모르고 힌트만 준다.
IconData applianceIconFor(String hint) => switch (hint) {
      'microwave' => Icons.microwave,
      'induction' => Icons.soup_kitchen,
      _ => Icons.widgets_outlined,
    };

/// GET /appliances 한 항목 → ApplianceMap. 폰에서 등록한 커스텀 가전이
/// 키오스크 조작판이 되는 지점이라, 필드가 이상하면 그 항목만 버린다
/// (호출부에서 try/catch).
ApplianceMap applianceFromServerJson(Map<String, dynamic> json) => ApplianceMap(
      id: json['id'] as String,
      name: json['name'] as String,
      icon: applianceIconFor(json['icon'] as String? ?? ''),
      rows: json['rows'] as int,
      cols: json['cols'] as int,
      // 준비 상태는 폰과 **같은 값**을 본다 — 한 서버에서 나온다.
      canExecute: json['can_execute'] as bool? ?? true,
      readiness: json['readiness'] as String? ?? 'unknown',
      readinessReasons:
          (json['readiness_reasons'] as List<dynamic>?)?.cast<String>() ??
              const [],
      buttons: [
        for (final b in json['buttons'] as List<dynamic>)
          ApplianceButton(
            id: (b as Map<String, dynamic>)['id'] as String,
            label: b['label'] as String,
            x: b['x'] as int,
            y: b['y'] as int,
          ),
      ],
    );
