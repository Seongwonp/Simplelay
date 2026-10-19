// 2026-10-14 HIGH 재확인 M-R1 — 잠시 쉬기 저장이 실패하면(서버 `persisted: false`) 200이어도 '이번 세션만 적용'을
// 사람 말로 알린다. 저장됨(true)·저장소 없음(null)·옛 서버(필드 없음)는 알리지 않는다.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/quiet_hours.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/services/rpi_api_service.dart';
import 'package:simplelay/widgets/dnd_bottom_sheet.dart';

RpiApiService _api(Object? persisted, List<String> calls) => RpiApiService('http://rpi5.local:8000',
    client: MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.url.path == '/dnd') {
        final body = <String, Object?>{'ok': true};
        if (persisted != 'absent') {
          body['persisted'] = persisted;
          body['session_only'] = persisted != true;
        }
        return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"detail":"not found"}', 404);
    }));

Widget _host(RpiApiService api) => ProviderScope(
      overrides: [rpiApiServiceProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDndSheet(context),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );

void main() {
  test('서비스는 /dnd 응답의 persisted를 그대로 돌려준다(없으면 null)', () async {
    for (final (persisted, expected) in [(true, true), (false, false), (null, null), ('absent', null)]) {
      final calls = <String>[];
      final api = _api(persisted, calls);
      expect(await api.setDnd(60), expected);
      expect(await api.clearDnd(), expected);
      expect(calls, ['POST /dnd', 'DELETE /dnd']);
    }
  });

  for (final (persisted, shown) in [(false, true), (true, false), (null, false), ('absent', false)]) {
    testWidgets('잠시 쉬기 켜기 — persisted=$persisted면 알림 ${shown ? '보임' : '없음'}', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(_host(_api(persisted, calls)));
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1시간'));
      await tester.pumpAndSettle();
      // 시트가 겹치는 자동 실행을 보이려고 규칙 목록을 읽는다(GET) — 바꾸는 요청 중 첫째가 POST /dnd.
      expect(calls.where((c) => !c.startsWith('GET ')).first, 'POST /dnd');
      expect(find.text(kSettingNotSavedNotice), shown ? findsOneWidget : findsNothing);
    });
  }

  // 검토 10/19(core6 12): 창을 먼저 닫고 기다려, 통신이 끊기면 예외가 새고 아무 말 없이 끝나 쉬는 줄 알았다.
  testWidgets('잠시 쉬기를 보내지 못하면 창을 두고 보내지 못했다고 말한다', (tester) async {
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
      if (req.url.path == '/dnd') throw http.ClientException('끊김');
      return http.Response('{"detail":"not found"}', 404);
    }));
    await tester.pumpWidget(_host(api));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1시간'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(kDndNotSentNotice), findsOneWidget);
    expect(find.text('30분'), findsOneWidget, reason: '창은 그대로 — 다시 누를 수 있다');
  });

  testWidgets('잠시 쉬기를 보내는 동안 다른 시간을 눌러도 한 번만 보낸다', (tester) async {
    final calls = <String>[];
    final api = RpiApiService('http://rpi5.local:8000', client: MockClient((req) async {
      calls.add('${req.method} ${req.url.path}');
      if (req.url.path == '/dnd') {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return http.Response.bytes(utf8.encode(jsonEncode({'ok': true, 'persisted': true})), 200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('{"detail":"not found"}', 404);
    }));
    await tester.pumpWidget(_host(api));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30분'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('1시간'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'POST /dnd'), hasLength(1));
    expect(find.text('30분'), findsNothing, reason: '본체가 받은 뒤 창을 닫는다');
  });
}
