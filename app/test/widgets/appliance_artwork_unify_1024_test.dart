// 가전 그림 통일 1단계(2026-10-24) — 종류 고르기와 저장 동작 아이콘이 홈과 같은 그림을 쓴다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/widgets/appliance_artwork.dart';
import 'package:simplelay/widgets/appliance_kind_picker.dart';
import 'package:simplelay/widgets/routine_icon.dart';

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  testWidgets('종류 고르기는 종류마다 가전 그림과 이름을 보이고, 고른 칸을 낭독·표시로 알린다', (tester) async {
    var picked = ApplianceCategory.microwave;
    await tester.pumpWidget(_wrap(StatefulBuilder(
      builder: (context, setState) => ApplianceKindPicker(
        selected: picked,
        onSelected: (c) => setState(() => picked = c),
      ),
    )));
    for (final c in ApplianceCategory.values) {
      expect(find.byKey(Key('appliance-artwork-${c.value}')), findsOneWidget,
          reason: '${c.label} 그림');
      expect(find.text(c.label), findsOneWidget);
    }
    expect(find.byKey(const Key('kind-selected-microwave')), findsOneWidget);
    final other = ApplianceCategory.values.last;
    await tester.tap(find.byKey(Key('kind-${other.value}')));
    await tester.pump();
    expect(picked, other);
    expect(find.byKey(Key('kind-selected-${other.value}')), findsOneWidget);
    expect(find.byKey(const Key('kind-selected-microwave')), findsNothing);
    expect(
      tester.getSemantics(find.byKey(Key('kind-${other.value}'))),
      matchesSemantics(
          label: other.label,
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasTapAction: true),
    );
  });

  testWidgets('저장 동작 아이콘은 대상 가전 그림을 그린다(둘이면 둘 다)', (tester) async {
    final routine = Routine.fromJson({
      'id': 'r1',
      'name': '아침',
      'mode': 'approve',
      'trigger': {'kind': 'manual'},
      'steps': [
        {'kind': 'press_sequence', 'appliance_id': 'm', 'buttons': ['시작']},
        {'kind': 'press_sequence', 'appliance_id': 'w', 'buttons': ['시작']},
      ],
    });
    await tester.pumpWidget(_wrap(RoutineIcon(
      routine: routine,
      iconOf: const {
        'm': ApplianceCategory.microwave,
        'w': ApplianceCategory.washingMachine,
      },
      color: Colors.black,
    )));
    expect(find.byType(ApplianceArtwork), findsNWidgets(2));
    expect(find.byKey(const Key('appliance-artwork-microwave')), findsOneWidget);
    expect(find.byKey(const Key('appliance-artwork-washing_machine')), findsOneWidget);
  });
}
