// 잠시 쉬기 — '언제까지 쉬는지'(끝나는 시각) 표시(2026-10-14 4·5번 마감 확인 A5).
// 남은 시간("1시간 30분 남음")만 있으면 사용자가 지금 시각에 더해 셈해야 한다. 홈 배너와 설정 줄에 끝 시각을 함께 적는다.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/screens/settings_screen.dart';

import '../helpers/test_helpers.dart';

class _FixedDnd extends DndNotifier {
  _FixedDnd(super.ref, DateTime until) {
    state = until;
  }
}

String _hhmm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  // 서버는 UTC 오프셋이 붙은 ISO 시각을 준다 — 화면은 이 기기 현지 시각으로 적는다.
  final until = DateTime.now().add(const Duration(minutes: 90)).toUtc();

  testWidgets('홈 배너: 방해 금지 중 · 끝나는 시각까지 · 남은 시간', (tester) async {
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const HomeScreen(),
      overrides: [
        ...connectedOverrides(),
        ...installedOverrides([kTestAppliance]),
        rpiServerOverride(RpiConnectionState.connected),
        dndProvider.overrideWith((ref) => _FixedDnd(ref, until)),
      ],
    ));
    await tester.pump();
    expect(find.textContaining('방해 금지 중 · ${_hhmm(until)}까지 · '), findsOneWidget);
    expect(find.textContaining('남음'), findsOneWidget);
  });

  testWidgets('설정 줄: 켜져 있으면 "HH:MM까지 새 제안과 자동 실행을 쉬어요"', (tester) async {
    _tall(tester);
    await tester.pumpWidget(buildScreen(
      const SettingsScreen(),
      overrides: [
        scanResultsProvider.overrideWith((ref) => Stream.value(const <ScanResult>[])),
        ...installedOverrides([kTestAppliance]),
        rpiApiServiceProvider.overrideWithValue(null),
        dndProvider.overrideWith((ref) => _FixedDnd(ref, until)),
      ],
    ));
    await tester.pump();
    expect(find.text('${_hhmm(until)}까지 새 제안과 자동 실행을 쉬어요'), findsOneWidget);
    expect(find.text('지금 받기'), findsOneWidget);
  });
}
