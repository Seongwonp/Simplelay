import 'package:flutter_test/flutter_test.dart';

import 'package:simplelay_touchscreen/main.dart';

void main() {
  testWidgets('idle screen renders without crashing', (tester) async {
    await tester.pumpWidget(const SimpleLayKioskApp());
    await tester.pump();

    expect(find.text('전자레인지'), findsOneWidget);
    expect(find.text('AI 모니터링 중'), findsOneWidget);
  });
}
