// 실행 화면 — 지금 누르는 버튼과 상태가 가장 크고, 진행은 단계로, 정지는
// 색을 빼도 알아본다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/executing_view.dart';

Future<void> _pump(
  WidgetTester tester, {
  String? button = '해동',
  int? attempt = 1,
  int? completed = 1,
  int? total,
  double? confidence,
  String? detail,
  ApplianceMap? target,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: KioskExecutingView(
          title: '즉석밥 데워줘',
          target: target,
          lastButtons: null,
          currentButton: button,
          currentAttempt: attempt,
          completedSteps: completed,
          totalSteps: total,
          verificationConfidence: confidence,
          verificationDetail: detail,
          onStop: () {},
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('버튼·누르는 중·총 N단계 중 K단계·대상 가전을 보여준다', (tester) async {
    await _pump(tester, total: 3, target: kMicrowaveAppliance);

    expect(find.text("'해동'"), findsOneWidget);
    expect(find.text('누르는 중'), findsOneWidget);
    expect(find.text('총 3단계 중 1단계'), findsOneWidget);
    expect(find.text('전자레인지'), findsOneWidget);
    // 시간으로 채우는 퍼센트가 아니다.
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('검증 근거가 오면 눌림 확인 중이고, 원시 수치는 작은 한 줄이다',
      (tester) async {
    await _pump(tester, confidence: 0.93, detail: '전류 +14mA · 소리 +9dB');

    expect(find.text('눌림 확인 중'), findsOneWidget);
    final evidence =
        tester.widget<Text>(find.text('전류 +14mA · 소리 +9dB · 센서 93%'));
    expect(evidence.style!.fontSize, lessThan(24));
  });

  testWidgets('재시도는 실패가 아니라 보정으로 말하고 정지는 그대로 있다', (tester) async {
    await _pump(tester, attempt: 2);

    expect(find.text('보정 후 다시 시도 중'), findsOneWidget);
    expect(find.byIcon(Icons.autorenew), findsOneWidget);
    expect(find.textContaining('2번째 시도'), findsOneWidget);
    expect(find.textContaining('실패'), findsNothing);
    expect(find.text('긴급 정지'), findsOneWidget);
  });

  testWidgets('긴급 정지는 정지 기호·글자·두꺼운 외곽선을 가진다', (tester) async {
    await _pump(tester);

    expect(find.byIcon(Icons.stop), findsOneWidget);
    final finder = find.ancestor(
      of: find.text('긴급 정지'),
      matching: find.byType(ElevatedButton),
    );
    final button = tester.widget<ElevatedButton>(finder);
    final shape = button.style!.shape!.resolve({}) as RoundedRectangleBorder;
    expect(shape.side.width, greaterThanOrEqualTo(3));
    expect(tester.getSize(finder).height, greaterThanOrEqualTo(64));
  });

  testWidgets('긴급 정지는 짙은 빨강에 흰 글자다 — 연한 색은 비상으로 읽히지 않았다',
      (tester) async {
    await _pump(tester);
    final button = tester.widget<ElevatedButton>(find.ancestor(
      of: find.text('긴급 정지'),
      matching: find.byType(ElevatedButton),
    ));
    expect(button.style!.backgroundColor!.resolve({}), KioskColors.stop);
    expect(button.style!.foregroundColor!.resolve({}), Colors.white);
  });

  testWidgets('대상 가전의 버튼판에서 지금 누르는 버튼을 가리킨다', (tester) async {
    await _pump(tester, total: 3, target: kMicrowaveAppliance);

    expect(find.text('지금 누르는 버튼'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('panel-current')),
        matching: find.text('해동'),
      ),
      findsOneWidget,
    );
    // 버튼판은 가전 버튼 전부를 자리대로 그린다.
    expect(find.text('냉동식품'), findsOneWidget);
    // 버튼판은 오른쪽, 지금 버튼 이름은 왼쪽.
    expect(tester.getCenter(find.text('해동')).dx,
        greaterThan(tester.getCenter(find.text("'해동'")).dx));
  });

  testWidgets('버튼판에서 자리를 찾을 수 없으면 그림을 지어내지 않는다', (tester) async {
    // 서버가 준 이름이 대상 가전에 없다(다른 이름·옛 버튼맵).
    await _pump(tester, button: '시간 90초', target: kMicrowaveAppliance);
    expect(find.text('지금 누르는 버튼'), findsNothing);
    // 대상 가전을 모를 때도.
    await _pump(tester, button: '해동');
    expect(find.text('지금 누르는 버튼'), findsNothing);
  });

  testWidgets('같은 이름의 버튼이 둘이면 어느 쪽인지 지어내지 않는다', (tester) async {
    // 서버는 버튼 이름만 준다. 이름이 두 번 나오면 틀린 자리를 가리킬 수 있다.
    const twin = ApplianceMap(
      id: 'twin',
      name: '쌍둥이 버튼 가전',
      category: 'other',
      rows: 1,
      cols: 2,
      buttons: [
        ApplianceButton(id: 'T-1', label: '시작', x: 0, y: 0),
        ApplianceButton(id: 'T-2', label: '시작', x: 1, y: 0),
      ],
    );
    await _pump(tester, button: '시작', target: twin);
    expect(find.text('지금 누르는 버튼'), findsNothing);
    expect(find.byKey(const ValueKey('panel-current')), findsNothing);
  });

  testWidgets('재시도 중에는 진행 막대의 지금 칸도 주의색이다', (tester) async {
    Color currentBorder() {
      final box = tester.widget<Container>(
          find.byKey(const ValueKey('segment-current')));
      return ((box.decoration! as BoxDecoration).border! as Border).top.color;
    }

    await _pump(tester, attempt: 2, completed: 1, total: 3);
    expect(currentBorder(), KioskColors.warning);
    await _pump(tester, attempt: 1, completed: 1, total: 3);
    expect(currentBorder(), KioskColors.primary);
  });

  testWidgets('서버가 단계 수를 안 주면 진행을 지어내지 않는다', (tester) async {
    await _pump(tester, completed: 2);

    expect(find.textContaining('단계 중'), findsNothing);
    expect(find.text('2단계 완료'), findsOneWidget);
  });

  testWidgets('큰 글씨에서도 넘치지 않는다', (tester) async {
    await _pump(
      tester,
      attempt: 3,
      total: 6,
      confidence: 0.41,
      detail: '전류 +2mA · 소리 +1dB',
      target: kMicrowaveAppliance,
      textScale: 1.22,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('긴급 정지'), findsOneWidget);
  });

  test('서버가 준 실행 대상 가전을 받는다', () {
    final st = KioskStatus.fromJson({
      'running': true,
      'job_id': 'j1',
      'appliance_id': 'custom_fan',
    });
    expect(st.applianceId, 'custom_fan');
    expect(
      KioskStatus.fromJson({'running': false, 'last_appliance_id': 'a1'})
          .lastApplianceId,
      'a1',
    );
  });
}
