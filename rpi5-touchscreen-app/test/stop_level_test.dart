// 정지 확인 단계(2026-10-13) — 키오스크가 '보냄'과 '확인'을 가른다.
//
// 서버 /status의 last_stop_level: sent(정지 명령을 보냄) · mcu_ack(모션 보드가 받음,
// 지연 ms) · verified(엔코더로 멈춤 확인). mcu_ack 이상만 '확인'이다. 없으면(옛 서버·
// 로컬 모의) 종전 화면 그대로 — 단계를 지어내지 않는다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(1920, 1080)),
        child: Scaffold(body: child),
      ),
    );

KioskDoneView _stopped({String? level, int? ackMs}) => KioskDoneView(
      success: false,
      label: '즉석밥 데워줘',
      reason: KioskFailureReason.stopped,
      executionMode: 'real',
      stopLevel: level,
      stopAckMs: ackMs,
    );

void main() {
  test('정지 단계 문장 — 보냄은 확인이라고 하지 않는다', () {
    expect(stopLevelSentence('sent'), '정지 명령을 보냈어요 — 멈췄는지 기계를 봐 주세요');
    expect(stopLevelSentence('mcu_ack', ackMs: 12), '정지 신호가 전달됐어요');
    expect(stopLevelSentence('verified', ackMs: 9), '멈춘 것을 확인했어요');
    // 응답 시간(ms)은 사용자 화면에 싣지 않는다(2026-10-14 문구 정리). 세 단계는 서로 다른 말로 남는다.
    expect(stopLevelSentence('verified'), '멈춘 것을 확인했어요');
    expect(stopLevelSentence(null), isNull);
    expect(stopLevelSentence('stopped_for_sure'), isNull);
    expect(stopLevelConfirmed('sent'), isFalse);
    expect(stopLevelConfirmed('mcu_ack'), isTrue);
  });

  test('/status의 마지막 정지 단계를 읽는다(옛 서버는 null)', () {
    final st = KioskStatus.fromJson(const {
      'running': false,
      'last_stop_level': 'mcu_ack',
      'last_stop_ack_ms': 21,
    });
    expect(st.lastStopLevel, 'mcu_ack');
    expect(st.lastStopAckMs, 21);
    final old = KioskStatus.fromJson(const {'running': false});
    expect(old.lastStopLevel, isNull);
    expect(old.lastStopAckMs, isNull);
  });

  testWidgets('멈춘 실행 화면 — 보냄이면 기계를 보라고 말한다', (tester) async {
    await tester.pumpWidget(_wrap(_stopped(level: 'sent')));
    expect(find.text('정지 명령을 보냈어요 — 멈췄는지 기계를 봐 주세요'), findsOneWidget);
    expect(find.textContaining('확인했어요'), findsNothing);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
  });

  testWidgets('멈춘 실행 화면 — 모션 보드 확인은 ms 없이 "정지 신호가 전달됐어요"', (tester) async {
    await tester.pumpWidget(_wrap(_stopped(level: 'mcu_ack', ackMs: 12)));
    expect(find.text('정지 신호가 전달됐어요'), findsOneWidget);
    expect(find.textContaining('ms'), findsNothing);
    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
  });

  testWidgets('멈춘 실행 화면 — 멈춤 확인', (tester) async {
    await tester.pumpWidget(_wrap(_stopped(level: 'verified', ackMs: 9)));
    expect(find.text('멈춘 것을 확인했어요'), findsOneWidget);
    expect(find.textContaining('ms'), findsNothing);
  });

  testWidgets('단계가 없으면 정지 줄을 그리지 않는다(종전 화면)', (tester) async {
    await tester.pumpWidget(_wrap(_stopped()));
    expect(find.textContaining('정지 명령을 보냈어요'), findsNothing);
    expect(find.textContaining('정지 신호가 전달됐어요'), findsNothing);
    expect(find.text('실행을 멈췄어요'), findsOneWidget);
  });

  testWidgets('정지로 멈춘 실행이 아니면 정지 단계를 말하지 않는다', (tester) async {
    await tester.pumpWidget(_wrap(const KioskDoneView(
      success: false,
      label: '즉석밥 데워줘',
      reason: KioskFailureReason.execution,
      stopLevel: 'mcu_ack',
      stopAckMs: 5,
    )));
    expect(find.textContaining('정지 신호가 전달됐어요'), findsNothing);
  });
}
