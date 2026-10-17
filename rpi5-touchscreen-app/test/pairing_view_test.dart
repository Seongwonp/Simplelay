import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/pairing_view.dart';

class _PairApi extends KioskApiService {
  String state = 'open';
  int approvals = 0;
  int closed = 0;
  @override
  Future<Map<String, dynamic>> pairingSession({bool create = false}) async => {
        'state': state,
        'code': '012345',
        'host': 'http://192.0.2.10:8000',
        'expires_in': 300,
        'request_id': 'abcdef-request',
        'phone': '내 폰',
      };
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
}
