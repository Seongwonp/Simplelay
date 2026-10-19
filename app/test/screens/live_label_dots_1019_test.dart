// 2026-10-19 에뮬레이터 점검: 실행 상태 화면의 화면 낭독 문장이 '…누르지 않았어요.. 됐어요'처럼
// 이미 마침표로 끝난 문장 뒤에 '. '를 또 붙여 점이 겹쳤다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/screens/status_screen.dart';

import '../helpers/test_helpers.dart';

void main() {
  testWidgets('끝난 실행의 낭독 문장에 마침표가 겹치지 않는다', (tester) async {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(buildScreen(const StatusScreen(),
        executionStatus: const ExecutionStatus(
          phase: ExecutionPhase.completed,
          outcome: 'success',
          route: 'physical',
          confirmation: 'reported',
          executionMode: 'mock',
          label: '30초',
        )));
    await tester.pump();

    final labels = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .map((s) => s.properties.label)
        .whereType<String>()
        .where((l) => l.contains('연습을 마쳤어요'))
        .toList();
    expect(labels, isNotEmpty);
    for (final l in labels) {
      expect(l.contains('..'), isFalse, reason: l);
      expect(l.contains('?.'), isFalse, reason: l);
    }
    handle.dispose();
  });
}
