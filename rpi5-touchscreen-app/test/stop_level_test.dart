// 정지 확인 단계(2026-10-13) — 키오스크가 '보냄'과 '확인'을 가른다.
//
// 서버 /status의 last_stop_level: sent(정지 명령을 보냄) · mcu_ack(모션 보드가 받음,
// 지연 ms) · verified(엔코더로 멈춤 확인). verified만 '확인'이다(2026-10-15). 없으면(옛 서버·
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
  // 2026-10-15 문구 개선 §2-1: 주어는 작은 팔. 확인하지 못한 단계는 제목부터 모른다고 말한다.
  // 평가 4차(10/18): '멈추라고 보냈어요'는 기계가 한 일 — 사람이 볼 상태('멈추는 중이에요'). 확인 수준은 그대로:
  // 멈췄다는 말은 엔코더로 본 verified뿐이다.
  test('정지 단계 제목 — 주어는 작은 팔, 보냄·받음은 멈췄다고 하지 않는다', () {
    expect(stopLevelHeadline('sent'), '멈추는 중이에요');
    expect(stopLevelHeadline('mcu_ack', ackMs: 12), '작은 팔이 멈추는 중이에요');
    for (final level in ['sent', 'mcu_ack']) {
      expect(stopLevelHeadline(level), isNot(contains('멈췄')));
      expect(stopLevelHeadline(level), isNot(contains('보냈')));
    }
    expect(stopLevelHeadline('verified', ackMs: 9), '작은 팔이 멈췄어요');
    // 단계를 모르면 서버가 말한 사실(정지 요청으로 실행이 끝남)까지만.
    expect(stopLevelHeadline(null), '정지를 눌러 끝났어요');
    expect(stopLevelHeadline('stopped_for_sure'), '정지를 눌러 끝났어요');
    for (final level in ['sent', 'mcu_ack', 'verified', null]) {
      // 가전이 멈췄다고는 어느 단계에서도 말하지 않는다(그건 전력 하강 확인 때만).
      expect(stopLevelHeadline(level), isNot(contains('가전이 멈췄')));
      expect(stopLevelHeadline(level), isNot(contains('ms')));
    }
    expect(stopLevelNextStep('verified'), '가전이 켜져 있으면 가전의 정지 버튼을 직접 눌러 주세요');
    expect(stopLevelNextStep('mcu_ack'), '가전을 봐 주세요');
    expect(stopLevelNextStep('sent'), '가전을 봐 주세요');
    // 확인은 엔코더 확인(verified)뿐 — 모션 보드가 받음(mcu_ack)은 확인이 아니다.
    expect(stopLevelConfirmed('sent'), isFalse);
    expect(stopLevelConfirmed('mcu_ack'), isFalse);
    expect(stopLevelConfirmed('verified'), isTrue);
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

  testWidgets('멈춘 실행 화면 — 보냄이면 제목부터 모른다고, 가전을 보라고', (tester) async {
    await tester.pumpWidget(_wrap(_stopped(level: 'sent')));
    expect(find.text('멈추는 중이에요'), findsOneWidget);
    expect(find.text('가전을 봐 주세요'), findsOneWidget);
    expect(find.textContaining('확인했어요'), findsNothing);
    expect(find.text('실행을 멈췄어요'), findsNothing);
    expect(find.byIcon(Icons.question_mark), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('멈춘 실행 화면 — 모션 보드 받음은 ✓ 없이 물음표, ms 없음', (tester) async {
    await tester.pumpWidget(_wrap(_stopped(level: 'mcu_ack', ackMs: 12)));
    expect(find.text('작은 팔이 멈추는 중이에요'), findsOneWidget);
    expect(find.text('가전을 봐 주세요'), findsOneWidget);
    expect(find.textContaining('ms'), findsNothing);
    expect(find.byIcon(Icons.verified_outlined), findsNothing);
    expect(find.byIcon(Icons.check), findsNothing);
    expect(find.byIcon(Icons.question_mark), findsOneWidget);
  });

  testWidgets('멈춘 실행 화면 — 멈춤 확인은 작은 팔이 멈췄다고, 가전은 직접', (tester) async {
    await tester.pumpWidget(_wrap(_stopped(level: 'verified', ackMs: 9)));
    expect(find.text('작은 팔이 멈췄어요'), findsOneWidget);
    expect(find.text('가전이 켜져 있으면 가전의 정지 버튼을 직접 눌러 주세요'), findsOneWidget);
    expect(find.textContaining('ms'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('단계가 없으면 정지 요청으로 실행이 끝났다고만 한다', (tester) async {
    await tester.pumpWidget(_wrap(_stopped()));
    expect(find.text('정지를 눌러 끝났어요'), findsOneWidget);
    expect(find.text('작은 팔과 가전이 멈췄는지 봐 주세요'), findsOneWidget);
    expect(find.text('실행을 멈췄어요'), findsNothing);
  });

  testWidgets('정지로 멈춘 실행이 아니면 정지 단계를 말하지 않는다', (tester) async {
    await tester.pumpWidget(_wrap(const KioskDoneView(
      success: false,
      label: '즉석밥 데워줘',
      reason: KioskFailureReason.execution,
      stopLevel: 'mcu_ack',
      stopAckMs: 5,
    )));
    expect(find.textContaining('정지 신호를 받았어요'), findsNothing);
  });
}
