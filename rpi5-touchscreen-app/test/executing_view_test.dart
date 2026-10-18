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
  // 2026-10-15 B1: completed_steps는 끝낸 수 — 지금 누르는 번호는 끝낸 수 + 1.
  testWidgets('버튼·누르고 있어요·누를 버튼 N개 중 K번째·대상 가전을 보여준다', (tester) async {
    await _pump(tester, total: 3, target: kMicrowaveAppliance);

    expect(find.text('해동 버튼'), findsOneWidget);
    // 큰 버튼 이름이 무엇인지 이름표가 붙는다(외부 평가 10/16 2차 k05).
    // 시제를 가리지 않는 이름표 — 확인 중에도 맞는 말(외부 평가 10/16 3차).
    expect(find.text('이번 버튼'), findsNothing); // 이름표 대신 진행 줄이 위에서 말한다(10/18).
    expect(find.text('누르고 있어요'), findsOneWidget); // 결선 모의 평가 10/18 — 단계대로
    expect(find.text('누를 버튼 3개 중 2번째'), findsOneWidget);
    expect(find.textContaining('전자레인지'), findsOneWidget); // 위 띠(10/18)
    // 시간으로 채우는 퍼센트가 아니다.
    expect(find.textContaining('%'), findsNothing);
  });

  // 2026-10-15 §3-1: 숫자(mA·dB·%)는 화면에서 뺀다 — 무엇을 보고 있는지만 작은 한 줄로.
  testWidgets("검증 근거가 오면 '눌렀어요, 확인 중이에요', 숫자는 화면에 없다",
      (tester) async {
    await _pump(tester, confidence: 0.93, detail: '전류 +14mA · 소리 +9dB');

    expect(find.text('눌렀어요, 확인 중이에요'), findsOneWidget); // 결선 모의 평가 10/18 — 누른 뒤 확인 단계
    // 같은 뜻의 둘째 줄('가전이 켜지는지 보고 있어요')은 두지 않는다(평가 15차 10/18).
    expect(find.text('가전이 켜지는지 보고 있어요'), findsNothing);
    expect(find.textContaining('mA'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('재시도는 실패가 아니라 보정으로 말하고 정지는 그대로 있다', (tester) async {
    await _pump(tester, attempt: 2);

    expect(find.text('자리를 맞춰 다시 누르는 중'), findsOneWidget);
    expect(find.textContaining('눌렸는지 몰라서 한 번 더 눌러요'), findsOneWidget);
    expect(find.textContaining('보정'), findsNothing);
    expect(find.byIcon(Icons.autorenew), findsOneWidget);
    expect(find.textContaining('2번째 시도'), findsOneWidget);
    expect(find.textContaining('실패'), findsNothing);
    expect(find.text('정지'), findsOneWidget);
  });

  testWidgets('긴급 정지는 정지 기호·글자·두꺼운 외곽선을 가진다', (tester) async {
    await _pump(tester);

    expect(find.byIcon(Icons.stop), findsOneWidget);
    final finder = find.ancestor(
      of: find.text('정지'),
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
      of: find.text('정지'),
      matching: find.byType(ElevatedButton),
    ));
    expect(button.style!.backgroundColor!.resolve({}), KioskColors.stop);
    expect(button.style!.foregroundColor!.resolve({}), Colors.white);
  });

  testWidgets('대상 가전의 버튼판에서 지금 누르는 버튼을 가리킨다', (tester) async {
    await _pump(tester, total: 3, target: kMicrowaveAppliance);

    // 실행 중 버튼판 위 안내는 한 줄(출시 검토 10/18).
    expect(find.text('화면은 누르지 않아도 돼요'), findsOneWidget);
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
    expect(tester.getCenter(find.descendant(of: find.byKey(const ValueKey('panel-current')), matching: find.text('해동'))).dx,
        greaterThan(tester.getCenter(find.text('해동 버튼')).dx));
  });

  testWidgets('버튼판에서 자리를 찾을 수 없으면 그림을 지어내지 않는다', (tester) async {
    // 서버가 준 이름이 대상 가전에 없다(다른 이름·옛 버튼맵).
    // 휴리스틱 평가(10/18): 그림이 없거나 자리를 못 찾아도 '화면은 누르지 않아도 돼요'는 같은 자리에 남는다 — 채운 칸만 없다.
    await _pump(tester, button: '시간 90초', target: kMicrowaveAppliance);
    expect(find.byKey(const ValueKey('panel-current')), findsNothing);
    expect(find.textContaining('화면은 누르지 않아도 돼요'), findsOneWidget);
    // 대상 가전을 모를 때도.
    await _pump(tester, button: '해동');
    expect(find.byKey(const ValueKey('panel-current')), findsNothing);
    expect(find.textContaining('화면은 누르지 않아도 돼요'), findsOneWidget);
  });

  testWidgets('누를 수 없는 버튼판은 수동 조작 버튼처럼 칠하지 않는다', (tester) async {
    // 수동 조작 칸과 같은 면색·테두리면 눌러도 되는 버튼으로 보인다.
    await _pump(tester, total: 3, target: kMicrowaveAppliance);
    final other = tester.widget<DecoratedBox>(find
        .ancestor(of: find.text('10초'), matching: find.byType(DecoratedBox))
        .first);
    final box = other.decoration as BoxDecoration;
    // 설명 그림 스타일(2026-10-16 디자인 규격 §1-6): 칸 테두리 없음 · 어두운 평면(수동 조작 칸의 면색과 다름) ·
    // 글자 50% 회색. 수동 조작 칸은 면(surface) + 선명한 경계 + 밝은 글자다.
    expect(box.border, isNull);
    expect(box.color, isNot(KioskColors.surface));
    expect(tester.widget<Text>(find.text('10초')).style!.color, KioskColors.panelText);
    // 지금 누르는 칸만 진행색으로 채운다(앰버 강조는 주 행동 몫 — 화면 구조 개편 10/18).
    final current = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('panel-current')));
    expect((current.decoration as BoxDecoration).color, KioskColors.running);
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
    expect(find.byKey(const ValueKey('panel-current')), findsNothing);
    expect(find.byKey(const ValueKey('panel-pressed-T-1')), findsNothing);
    expect(find.byKey(const ValueKey('panel-pressed-T-2')), findsNothing);
  });

  testWidgets('재시도도 같은 단계 번호를 고정 표시하고 시도 횟수는 따로 알린다', (tester) async {
    await _pump(tester, attempt: 2, completed: 1, total: 3);
    expect(find.byKey(const ValueKey('execution-step')), findsOneWidget);
    expect(find.text('누를 버튼 3개 중 2번째'), findsOneWidget);
    expect(find.textContaining('2번째 시도'), findsOneWidget);
    expect(find.byKey(const ValueKey('segment-current')), findsNothing);
    await _pump(tester, attempt: 1, completed: 1, total: 3);
    expect(find.text('누를 버튼 3개 중 2번째'), findsOneWidget);
  });

  testWidgets('서버가 단계 수를 안 주면 진행을 지어내지 않는다', (tester) async {
    await _pump(tester, completed: 2);

    expect(find.textContaining('개 중'), findsNothing);
    expect(find.text('버튼 2개를 눌렀어요'), findsOneWidget);
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
    expect(find.text('정지'), findsOneWidget);
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

  testWidgets('real 실행에는 머리 표시를 달지 않고 실기기 검증처럼 읽히지 않는다',
      (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KioskExecutingView(
          executionMode: 'real',
          title: '즉석밥 데워줘',
          lastButtons: null,
          currentButton: '해동',
          currentAttempt: 1,
          completedSteps: 1,
          verificationConfidence: null,
          verificationDetail: null,
          onStop: () {},
        ),
      ),
    ));

    // 실제 실행은 평소라 따로 말하지 않는다(2026-10-14). 연습일 때만 '연습 모드'.
    expect(find.text('실제 장치로 실행'), findsNothing);
    expect(find.text('연습 모드'), findsNothing);
    expect(find.textContaining('실기기'), findsNothing);
  });
}
