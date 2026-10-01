// 결과·경로·확인 수준 문구 규칙(2026-09-29). 서버 필드 이름은 rpi/api/schemas.py
// StatusResponse·HistoryEntryResponse 기준이다.
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/models/command_result.dart';

void main() {
  group('resultKindOf', () {
    test('last_outcome을 우선 읽는다 — 정지 요청과 안전 정지를 가른다', () {
      expect(resultKindOf(outcome: 'success', status: 'succeeded'),
          ResultKind.success);
      expect(resultKindOf(outcome: 'stopped', status: 'safety_stopped'),
          ResultKind.stopped);
      expect(resultKindOf(outcome: 'safety_stop', status: 'safety_stopped'),
          ResultKind.safetyStop);
      expect(resultKindOf(outcome: 'failed', status: 'safety_stopped'),
          ResultKind.failed);
      expect(resultKindOf(outcome: 'unconfirmed', status: 'unconfirmed'),
          ResultKind.unconfirmed);
    });

    test('옛 서버(last_outcome 없음)는 종전 last_status 판정', () {
      expect(resultKindOf(status: 'succeeded'), ResultKind.success);
      expect(resultKindOf(status: 'safety_stopped'), ResultKind.stopped);
      expect(resultKindOf(status: 'failed'), ResultKind.failed);
      expect(resultKindOf(status: 'unconfirmed'), ResultKind.unconfirmed);
      expect(resultKindOf(), ResultKind.failed);
    });

    test('한 단어: 성공 / 실패 / 정지됨 / 안전 정지', () {
      expect(resultWord(ResultKind.success), '성공');
      expect(resultWord(ResultKind.failed), '실패');
      expect(resultWord(ResultKind.stopped), '정지됨');
      expect(resultWord(ResultKind.safetyStop), '안전 정지');
    });
  });

  group('ThinQ 확인 수준', () {
    test('상태 확인됨은 state_confirmed일 때만', () {
      expect(
          confirmationLabel(
              route: 'thinq',
              receipt: 'accepted',
              confirmation: 'state_confirmed',
              kind: ResultKind.success),
          '상태 확인됨');
      expect(
          confirmationLabel(
              route: 'thinq',
              receipt: 'accepted',
              confirmation: 'none',
              kind: ResultKind.unconfirmed),
          '접수됨');
      expect(
          confirmationLabel(
              route: 'thinq',
              receipt: 'unknown',
              confirmation: 'none',
              kind: ResultKind.unconfirmed),
          '받았는지 확인이 필요해요');
      expect(
          confirmationLabel(
              route: 'thinq',
              receipt: 'not_dispatched',
              confirmation: 'none',
              kind: ResultKind.failed),
          '보내지 않음');
    });

    test('확인 못 함 문장은 실패도 성공도 말하지 않는다', () {
      for (final receipt in ['accepted', 'unknown']) {
        final m = finishedMessage(
            kind: ResultKind.unconfirmed, route: 'thinq', receipt: receipt);
        expect(m, contains('보냈지만'));
        expect(m, isNot(contains('실패')));
        expect(m, isNot(contains('마쳤어요')));
        expect(m, isNot(contains('확인했어요')));
      }
      expect(unconfirmedSentence(receipt: 'unknown'), contains('받았는지 확인이 필요해요'));
    });

    test('경로 배지', () {
      expect(routeLabel('physical'), '물리 버튼');
      expect(routeLabel('thinq'), 'ThinQ');
      expect(routeLabel('unknown'), isNull);
      expect(routeLabel(null), isNull);
    });

    test('모의 ThinQ 성공은 실제 가전이 아니라고 말한다', () {
      expect(
          finishedMessage(
              kind: ResultKind.success, executionMode: 'mock', route: 'thinq'),
          contains('실제 가전은 조작하지 않았어요'));
    });
  });
}
