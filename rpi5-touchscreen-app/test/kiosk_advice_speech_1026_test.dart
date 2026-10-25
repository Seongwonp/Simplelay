// 2026-10-26 — 조언 카드('알겠어요'·'괜찮아요', 실행 없음), 사람에게 말하듯 읽는 제안 소리, 바깥 미세먼지 한 줄.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/screens/kiosk_screen.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/suggestion_view.dart';

final _advice = KioskSuggestion.fromJson({
  'id': 'a1',
  'purpose': '창문을 열어 환기해 보세요',
  'occurrences': 0,
  'time_band': '조언',
  'reason': '실내 습도가 74%로 꽤 습해요. 바깥은 18도로 선선하니 잠깐 창문을 열어 환기해 보시는 건 어떨까요?',
  'appliance_id': null,
  'kind': 'advice',
  'speech': '실내 습도가 74%로 꽤 습해요. 바깥은 18도로 선선하니 잠깐 창문을 열어 환기해 보시는 건 어떨까요?',
  'signals': [
    {'label': '집에 계심', 'ok': true},
    {'label': '바깥 미세먼지 보통', 'ok': true},
  ],
});

void main() {
  group('소리로 읽을 말', () {
    test('서버 speech가 있으면 그대로 — 하시려면 안내는 붙이지 않는다', () {
      final s = KioskSuggestion.fromJson({
        'id': 'e1',
        'purpose': '제습기 켜줘',
        'reason': '지금 실내 습도가 74%로 꽤 습해요.',
        'question': '제습기를 켤까요?',
        'speech': '지금 실내 습도가 74%로 꽤 습해요. 제습기를 켤까요?',
      });
      expect(s.question, '제습기를 켤까요?');
      expect(suggestionSpeech(s), '지금 실내 습도가 74%로 꽤 습해요. 제습기를 켤까요?');
      expect(suggestionSpeech(s), isNot(contains('하시려면')));
    });

    test('speech가 없으면 근거 문장 + 화면 질문', () {
      const habit = KioskSuggestion(
          id: 'h1', purpose: '즉석밥 데워줘', occurrences: 5, timeBand: '저녁', reason: '최근 28일 중 5일, 오후 7시쯤 하셨어요');
      expect(suggestionSpeech(habit), '최근 28일 중 5일, 오후 7시쯤 하셨어요. 즉석밥 데우기를 지금 할까요?');
      const old = KioskSuggestion(id: 'h2', purpose: '즉석밥 데워줘', occurrences: 0);
      expect(suggestionSpeech(old), '즉석밥 데우기를 지금 할까요?');
    });

    test('조언 카드는 조언 문장만', () {
      expect(suggestionSpeech(_advice), startsWith('실내 습도가 74%로 꽤 습해요.'));
      expect(_advice.isAdvice, isTrue);
      expect(KioskSuggestion.fromJson({'id': 'x', 'purpose': 'p'}).isAdvice, isFalse);
    });
  });

  group('조언 카드 화면', () {
    Future<(List<String>, KioskSuggestionView)> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final calls = <String>[];
      final view = KioskSuggestionView(
        suggestion: _advice,
        cdRemaining: 20,
        cdTotal: 20,
        onApprove: () => calls.add('approve'),
        onReject: () => calls.add('reject'),
        onAcknowledge: () => calls.add('ack'),
        onMuteChanged: (_) {},
        onMarkDone: () {},
      );
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
      return (calls, view);
    }

    testWidgets("'알겠어요'·'괜찮아요'만 — '네'·숨기기·실행 단추 없음", (tester) async {
      final (calls, view) = await pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('창문을 열어 환기해 보세요'), findsOneWidget);
      expect(find.text('알겠어요'), findsOneWidget);
      expect(find.text('괜찮아요'), findsOneWidget);
      expect(find.text('네'), findsNothing);
      expect(find.text('아니요'), findsNothing);
      expect(view.offersMute, isFalse);
      expect(find.text('가전은 움직이지 않아요'), findsOneWidget);
      expect(find.text('집에 계심'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('suggestion-approve')));
      await tester.tap(find.byKey(const ValueKey('suggestion-later')));
      expect(calls, ['ack', 'reject']);
    });
  });

  group('바깥 미세먼지', () {
    test('서버 outdoor_air → 날씨 자세히 한 줄', () {
      final a = AmbientInfo.fromJson({
        'greeting': '좋은 오후예요.',
        'outdoor_air': {'station': '부림동', 'grade': '보통', 'pm10': 40, 'pm25': 20},
      });
      expect(a.outdoorAirLine, '바깥 미세먼지 보통 (측정소 부림동)');
      expect(AmbientInfo.fromJson({'greeting': ''}).outdoorAirLine, isNull);
      expect(AmbientInfo.fromJson({'greeting': '', 'outdoor_air': {'station': '부림동', 'grade': null}}).outdoorAirLine,
          isNull);
    });
  });
}
