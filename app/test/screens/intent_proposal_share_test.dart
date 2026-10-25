// 휴대폰에서 알아들은 말의 확인 질문을 키오스크와 나눈다(2026-10-26) — 먼저 정한 쪽만 실행, 본체는 실행하지 않는다.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simplelay/providers/execution_status_provider.dart';

import 'llm_intent_flow_test.dart' show jsonResponse, mount, proposal;

Map<String, Object> shared() => {...proposal('buttons'), 'proposal_id': 'p1'};

void main() {
  testWidgets('네 — 본체에 먼저 정한 뒤에만 기존 경로로 실행', (tester) async {
    final writes = <String>[];
    await mount(tester, (r) async {
      if (r.url.path == '/execute') return jsonResponse({'detail': '모름'}, 422);
      if (r.url.path == '/intent/understand') return jsonResponse(shared());
      if (r.method == 'POST') {
        writes.add(r.url.path);
        if (r.url.path.endsWith('/resolve')) return jsonResponse({'id': 'p1', 'state': 'yes'});
        return jsonResponse({'job_id': 'job1'});
      }
      if (r.url.path == '/intent/proposals/p1') return jsonResponse({'id': 'p1', 'state': 'pending'});
      return jsonResponse({'running': false});
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('네'));
    await tester.pumpAndSettle();
    expect(writes, ['/intent/proposals/p1/resolve', '/execute-buttons']);
    expect(find.text('tracked-job'), findsOneWidget);
    ProviderScope.containerOf(tester.element(find.text('tracked-job'))).invalidate(executionStatusProvider);
    await tester.pump();
  });

  testWidgets('네 — 키오스크가 먼저 정했으면(409) 실행하지 않고 알린다', (tester) async {
    final writes = <String>[];
    await mount(tester, (r) async {
      if (r.url.path == '/execute') return jsonResponse({'detail': '모름'}, 422);
      if (r.url.path == '/intent/understand') return jsonResponse(shared());
      if (r.method == 'POST') {
        writes.add(r.url.path);
        if (r.url.path.endsWith('/resolve')) return jsonResponse({'detail': '다른 곳에서 이미 정했어요.'}, 409);
        return jsonResponse({'job_id': 'job1'});
      }
      return jsonResponse({'id': 'p1', 'state': 'pending'});
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('네'));
    await tester.pumpAndSettle();
    expect(writes, ['/intent/proposals/p1/resolve']);
    expect(find.text('본체 화면에서 이미 정했어요'), findsOneWidget);
    expect(find.text('tracked-job'), findsNothing);
  });

  testWidgets('창이 떠 있는 동안 키오스크가 정하면 창을 닫고 실행하지 않는다', (tester) async {
    final writes = <String>[];
    var state = 'pending';
    await mount(tester, (r) async {
      if (r.url.path == '/execute') return jsonResponse({'detail': '모름'}, 422);
      if (r.url.path == '/intent/understand') return jsonResponse(shared());
      if (r.method == 'POST') {
        writes.add(r.url.path);
        return jsonResponse({'job_id': 'job1'});
      }
      if (r.url.path == '/intent/proposals/p1') return jsonResponse({'id': 'p1', 'state': state});
      return jsonResponse({'running': false});
    });
    await tester.pumpAndSettle();
    expect(find.text('시험 동작을 할까요?'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('시험 동작을 할까요?'), findsOneWidget, reason: '아직 정하지 않았으면 그대로');
    state = 'yes';
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('시험 동작을 할까요?'), findsNothing);
    expect(find.text('본체 화면에서 이미 정했어요'), findsOneWidget);
    expect(writes, isEmpty);
  });

  testWidgets('아니요 — 본체에 아니요로 정하고 실행하지 않는다', (tester) async {
    final writes = <http.Request>[];
    await mount(tester, (r) async {
      if (r.url.path == '/execute') return jsonResponse({'detail': '모름'}, 422);
      if (r.url.path == '/intent/understand') return jsonResponse(shared());
      if (r.method == 'POST') writes.add(r);
      return jsonResponse({'id': 'p1', 'state': 'no'});
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('아니요'));
    await tester.pumpAndSettle();
    expect(writes.map((r) => r.url.path), ['/intent/proposals/p1/resolve']);
    expect(writes.single.body, contains('"no"'));
  });
}
