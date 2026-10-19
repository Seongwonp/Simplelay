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

/// 이 기기 현지 시각 '오후 10:04' — 폰의 시각 꼴(평가 8차 10/18).
String _hhmm(DateTime t) {
  final l = t.toLocal();
  final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
  return '${l.hour < 12 ? '오전' : '오후'} $h12:${l.minute.toString().padLeft(2, '0')}';
}

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  // 서버는 UTC 오프셋이 붙은 ISO 시각을 준다 — 화면은 이 기기 현지 시각으로 적는다.
  final until = DateTime.now().add(const Duration(minutes: 90)).toUtc();

  testWidgets('홈 배너: 방해 금지 켜짐. 끝나는 시각까지, 남은 시간, 범위', (tester) async {
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
    expect(findPlainText('방해 금지 켜짐. ${_hhmm(until)}까지, ', contains: true), findsOneWidget);
    expect(findPlainText('남았어요. 새 제안과 자동으로 하는 일을 잠시 쉬어요. 직접 하기와 정지는 그대로예요.', contains: true), findsOneWidget);
  });

  testWidgets('설정 줄: 켜져 있으면 "HH:MM까지 켜져 있어요"와 범위', (tester) async {
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
    // 첫 화면 한 줄의 지금 값은 끝나는 시각.
    expect(find.descendant(
            of: find.byKey(const Key('settings-row-dnd')), matching: findPlainText('${_hhmm(until)}까지')),
        findsOneWidget);
    await openSettingRow(tester, 'dnd');
    expect(findPlainText('${_hhmm(until)}까지 켜져 있어요. 새 제안과 자동으로 하는 일을 잠시 쉬어요.'), findsOneWidget);
    expect(findPlainText('방해 금지 끄기'), findsOneWidget);
  });
}
