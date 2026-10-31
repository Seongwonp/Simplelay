import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/models/hub.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/add_appliance_wizard_screen.dart';
import 'package:simplelay/screens/appliance_editor_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/appliance_setup_card.dart';
import '../helpers/test_helpers.dart';

void main() {
  testWidgets('종류 이름을 채우고 나가기 취소와 사진 없는 전환에서 입력을 지켜요', (tester) async {
    tester.view.physicalSize = const Size(600, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const Scaffold(body: Text('홈'))),
      GoRoute(path: '/add', builder: (_, __) => const AddApplianceWizardScreen()),
      GoRoute(path: '/appliance/new', builder: (_, s) => ApplianceEditorScreen(draft: s.extra as ApplianceDraft)),
    ]);
    final api = RpiApiService('http://rpi5.local:8000',
        client: MockClient((_) async => http.Response('{"found": true, "kit_id": "kit-a"}', 200)));
    await tester.pumpWidget(buildWithProviderState(
      overrides: [...connectedOverrides(), rpiServerOverride(RpiConnectionState.connected), rpiApiServiceProvider.overrideWithValue(api)],
      child: MaterialApp.router(routerConfig: router),
    ));
    router.push('/add');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('wizard-next')));
    await tester.pumpAndSettle();
    // 가전 그림 통일(10/24): 종류는 ChoiceChip 대신 그림 카드('kind-<value>')로 고른다.
    final washer = ApplianceCategory.washingMachine.value;
    await tester.tap(find.byKey(Key('kind-$washer')));
    await tester.pump();
    expect(find.byKey(Key('kind-selected-$washer')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('wizard-name'))).controller!.text, '세탁기');
    await tester.enterText(find.byKey(const Key('wizard-name')), '내 세탁기');
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않고 나가기'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '계속 고치기'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('wizard-name'))).controller!.text, '내 세탁기');
    await tester.tap(find.text('사진 없이 버튼판으로 등록하기'));
    await tester.pumpAndSettle();
    expect(find.byType(ApplianceEditorScreen), findsOneWidget);
    expect(find.text('내 세탁기'), findsWidgets);
    expect(find.text('버튼판 사진 찍기'), findsNothing);
  });

  testWidgets('등록 뒤 위치와 주행 두 가지를 홈 카드에서 이어가요', (tester) async {
    final appliance = ApplianceMap.fromJson({...kApplianceTemplates.first.toJson(), 'id': 'custom_test'});
    await tester.pumpWidget(ProviderScope(overrides: [
      setupPassProvider(appliance.id)
          .overrideWith((_) async => const VerifyPassLookup.unknown()),
    ], child: MaterialApp(home: Scaffold(body: ApplianceSetupCard(appliance: appliance)))));
    await tester.pumpAndSettle();
    expect(findPlainText('전자레인지, 설정이 2개 남았어요'), findsOneWidget);
    expect(find.text('버튼 자리 맞추기'), findsOneWidget);
  });
}
