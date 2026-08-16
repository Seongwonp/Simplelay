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

  factory ApplianceButton.fromJson(Map<String, dynamic> json) => ApplianceButton(
        id: json['id'] as String,
        label: json['label'] as String,
        x: json['x'] as int,
        y: json['y'] as int,
      );

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'x': x, 'y': y};
}

// 내장 가전(전자레인지/인덕션)은 백엔드 규칙 기반 의도 해석기에 목적→버튼 매핑이
// 있어서 음성 명령이 되지만, 사용자가 새로 등록한 가전(isCustom)은 그 매핑이
// 없으므로 버튼을 직접 탭해서 실행하는 수동 모드로만 동작한다.
class ApplianceMap {
  const ApplianceMap({
    required this.id,
    required this.name,
    required this.icon,
    required this.rows,
    required this.cols,
    required this.buttons,
    this.isCustom = false,
  });

  final String id;
  final String name;
  final IconData icon;
  final int rows;
  final int cols;
  final List<ApplianceButton> buttons;
  final bool isCustom;

  ApplianceButton? buttonAt(int x, int y) {
    try {
      return buttons.firstWhere((b) => b.x == x && b.y == y);
    } catch (_) {
      return null;
    }
  }

  String labelFor(String buttonId) {
    try {
      return buttons.firstWhere((b) => b.id == buttonId).label;
    } catch (_) {
      return buttonId;
    }
  }

  // 아이콘은 코드포인트로 직렬화하면 릴리즈 빌드의 아이콘 트리셰이킹이 깨질 수
  // 있어서, 커스텀 가전은 항상 고정 아이콘을 쓰고 저장/복원 대상에서 제외한다.
  factory ApplianceMap.fromJson(Map<String, dynamic> json) => ApplianceMap(
        id: json['id'] as String,
        name: json['name'] as String,
        icon: Icons.widgets_outlined,
        rows: json['rows'] as int,
        cols: json['cols'] as int,
        buttons: (json['buttons'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map(ApplianceButton.fromJson)
            .toList(),
        isCustom: true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'rows': rows,
        'cols': cols,
        'buttons': buttons.map((b) => b.toJson()).toList(),
      };
}

const kAppliances = <ApplianceMap>[
  ApplianceMap(
    id: 'microwave',
    name: '전자레인지',
    icon: Icons.microwave,
    rows: 4,
    cols: 3,
    buttons: [
      ApplianceButton(id: 'BT-01', label: '10초',    x: 0, y: 0),
      ApplianceButton(id: 'BT-02', label: '30초',    x: 1, y: 0),
      ApplianceButton(id: 'BT-03', label: '1분',     x: 2, y: 0),
      ApplianceButton(id: 'BT-04', label: '5분',     x: 0, y: 1),
      ApplianceButton(id: 'BT-07', label: '해동',    x: 0, y: 2),
      ApplianceButton(id: 'BT-08', label: '우유',    x: 1, y: 2),
      ApplianceButton(id: 'BT-09', label: '자동조리', x: 2, y: 2),
      ApplianceButton(id: 'BT-06', label: '취소',    x: 1, y: 3),
      ApplianceButton(id: 'BT-05', label: '시작',    x: 2, y: 3),
    ],
  ),
  ApplianceMap(
    id: 'induction',
    name: '인덕션',
    icon: Icons.soup_kitchen,
    rows: 3,
    cols: 4,
    buttons: [
      ApplianceButton(id: 'IN-01', label: '전원',  x: 0, y: 0),
      ApplianceButton(id: 'IN-02', label: '화력+', x: 1, y: 0),
      ApplianceButton(id: 'IN-03', label: '화력-', x: 2, y: 0),
      ApplianceButton(id: 'IN-04', label: '타이머', x: 3, y: 0),
      ApplianceButton(id: 'IN-05', label: '1단',   x: 0, y: 1),
      ApplianceButton(id: 'IN-06', label: '3단',   x: 1, y: 1),
      ApplianceButton(id: 'IN-07', label: '5단',   x: 2, y: 1),
      ApplianceButton(id: 'IN-08', label: '보온',  x: 3, y: 1),
      ApplianceButton(id: 'IN-09', label: '시작',  x: 2, y: 2),
      ApplianceButton(id: 'IN-10', label: '취소',  x: 3, y: 2),
    ],
  ),
];
