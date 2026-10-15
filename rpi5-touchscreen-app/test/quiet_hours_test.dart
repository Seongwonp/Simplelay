// 조용한 시간(2026-10-14, 5번) — 키오스크가 폰과 같은 서버 상태(/health/detail의 quiet)를 보이고, 실제 범위만 말한다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/dnd_overlay.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';

const _quietJson = {
  'ok': true,
  'actuator_ready': true,
  'dnd_until': null,
  'quiet': {
    'enabled': true,
    'start': '22:00',
    'end': '07:00',
    'active': true,
    'reason': 'schedule',
    'pause_until': null,
    'scope': '새 제안과 일반 안내 소리만 쉬어요. 아직 시작하지 않은 자동 실행은 건너뛰고 나중에 다시 하지 않아요.',
  },
};

void main() {
  test('/health/detail의 quiet를 읽는다(받지 못하면 꺼짐·준비됨으로 보지 않는다)', () {
    final h = HealthStatus.fromJson(_quietJson);
    expect(h.quietActive, isTrue);
    expect(h.quietKnown, isTrue);
    expect(h.speakGeneral, isFalse);
    expect(h.quietSchedule, ('22:00', '07:00'));
    expect(h.quietScheduleActive, isTrue);
    // 2026-10-14 보안 점검: 공개 /health처럼 quiet·actuator_ready가 없는 응답은 '모름' — 일반 안내 소리를 쉬고 준비 안 됨.
    final missing = HealthStatus.fromJson(const {'ok': true, 'version': '0.1.0'});
    expect(missing.quietActive, isFalse);
    expect(missing.quietKnown, isFalse);
    expect(missing.speakGeneral, isFalse);
    expect(missing.actuatorReady, isFalse);
    expect(missing.quietSchedule, isNull);
    expect(HealthStatus.disconnected.speakGeneral, isFalse);
    final off = HealthStatus.fromJson(const {
      'ok': true, 'actuator_ready': true,
      'quiet': {'enabled': false, 'start': '22:00', 'end': '07:00', 'active': false, 'reason': null},
    });
    expect(off.speakGeneral, isTrue);
    expect(off.actuatorReady, isTrue);
  });

  test('checkHealth는 인증 경로 /health/detail을 부른다(공개 /health는 생존·버전만)', () async {
    final paths = <String>[];
    final api = http.runWithClient(() => KioskApiService(baseUrl: 'http://hub.test'), () => MockClient((r) async {
          paths.add(r.url.path);
          if (r.url.path != '/health/detail') {
            return http.Response(jsonEncode({'ok': true, 'version': '0.1.0'}), 200);
          }
          return http.Response.bytes(utf8.encode(jsonEncode(_quietJson)), 200,
              headers: {'content-type': 'application/json'});
        }));
    final h = await api.checkHealth();
    expect(paths, ['/health/detail']);
    expect(h.quietActive, isTrue);
    expect(h.quietKnown, isTrue);
  });

  // 배포 전 확인(2026-10-14 인계 4번) — 실패 네 종류 모두 연결 끊김(준비 안 됨·조용한 시간 모름)이지 준비됨이 아니다.
  // 타임아웃은 4초를 실제로 기다리지 않고 .timeout()이 던지는 TimeoutException을 그대로 흉내 낸다.
  final failures = <String, Future<http.Response> Function()>{
    '401': () async => http.Response('{"detail":"invalid or missing API key"}', 401),
    '연결 실패': () async => throw const SocketException('connection refused'),
    '타임아웃': () async => throw TimeoutException('health/detail'),
    '해석 실패': () async => http.Response('<html>proxy error</html>', 200),
  };
  for (final entry in failures.entries) {
    test('checkHealth: ${entry.key}면 준비됨으로 보지 않는다', () async {
      final api = http.runWithClient(
          () => KioskApiService(baseUrl: 'http://hub.test'), () => MockClient((_) => entry.value()));
      final h = await api.checkHealth();
      expect(h.ok, isFalse);
      expect(h.actuatorReady, isFalse);
      expect(h.quietKnown, isFalse);
    });
  }

  testWidgets('평소 화면: 매일 조용한 시간이면 위 줄 칩이 "조용한 시간 · 07:00까지"', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KioskIdleView(
          now: DateTime(2026, 10, 14, 23, 5),
          connected: true,
          appliances: const [kMicrowaveAppliance],
          quietUntil: '07:00',
          onSelectAppliance: (_) {},
          onOpenConnection: (_) {},
          onDndGesture: () {},
        ),
      ),
    ));
    expect(find.text('조용한 시간'), findsOneWidget);
    expect(find.text('07:00까지'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^조용한 시간, 07:00까지')), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('방해 금지 창: 실제 범위만 말하고, 매일 시간대를 보인다(바꾸기는 폰)', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DndOverlay(
          dndUntil: null,
          quietSchedule: ('22:00', '07:00'),
          onSet: (_) {},
          onClear: () {},
          onDismiss: () {},
        ),
      ),
    ));
    expect(find.text('새 제안과 자동 실행을 잠시 쉬어요'), findsOneWidget);
    expect(find.text('매일 22:00~07:00 조용한 시간 · 바꾸기는 폰 설정에서'), findsOneWidget);
    expect(find.textContaining('모든'), findsNothing);
    expect(find.textContaining('사용 습관 제안'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 2026-10-14 4·5번 마감 확인 A5: 잠시 쉬기가 켜져 있으면 '언제까지'(끝나는 시각)를 함께 적는다.
  testWidgets('방해 금지 창: 켜져 있으면 끝나는 시각까지 쉰다고 적는다', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DndOverlay(
          dndUntil: DateTime(2026, 10, 14, 23, 30),
          onSet: (_) {},
          onClear: () {},
          onDismiss: () {},
        ),
      ),
    ));
    expect(find.text('23:30까지 새 제안과 자동 실행을 쉬고 있어요'), findsOneWidget);
    expect(find.text('다시 제안 받기'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
