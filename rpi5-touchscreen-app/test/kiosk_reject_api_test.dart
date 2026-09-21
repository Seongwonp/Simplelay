import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';

void main() {
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
