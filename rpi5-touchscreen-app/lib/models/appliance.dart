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
  });

  final String id;
  final String name;
  final IconData icon;
  final int rows;
  final int cols;
  final List<ApplianceButton> buttons;

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
