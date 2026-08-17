import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/appliance.dart';
import 'package:simplelay/providers/appliance_provider.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/providers/voice_provider.dart';
import 'package:simplelay/screens/voice_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

const _testAppliance = ApplianceMap(
  id: 'custom_test',
  name: '테스트가전',
  icon: Icons.widgets_outlined,
  rows: 1,
  cols: 2,
  isCustom: true,
  buttons: [
    ApplianceButton(id: 'b1', label: '켜기', x: 0, y: 0),
    ApplianceButton(id: 'b2', label: '끄기', x: 1, y: 0),
  ],
);

Widget _buildScreen(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: VoiceScreen()),
    );

Future<ProviderContainer> _makeContainer({
  List<Override> extra = const [],
}) async {
  final container = ProviderContainer(overrides: extra);
  addTearDown(container.dispose);
  await container.read(customAppliancesProvider.notifier).ensureLoaded();
  return container;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('내장 가전 선택 시 (기존 동작 유지)', () {
    testWidgets('힌트는 "우유 데워줘" 예시를 보여준다', (tester) async {
      final container = await _makeContainer();
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      expect(find.text('예: 우유 데워줘'), findsOneWidget);
    });

    testWidgets('전송 시 /execute를 호출한다', (tester) async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode({'status': 'succeeded', 'buttons': []})),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await _makeContainer(
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      container.read(voiceTextProvider.notifier).state = '우유 데워줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('지금 전송'));
      await tester.pump();

      expect(captured!.url.path, '/execute');
      expect(jsonDecode(captured!.body), {'text': '우유 데워줘', 'source': 'voice'});
    });
  });

  group('사용자 정의 가전 선택 시', () {
    Future<ProviderContainer> makeCustomContainer({
      List<Override> extra = const [],
    }) async {
      final container = await _makeContainer(extra: extra);
      await container.read(customAppliancesProvider.notifier).add(_testAppliance);
      await container
          .read(selectedApplianceProvider.notifier)
          .select(_testAppliance);
      return container;
    }

    testWidgets('힌트가 등록된 실제 버튼 라벨로 바뀐다', (tester) async {
      final container = await makeCustomContainer();
      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();

      expect(find.text('예: 켜기 해줘'), findsOneWidget);
      expect(find.text('예: 우유 데워줘'), findsNothing);
    });

    testWidgets('RPi 연결이 없으면 안내만 뜨고 전송하지 않는다', (tester) async {
      final container = await makeCustomContainer();
      container.read(voiceTextProvider.notifier).state = '켜줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('지금 전송'));
      await tester.pump();

      expect(
        find.text('사용자 정의 가전의 음성 명령은 RPi5 서버 연결이 필요해요. 설정에서 URL을 확인하세요.'),
        findsOneWidget,
      );
    });

    testWidgets('전송 시 /execute-for-appliance를 등록된 버튼 어휘와 함께 호출한다',
        (tester) async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'status': 'succeeded',
            'buttons': [
              {'button': '켜기', 'success': true},
            ],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await makeCustomContainer(
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      container.read(voiceTextProvider.notifier).state = '켜줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('지금 전송'));
      await tester.pump();

      expect(captured!.url.path, '/execute-for-appliance');
      expect(jsonDecode(captured!.body), {
        'text': '켜줘',
        'known_buttons': ['켜기', '끄기'],
      });
    });

    testWidgets('LLM 미설정 등으로 503이 오면 오류 메시지를 보여준다', (tester) async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'detail': 'no LLM client configured'}),
          503,
        ),
      );
      final api = RpiApiService('http://rpi5.local:8000', client: client);
      final container = await makeCustomContainer(
        extra: [rpiApiServiceProvider.overrideWithValue(api)],
      );
      container.read(voiceTextProvider.notifier).state = '켜줘';

      await tester.pumpWidget(_buildScreen(container));
      await tester.pump();
      await tester.tap(find.text('지금 전송'));
      await tester.pump();

      expect(find.textContaining('no LLM client configured'), findsOneWidget);
    });
  });
}
