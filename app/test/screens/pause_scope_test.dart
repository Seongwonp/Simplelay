// 잠시 쉬기 범위 문구(2026-10-14 마감 2번) — 화면이 실제 범위만 말한다.
// 업데이트 뒤 켠 잠시 쉬기: 새 제안 + 아직 시작하지 않은 자동 실행. 업데이트 전 서버에서 켠 것을 이어받은 동안:
// 새 제안만(자동 실행은 그대로). 서버 /health/detail `dnd_scope`로 가른다.
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

class _FixedDnd extends DndNotifier {
  _FixedDnd(super.ref, DateTime? until) {
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

Future<void> _settings(WidgetTester tester, DateTime? until, String? scope) async {
  _tall(tester);
  await tester.pumpWidget(buildScreen(
    const SettingsScreen(),
    overrides: [
      scanResultsProvider.overrideWith((ref) => Stream.value(const <ScanResult>[])),
      ...installedOverrides([kTestAppliance]),
      rpiApiServiceProvider.overrideWithValue(null),
      dndProvider.overrideWith((ref) => _FixedDnd(ref, until)),
      dndScopeProvider.overrideWith((ref) => scope),
    ],
  ));
  await tester.pump();
  await openSettingRow(tester, 'dnd');
}

void main() {
  final until = DateTime.now().add(const Duration(minutes: 50)).toUtc();

  test('health/detail의 dnd_scope를 읽는다(없으면 null)', () {
    final carried = RpiHealthData.fromJson({
      'ok': true, 'actuator_ready': true,
      'dnd_until': until.toIso8601String(), 'dnd_scope': 'suggestions_only',
    });
    expect(carried.dndScope, 'suggestions_only');
    expect(RpiHealthData.fromJson({'ok': true, 'actuator_ready': true}).dndScope, isNull);
  });

  testWidgets('이어받은 잠시 쉬기(옛 범위): "HH:MM까지 새 제안만 쉬어요" — 자동 실행은 그대로라고 말한다', (tester) async {
    await _settings(tester, until, 'suggestions_only');
    expect(findPlainText('${_hhmm(until)}까지 묻지만 않아요. 예전에 켠 설정이라 자동으로 하는 일은 그대로 해요'),
        findsOneWidget);
    expect(findPlainText('묻지도, 자동으로 하지도 않아요', contains: true), findsNothing);
  });

  testWidgets('업데이트 뒤 켠 잠시 쉬기(새 범위): "HH:MM까지 묻지도, 자동으로 하지도 않아요"', (tester) async {
    await _settings(tester, until, 'suggestions_and_auto');
    expect(findPlainText('${_hhmm(until)}까지 묻지도, 자동으로 하지도 않아요'), findsOneWidget);
  });

  testWidgets('시간 고르기 창의 선택지도 새 범위를 말한다(제안만 숨긴다고 하지 않음)', (tester) async {
    await _settings(tester, null, null);
    await tester.tap(findPlainText('시간 고르기'));
    await tester.pumpAndSettle();
    expect(findPlainText('30분 동안 묻지도, 자동으로 하지도 않아요'), findsOneWidget);
    expect(findPlainText('1시간 동안 묻지도, 자동으로 하지도 않아요'), findsOneWidget);
    expect(findPlainText('2시간 동안 묻지도, 자동으로 하지도 않아요'), findsOneWidget);
    expect(findPlainText('사용 습관 제안을', contains: true), findsNothing);
  });
}
