// 실행 기록·실행 상태 화면의 결과/경로/확인 수준 표시(2026-09-29).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay/models/execution_status.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';
import 'package:simplelay/screens/history_screen.dart';
import 'package:simplelay/screens/status_screen.dart';
import 'package:simplelay/services/rpi_api_service.dart';

import '../helpers/test_helpers.dart';

RpiApiService _apiWithHistory(List<Map<String, dynamic>> entries) =>
    RpiApiService(
      'http://rpi5.local:8000',
      client: MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode(entries)),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

Map<String, dynamic> _entry(String id, Map<String, dynamic> extra) => {
      'job_id': id,
      'finished_at': '2026-09-29T19:30:00+09:00',
      'purpose': '목적 $id',
      'retry_count': 0,
      'buttons': <Map<String, dynamic>>[],
      'execution_mode': 'mock',
      ...extra,
    };

void main() {
  testWidgets('이력: 결과·경로·확인 수준 열을 outcome으로 말한다', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _apiWithHistory([
      _entry('t1', {
        'status': 'failed',
        'outcome': 'unconfirmed',
        'route': 'thinq',
        'receipt': 'accepted',
        'confirmation': 'none',
        'detail': '상태를 확인하지 못했어요',
        // 실제 경로의 수신 수준을 본다(모의 기록은 '연습' 한 줄만 말한다, 2026-10-14).
        'execution_mode': 'real',
      }),
      _entry('t2', {
        'status': 'succeeded',
        'outcome': 'success',
        'route': 'thinq',
        'receipt': 'accepted',
        'confirmation': 'state_confirmed',
      }),
      _entry('t3', {
        'status': 'failed',
        'outcome': 'unconfirmed',
        'route': 'thinq',
        'receipt': 'unknown',
        'confirmation': 'none',
        'execution_mode': 'real',
      }),
      _entry('p1', {
        'status': 'safety_stopped',
        'outcome': 'safety_stop',
        'termination': 'retries_exhausted',
        'route': 'physical',
        'receipt': 'accepted',
        'confirmation': 'reported',
      }),
      _entry('p2', {
        'status': 'safety_stopped',
        'outcome': 'stopped',
        'termination': 'stopped_by_user',
        'route': 'physical',
      }),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [rpiApiServiceProvider.overrideWithValue(api)],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();
    // 결과 문장은 행을 눌러 펼친다(2026-10-18).
    for (final e in find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('history-tap-')).evaluate().toList()) {
      await tester.tap(find.byKey(e.widget.key!));
      await tester.pump();
    }

    // ThinQ 확인 못 함은 실패로 말하지 않는다.
    // '확인 필요' 줄의 까닭 한 줄은 낱말 단위로 그린다(평가 10차 10/18) — 결합 문자를 빼고 본다.
    expect(findPlainText('설정이 바뀌었는지 확인하지 못했어요', contains: true), findsNWidgets(2));
    // 경로 · 확인 수준은 '경로'·'확인' 꼬리표 없이 자연스러운 한 줄로 말한다.
    expect(find.text('가전이 받았어요'), findsOneWidget);
    // t2는 모의 실행 — 결과 문장 한 줄이 연습이라고 말하고 수신 줄을 겹치지 않는다(2026-10-14).
    expect(find.text('ThinQ · 연습 상태 확인'), findsNothing);
    expect(find.text('연습이라 가전에 보내지 않았어요'), findsOneWidget);
    // 접수 불명은 받았는지 모른다고만 말한다(접수됨·확인됨으로 올리지 않는다,
    // 실패로도 말하지 않는다).
    expect(find.text('가전이 받았는지 확인하지 못했어요'), findsOneWidget);
    expect(find.textContaining('확인 받았는지'), findsNothing);
    expect(find.textContaining('확인 확인'), findsNothing);
    // t2는 모의 실행이다 — 실제 가전 확인 문장을 쓰지 않는다.
    expect(find.textContaining('가전 상태를 확인했어요'), findsNothing);
    expect(find.textContaining('스스로 멈췄어요'), findsOneWidget);
    expect(find.text('멈췄어요'), findsOneWidget);
    // ThinQ 기록에는 '버튼판에서 직접 누르기'을 내걸지 않는다(물리 실패 2건만).
    expect(find.text('버튼판에서 직접 누르기'), findsNWidgets(2));
  });

  testWidgets('이력: 연습(모의) 기록에는 서버 설명 줄("명령을 보냈어요 …")을 겹치지 않는다', (tester) async {
    // 10/14 실물 캡처: '연습이라 가전에 보내지 않았어요' 아래에 '명령을 보냈어요 — …'가 함께 나와 서로 어긋났다.
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _apiWithHistory([
      _entry('m1', {
        'status': 'failed',
        'outcome': 'unconfirmed',
        'route': 'thinq',
        'receipt': 'accepted',
        'confirmation': 'none',
        'detail': '명령을 보냈어요 — 보내기 전에도 같은 값이라 변경을 확인할 수 없어요',
      }),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [rpiApiServiceProvider.overrideWithValue(api)],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();
    // 결과 문장은 행을 눌러 펼친다(2026-10-18).
    for (final e in find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('history-tap-')).evaluate().toList()) {
      await tester.tap(find.byKey(e.widget.key!));
      await tester.pump();
    }
    expect(find.text('연습이라 가전에 보내지 않았어요'), findsOneWidget);
    expect(find.textContaining('명령을 보냈어요'), findsNothing);
  });

  testWidgets('이력: 실제/연습을 모르는 기록은 성공 문장만 두지 않고 "실제 가전이 움직였는지 확인하지 못했어요"를 남긴다',
      (tester) async {
    // 10/14 Codex 의견: 일반 화면에서 '실행 환경 미확인'을 지워도 기록에서는 실제 성공처럼 보이면 안 된다(F4 경계).
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _apiWithHistory([
      _entry('u1', {
        'status': 'succeeded',
        'outcome': 'success',
        'route': 'physical',
        'receipt': 'accepted',
        'confirmation': 'reported',
        'execution_mode': 'unknown',
      }),
      _entry('m1', {
        'status': 'succeeded',
        'outcome': 'success',
        'route': 'physical',
        'execution_mode': 'mock',
      }),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [rpiApiServiceProvider.overrideWithValue(api)],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();
    // 결과 문장은 행을 눌러 펼친다(2026-10-18).
    for (final e in find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('history-tap-')).evaluate().toList()) {
      await tester.tap(find.byKey(e.widget.key!));
      await tester.pump();
    }
    expect(find.text('실제 가전이 움직였는지 확인하지 못했어요'), findsOneWidget);
    // 연습 표시는 그대로 남는다.
    expect(find.text('연습이라 실제로 누르지 않았어요'), findsOneWidget);
    expect(find.textContaining('실행 환경 미확인'), findsNothing);
  });

  testWidgets('실행 상태: ThinQ 확인 못 함은 주의로, 정지 버튼 없이 경로·확인 수준을 말한다',
      (tester) async {
    await tester.pumpWidget(buildScreen(
      const StatusScreen(),
      executionStatus: const ExecutionStatus(
        label: '공기청정기 켜기',
        phase: ExecutionPhase.unconfirmed,
        message: '명령을 보냈지만 확인하지 못했어요. 가전을 직접 확인해 주세요.',
        executionMode: 'mock',
        outcome: 'unconfirmed',
        route: 'thinq',
        receipt: 'accepted',
        confirmation: 'none',
      ),
    ));
    await tester.pump();

    expect(findPlainText('보냈지만 확인하지 못했어요', contains: true), findsOneWidget);
    expect(find.text('확인 못 함'), findsOneWidget);
    expect(find.text('LG 가전'), findsOneWidget);
    expect(find.text('가전이 받았어요'), findsOneWidget);
    expect(find.text('연습이에요. 실제 가전에 보내지 않아요'), findsOneWidget);
    expect(find.textContaining('못 했어요'), findsNothing);
    expect(find.text('실패'), findsNothing);
    expect(find.textContaining('정지'), findsNothing);
  });

  // 2026-10-14 추가 확인 3: 이미 목표값(상태 확인됨·변경 명령 안 보냄) — 체크를 써도 제목·낭독이 '바꿨어요'로 읽히지 않는다.
  for (final message in <String?>['이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요.', null]) {
    testWidgets('실행 상태: 이미 목표값은 "이미 … 설정" 제목, 바꿨다고 읽히지 않는다(서버 문장 ${message == null ? '없음' : '있음'})',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(buildScreen(
        const StatusScreen(),
        executionStatus: ExecutionStatus(
          label: '공기청정기 강풍',
          phase: ExecutionPhase.completed,
          message: message,
          executionMode: 'real',
          outcome: 'success',
          route: 'thinq',
          receipt: 'not_dispatched',
          confirmation: 'already_at_target',
          detail: '이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요.',
        ),
      ));
      await tester.pump();
      expect(findPlainText('이미 강풍으로 설정돼 있어요. 변경 명령을 보내지 않았어요.'), findsOneWidget);
      expect(find.text('이미 그 설정이라 보내지 않았어요'), findsOneWidget);
      expect(find.textContaining('바꿨'), findsNothing);
      expect(find.textContaining('보냈'), findsNothing);
      final live = find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true && (w.properties.label ?? '').isNotEmpty);
      final label = tester.widget<Semantics>(live.first).properties.label!;
      expect(label, contains('이미 강풍으로 설정돼 있어요'));
      expect(label, isNot(contains('바꿨')));
      handle.dispose();
    });
  }

  testWidgets('이력: 모의 ThinQ 상태 확인은 결과 문장 자체가 모의라고 말한다',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final api = _apiWithHistory([
      _entry('m1', {
        'status': 'succeeded',
        'outcome': 'success',
        'route': 'thinq',
        'receipt': 'accepted',
        'confirmation': 'state_confirmed',
        'execution_mode': 'mock',
      }),
      _entry('r1', {
        'status': 'succeeded',
        'outcome': 'success',
        'route': 'thinq',
        'receipt': 'accepted',
        'confirmation': 'state_confirmed',
        'execution_mode': 'real',
      }),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [rpiApiServiceProvider.overrideWithValue(api)],
      child: const MaterialApp(home: HistoryScreen()),
    ));
    await tester.pump();
    await tester.pump();
    // 결과 문장은 행을 눌러 펼친다(2026-10-18).
    for (final e in find.byWidgetPredicate((w) =>
        w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('history-tap-')).evaluate().toList()) {
      await tester.tap(find.byKey(e.widget.key!));
      await tester.pump();
    }

    // 2026-10-13: 결과는 한 문장으로, 모의 여부는 따로 한 줄로 말한다.
    // 모의 기록의 결과 문장이 실제 확인처럼 읽히면 안 된다.
    // 2026-10-14: 모의는 한 줄로만 — 결과 문장이 곧 연습 표시다.
    expect(find.text('연습이라 가전에 보내지 않았어요'), findsOneWidget);
    expect(find.textContaining('모의 상태만'), findsNothing);
    // 실제 장치 기록은 실제 확인 문장 그대로, 모의 표시는 없다.
    expect(find.text('가전 상태를 확인했어요'), findsOneWidget);
    expect(find.textContaining('실기기'), findsNothing);
  });
}
