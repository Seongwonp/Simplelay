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
          '가전이 받았는지 확인이 필요해요');
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
      // 접수 불명: 받았는지 모른다고 말하고, 다시 보내기 전에 확인하라고 한다.
      final unknown = unconfirmedSentence(receipt: 'unknown');
      expect(unknown, contains('받았는지 확인하지 못했어요'));
      expect(unknown, contains('다시 보내기 전에'));
      expect(unknown, isNot(contains('실패')));
      expect(unknown, isNot(contains('확인했어요')));
    });

    test('경로 배지', () {
      expect(routeLabel('physical'), '버튼을 대신 눌러요');
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

  // 10/6 Copilot 리뷰(66990be): state_confirmed가 모의 판정보다 먼저 처리돼
  // 모의 실행에도 "상태 확인됨"이 나왔다.
  group('모의 실행의 상태 확인', () {
    test('모의 실행의 state_confirmed는 모의 상태 확인이다', () {
      expect(
          confirmationLabel(
              route: 'thinq',
              receipt: 'accepted',
              confirmation: 'state_confirmed',
              kind: ResultKind.success,
              executionMode: 'mock'),
          '모의 상태 확인');
    });
    test('실제·미확인 실행은 상태 확인됨 그대로', () {
      for (final mode in ['real', 'uart', 'unknown', null]) {
        expect(
            confirmationLabel(
                route: 'thinq',
                receipt: 'accepted',
                confirmation: 'state_confirmed',
                kind: ResultKind.success,
                executionMode: mode),
            '상태 확인됨');
      }
    });
  });
}
