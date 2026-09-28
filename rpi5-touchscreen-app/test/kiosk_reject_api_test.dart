import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';

void main() {
  test('routine only calls simulator API and propagates unavailable response', () async {
    final paths = <String>[];
    await http.runWithClient(() async {
      final api = KioskApiService(baseUrl: 'http://localhost:8768');
      expect((await api.routineRequest(null))['execution_mode'], 'mock');
      await expectLater(api.routineRequest({'event': 'approve', 'session': 'one', 'revision': 1}), throwsStateError);
      api.dispose();
    }, () => MockClient((r) async {
      paths.add(r.url.path);
      return http.Response('{"execution_mode":"mock"}', r.method == 'GET' ? 200 : 404);
    }));
    expect(paths, ['/simulator/routine/state', '/simulator/routine/event']);
  });
  for (final code in [200, 404, 401, 500]) {
    test('넘김 HTTP $code 응답을 정확히 처리한다', () async {
      await http.runWithClient(() async {
        final api = KioskApiService();
        try {
          final request = api.rejectSuggestion('s1');
          if (code == 200 || code == 404) {
            await expectLater(request, completes);
          } else {
            await expectLater(request, throwsException);
          }
        } finally {
          api.dispose();
        }
      }, () => MockClient((request) async => http.Response('{}', code)));
    });
  }
}
