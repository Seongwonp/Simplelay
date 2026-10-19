import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/pairing_view.dart';

class _PairApi extends KioskApiService {
  String state = 'open';
  int expiresIn = 300;
  int sessionCalls = 0;
  int approvals = 0;
  int closed = 0;
  @override
  Future<Map<String, dynamic>> pairingSession({bool create = false}) async {
    sessionCalls++;
    return {
      'state': state,
      'code': '012345',
      'host': 'http://192.0.2.10:8000',
      'expires_in': expiresIn,
      'request_id': 'abcdef-request',
      'phone': '내 폰',
    };
  }
  @override
  Future<void> approvePairing(String requestId, bool approved) async {
    expect(requestId, 'abcdef-request');
    approvals++;
    state = approved ? 'approved' : 'denied';
  }

  @override
  Future<void> closePairing() async {
    closed++;
  }
}

void main() {
  testWidgets('폰 요청을 보고 직접 승인해야 연결해요', (tester) async {
    final api = _PairApi();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: KioskPairingView(api: api, onClose: () {}))));
    await tester.pumpAndSettle();
    expect(find.text('012345'), findsOneWidget);
    expect(api.approvals, 0);
    api.state = 'pending';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('이 폰을 연결할까요?'), findsOneWidget);
    expect(find.textContaining('abcdef'), findsOneWidget);
    expect(api.approvals, 0);
    await tester.tap(find.text('이 폰 연결하기'));
    await tester.pump();
    expect(api.approvals, 1);
    expect(find.text('허락했어요. 폰에서 연결을 봐 주세요.'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pump();
    expect(api.closed, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // 검토 10/19 — 허브는 허락된 키를 폰에 한 번 보냈으면 'consumed'다(폰은 받았음 알림 전까지 같은 키를 다시 받을 수 있다).
  // 예전: 화면이 계속 묻고 초를 세다 창이 끝나면 '연결 시간이 지났어요. 새 코드를 받아 주세요.'로 바뀌어, 이미 연결된 폰을
  // 다시 연결해야 하는 줄 알았다. 이제: 보냈으면 그 문장을 남기고 묻기·초 세기를 멈춘다.
  testWidgets('폰에 연결 정보를 보냈으면 창이 끝나도 그 문장을 남기고 더 묻지 않아요', (tester) async {
    final api = _PairApi()..expiresIn = 4;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: KioskPairingView(api: api, onClose: () {}))));
    await tester.pumpAndSettle();
    api.state = 'pending';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.tap(find.text('이 폰 연결하기'));
    await tester.pump();
    api.state = 'consumed';
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('폰에 연결 정보를 보냈어요.'), findsOneWidget);
    expect(find.textContaining('초 남았어요'), findsNothing);
    // 만료 시각은 벽시계로 센다 — 만료 문장으로 바뀌지 않는 것은 묻기·초 세기가 멈춘 것으로 지킨다.
    final calls = api.sessionCalls;
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.text('폰에 연결 정보를 보냈어요.'), findsOneWidget);
    expect(find.textContaining('연결 시간이 지났어요'), findsNothing);
    expect(api.sessionCalls, calls, reason: '보낸 뒤에는 더 묻지 않는다');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
