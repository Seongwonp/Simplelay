// 2026-10-14 HIGH 재확인 M-R1 — 잠시 쉬기 응답의 저장 결과(`persisted`)를 그대로 돌려준다.
// true 저장됨 · false 저장 실패(이번 세션만 적용 — 화면이 알린다) · null 저장소 없음·옛 서버(필드 없음)·오류 응답.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';

void main() {
  const cases = <String, bool?>{
    '{"ok":true,"persisted":true,"session_only":false}': true,
    '{"ok":true,"persisted":false,"session_only":true}': false,
    '{"ok":true,"persisted":null,"session_only":true}': null,
    '{"ok":true}': null,
  };
  cases.forEach((body, expected) {
    test('POST·DELETE /dnd $body → $expected', () async {
      final methods = <String>[];
      await http.runWithClient(() async {
        final api = KioskApiService(baseUrl: 'http://localhost:8000');
        try {
          expect(await api.setDnd(60), expected);
          expect(await api.clearDnd(), expected);
        } finally {
          api.dispose();
        }
      }, () => MockClient((r) async {
        methods.add('${r.method} ${r.url.path}');
        return http.Response(body, 200);
      }));
      expect(methods, ['POST /dnd', 'DELETE /dnd']);
    });
  });

  // 오류 응답은 저장 결과를 지어내지 않고, 적용된 것처럼 null(옛 서버)로 넘기지도 않는다 — 화면이 '못 보냈다'고 말한다(검토 10/19 코어 6차 #12).
  test('오류 응답은 적용되지 않았다고 던진다', () async {
    await http.runWithClient(() async {
      final api = KioskApiService(baseUrl: 'http://localhost:8000');
      try {
        await expectLater(api.setDnd(30), throwsA(isA<KioskApiException>()));
        await expectLater(api.clearDnd(), throwsA(isA<KioskApiException>()));
      } finally {
        api.dispose();
      }
    }, () => MockClient((r) async => http.Response('{"persisted":false}', 500)));
  });
}
