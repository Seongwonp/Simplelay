import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:routine_rehearsal/routine_rehearsal.dart';

Map<String, dynamic> snapshot({String phase = 'draft', int revision = 0}) => {
      'execution_mode': 'mock',
      'session': 'test',
      'revision': revision,
      'phase': phase,
      'reason': '합성 이력',
      'items': [
        {
          'id': 'purifier',
          'name': '공기청정기',
          'action': '켜기',
          'selected': true,
          'status': 'not_started',
          'receipt': 'not_dispatched'
        },
        {
          'id': 'fan',
          'name': '선풍기',
          'action': '약풍',
          'selected': true,
          'status': 'not_started',
          'receipt': 'not_dispatched'
        },
      ],
    };
OutlinedButton button(WidgetTester t, String label) =>
    t.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label));
Future<void> tap(WidgetTester t, String label) async {
  await t.ensureVisible(find.text(label));
  await t.tap(find.text(label));
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
      'exclusion needs preview and distinct approval; no automatic dispatch',
      (t) async {
    final events = <Map<String, dynamic>>[];
    var state = snapshot();
    await t.pumpWidget(
        MaterialApp(home: RoutineRehearsalScreen(request: (e) async {
      if (e != null) {
        events.add(e);
        state = snapshot(
            phase: e['event'] == 'review' ? 'review' : 'running',
            revision: state['revision'] + 1);
        if (e['selected'] != null) state['items'][1]['selected'] = false;
      }
      return state;
    })));
    await t.pumpAndSettle();
    expect(events, isEmpty);
    expect(button(t, '확인한 구성 승인 · 모의 실행').onPressed, isNull);
    await tap(t, '선풍기');
    await tap(t, '선택한 구성 미리보기');
    expect(events.single['selected'], ['purifier']);
    expect(events.single['revision'], 0);
    expect(button(t, '확인한 구성 승인 · 모의 실행').onPressed, isNotNull);
    await t.scrollUntilVisible(find.text('선풍기'), -150);
    await tap(t, '선풍기');
    expect(button(t, '확인한 구성 승인 · 모의 실행').onPressed, isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('in-flight old poll cannot overwrite approval response',
      (t) async {
    final oldPoll = Completer<Map<String, dynamic>>();
    var reads = 0;
    await t.pumpWidget(
        MaterialApp(home: RoutineRehearsalScreen(request: (e) async {
      if (e != null) return snapshot(phase: 'running', revision: 2);
      if (++reads == 1) return snapshot(phase: 'review', revision: 1);
      return await oldPoll.future;
    })));
    await t.pumpAndSettle();
    await t.pump(const Duration(seconds: 2));
    await tap(t, '확인한 구성 승인 · 모의 실행');
    oldPoll.complete(snapshot(phase: 'review', revision: 1));
    await t.pumpAndSettle();
    expect(find.text('순서대로 모의 실행 중'), findsOneWidget);
    expect(button(t, '확인한 구성 승인 · 모의 실행').onPressed, isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'lost approval response disables controls and never retries event',
      (t) async {
    var events = 0;
    await t.pumpWidget(
        MaterialApp(home: RoutineRehearsalScreen(request: (e) async {
      if (e != null) {
        events++;
        throw StateError('lost');
      }
      return snapshot(phase: 'review');
    })));
    await t.pumpAndSettle();
    await tap(t, '확인한 구성 승인 · 모의 실행');
    expect(events, 1);
    expect(button(t, '확인한 구성 승인 · 모의 실행').onPressed, isNull);
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(events, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('per-device success survives stop pending and unknown outcomes',
      (t) async {
    final s = snapshot(phase: 'stopping');
    s['items'][0]['status'] = 'succeeded';
    s['items'][1]['status'] = 'unconfirmed';
    s['items'][1]['receipt'] = 'unknown';
    await t.pumpWidget(
        MaterialApp(home: RoutineRehearsalScreen(request: (_) async => s)));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(find.text('공기청정기: 모의 동작 성공'), 200);
    expect(find.text('공기청정기: 모의 동작 성공'), findsOneWidget);
    expect(find.text('선풍기: 응답 유실 · 동작 여부 모름'), findsOneWidget);
    expect(find.text('정지 요청 · 확인 대기'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('non-mock response fails closed', (t) async {
    await t.pumpWidget(MaterialApp(
        home: RoutineRehearsalScreen(
            request: (_) async => {...snapshot(), 'execution_mode': 'real'})));
    await t.pumpAndSettle();
    expect(button(t, '선택한 구성 미리보기').onPressed, isNull);
    expect(button(t, '확인한 구성 승인 · 모의 실행').onPressed, isNull);
    await t.pumpWidget(const SizedBox());
  });
}
