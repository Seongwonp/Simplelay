import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/auto_rule.dart';
import 'package:simplelay/models/routine.dart';
import 'package:simplelay/providers/routine_provider.dart';
import 'package:simplelay/screens/routines_screen.dart';
import '../helpers/test_helpers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('예약과 조건을 한 화면에 표시하고 고아 시각 규칙도 남긴다', (tester) async {
    tester.view.physicalSize = const Size(430, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scheduled = Routine.fromJson({
      'id': 'morning', 'name': '아침 공기청정기', 'enabled': true,
      'trigger': {'kind': 'time', 'time': '07:00'}, 'steps': [],
    });
    const condition = AutoRule(id: 'heat', name: '가열 후 환기',
      conditionText: '가열이 끝나면', actionText: '공기청정기 켜기',
      enabled: false, statusLabel: '꺼짐', conditionKind: 'heat_end');
    const orphan = AutoRule(id: 'orphan', name: '지워진 동작의 예약',
      conditionText: '오후 10시에', actionText: '공기청정기 끄기',
      enabled: true, statusLabel: '켜짐', conditionKind: 'time', conditionTime: '22:00');
    await tester.pumpWidget(buildScreen(const RoutinesScreen(automatic: true), overrides: [
      ...installedOverrides([]),
      routinesProvider.overrideWith((_) async => [scheduled]),
      automationRulesProvider.overrideWith((_) async => [condition, orphan]),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('정해진 시간'), findsOneWidget);
    expect(find.text('상황에 따라'), findsOneWidget);
    expect(find.byKey(const Key('routine-row-morning')), findsOneWidget);
    expect(find.byKey(const Key('auto-rule-heat')), findsOneWidget);
    expect(find.byKey(const Key('auto-rule-orphan')), findsOneWidget);
    expect(find.text('내 루틴'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('조회 실패는 조건 없음으로 표시하지 않는다', (tester) async {
    await tester.pumpWidget(buildScreen(const RoutinesScreen(automatic: true), overrides: [
      ...installedOverrides([]),
      routinesProvider.overrideWith((_) async => []),
      automationRulesProvider.overrideWith((_) async => throw Exception('offline')),
    ]));
    await tester.pumpAndSettle();
    expect(findPlainText('조건을 불러오지 못했어요', contains: true), findsOneWidget);
    expect(findPlainText('허용한 조건이 없어요', contains: true), findsNothing);
  });
}
