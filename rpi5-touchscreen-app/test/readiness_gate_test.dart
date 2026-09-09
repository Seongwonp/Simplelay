// F1 — 준비 안 된 가전은 조작판을 내주지 않는다.
//
// 등록됐다는 것과 조작할 수 있다는 것은 다르다. 주소는 맞는데 선이 안 꽂혀
// 있거나, 전송은 되는데 모터가 홈을 안 잡은 상태가 있다. 그때 버튼을 누를 수
// 있게 두면, 서버가 막은 것을 사용자는 **가전 고장으로 오해한다.**
//
// 서버도 412로 거절한다(이중 방어). 화면이 먼저 말하는 이유는 "왜 안 되는지"를
// 누르기 전에 알려주기 위해서다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

ApplianceMap _fan({
  bool canExecute = true,
  String readiness = 'operable',
  List<String> reasons = const [],
}) =>
    ApplianceMap(
      id: 'fan',
      name: '선풍기',
      icon: Icons.air,
      rows: 1,
      cols: 2,
      buttons: const [
        ApplianceButton(id: 'F-01', label: '전원', x: 0, y: 0),
        ApplianceButton(id: 'F-02', label: '바람세기', x: 1, y: 0),
      ],
      canExecute: canExecute,
      readiness: readiness,
      readinessReasons: reasons,
    );

Future<List<String>> _pressed(WidgetTester tester, ApplianceMap appliance) async {
  final tapped = <String>[];
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: KioskManualView(
        appliance: appliance,
        onExecute: (b) => tapped.add(b.label),
        onCancel: () {},
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('전원'));
  await tester.pump();
  return tapped;
}

void main() {
  testWidgets('준비된 가전은 종전대로 눌린다', (tester) async {
    expect(await _pressed(tester, _fan()), ['전원']);
  });

  testWidgets('준비 안 된 가전은 탭이 실행으로 이어지지 않는다', (tester) async {
    final tapped = await _pressed(
      tester,
      _fan(canExecute: false, readiness: 'needs_setup'),
    );

    expect(tapped, isEmpty, reason: '누를 수 있는데 안 되는 버튼을 두지 않는다');
  });

  testWidgets('무엇이 남았는지 함께 말한다', (tester) async {
    // "안 됩니다"만 알리면 사용자가 할 수 있는 일이 없다.
    await _pressed(
      tester,
      _fan(
        canExecute: false,
        readiness: 'needs_setup',
        reasons: const ['눌림을 확인할 센서가 아직 준비되지 않았어요'],
      ),
    );

    expect(find.text('아직 준비가 끝나지 않았어요'), findsOneWidget);
    expect(
      find.text('눌림을 확인할 센서가 아직 준비되지 않았어요'),
      findsOneWidget,
    );
  });

  testWidgets('연결 자체가 안 된 경우와 준비 미완을 구분해 말한다', (tester) async {
    await _pressed(
      tester,
      _fan(canExecute: false, readiness: 'disconnected'),
    );

    expect(find.text('아직 연결되지 않았어요'), findsOneWidget);
    expect(find.text('아직 준비가 끝나지 않았어요'), findsNothing);
  });

  testWidgets('서버 정보가 없으면 막지 않는다 — 오프라인 폴백', (tester) async {
    // 하드코딩 내장 가전에는 준비 상태가 없다. 모르는 것을 '안 됨'으로
    // 단정하면 서버가 죽었을 때 조작 수단이 통째로 사라진다.
    expect(await _pressed(tester, _fan(readiness: 'unknown')), ['전원']);
    expect(find.text('아직 연결되지 않았어요'), findsNothing);
  });

  test('서버 응답에 준비 상태가 없으면 operable이 아니라 unknown이다', () {
    // '확인된 조작 가능'과 '그냥 모름'을 같은 값으로 보면, 서버를 거치지
    // 않는 경로에서 둘을 구분할 수 없다.
    final parsed = applianceFromServerJson({
      'id': 'fan',
      'name': '선풍기',
      'rows': 1,
      'cols': 1,
      'buttons': [
        {'id': 'F-01', 'label': '전원', 'x': 0, 'y': 0},
      ],
    });

    expect(parsed.readiness, 'unknown');
    expect(parsed.canExecute, isTrue, reason: '막지는 않는다');
  });
}
