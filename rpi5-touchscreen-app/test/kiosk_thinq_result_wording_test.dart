// LG 가전 결과 화면의 확인된 성공 문구 — 켜기·끄기·바람이 같은 틀(제목: 가전 이름 + 결과, 아래: 근거 한 줄).
//
// 실패널에서 같은 공기청정기의 켜기는 '공기청정기가 켜졌어요 / 가전 상태를 다시 읽어 확인했어요', 끄기는
// '가전 설정을 확인했어요 / LG 가전 · 설정 변경을 확인했어요 / 전원 끄기로 바꿨어요.'로 형식이 달랐고 '확인했어요'가 두 번 나왔다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/command_result.dart';
import 'package:simplelay_touchscreen/models/thinq_run.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/done_view.dart';

final _purifier = applianceFromServerJson({
  'id': 'air_purifier',
  'name': '공기청정기',
  'category': 'air_purifier',
  'rows': 0,
  'cols': 0,
  'buttons': <dynamic>[],
  'control_path': 'thinq',
  'can_execute': true,
  'readiness': 'operable',
});

const _seen = '실제로 바뀐 것을 확인했어요';

ThinqResultCopy _copy(String conf, String detail, {String name = '공기청정기'}) => thinqResultCopy(
    applianceName: name,
    kind: ResultKind.success,
    receipt: 'accepted',
    confirmation: conf,
    detail: detail,
    executionMode: 'real')!;

int _count(String text, String word) => word.allMatches(text).length;

void main() {
  group('확인된 성공 — 동작별 같은 틀', () {
    test('켜기·끄기·바람: 제목은 가전 이름 + 결과, 아래 줄은 같은 근거 한 줄', () {
      final on = _copy('state_confirmed', '전원 켜기로 바꿨어요.');
      final off = _copy('state_confirmed', '전원 끄기로 바꿨어요.');
      final wind = _copy('state_confirmed', '바람 세기 강으로 바꿨어요.');
      expect(on.headline, '공기청정기가 켜졌어요');
      expect(off.headline, '공기청정기가 꺼졌어요');
      expect(wind.headline, '바람을 강풍으로 바꿨어요');
      for (final c in [on, off, wind]) {
        expect(c.sub, _seen);
        expect(c.tone, ThinqResultTone.confirmed);
      }
    });

    test('바람 세기 값별 이름', () {
      expect(_copy('state_confirmed', '바람 세기 약으로 바꿨어요.').headline, '바람을 약풍으로 바꿨어요');
      expect(_copy('state_confirmed', '바람 세기 자동으로 바꿨어요.').headline, '바람을 자동으로 바꿨어요');
    });

    test("가전 이름을 모르면 '가전'", () {
      expect(_copy('state_confirmed', '전원 끄기로 바꿨어요.', name: '가전').headline, '가전이 꺼졌어요');
    });

    test("기술 표현 없음, 어느 확인 수준에서도 '확인했어요'는 한 화면에 한 번까지", () {
      final all = [
        _copy('state_confirmed', '전원 켜기로 바꿨어요.'),
        _copy('state_confirmed', '운전 모드 청정으로 바꿨어요.'),
        _copy('state_confirmed_unknown_before', '전원 켜기로 설정된 것을 확인했어요.'),
        _copy('state_confirmed_unknown_before', '바람 세기 강으로 설정된 것을 확인했어요.'),
        _copy('state_confirmed_unknown_before', '운전 모드 청정으로 설정된 것을 확인했어요.'),
        _copy('already_at_target', '이미 전원 켜기로 설정돼 있어요. 그래서 보내지 않았어요.'),
        _copy('already_at_target', '이미 바람 세기 강으로 설정돼 있어요. 그래서 보내지 않았어요.'),
      ];
      for (final c in all) {
        final screen = '${c.headline}\n${c.sub}';
        expect(_count(screen, '확인했어요'), lessThanOrEqualTo(1), reason: screen);
        expect(screen, isNot(contains('다시 읽어')));
        expect(screen, isNot(contains('설정 변경')));
      }
    });

    test('전 값 모름·이미 그 설정은 뜻 그대로(바꿨다고 하지 않음)', () {
      final unknown = _copy('state_confirmed_unknown_before', '바람 세기 강으로 설정된 것을 확인했어요.');
      expect(unknown.headline, '바람이 강풍이에요');
      expect(unknown.sub, '지금 상태를 확인했어요');
      final already = _copy('already_at_target', '이미 바람 세기 강으로 설정돼 있어요. 그래서 보내지 않았어요.');
      expect(already.headline, '바람이 이미 강풍이에요');
      expect(already.sub, '그대로 두었어요');
      for (final c in [unknown, already]) {
        expect('${c.headline} ${c.sub}', isNot(contains('바꿨')));
        expect(c.sub, isNot(_seen));
      }
    });
  });

  // 전용 결과 창을 쓰지 않는 경로(이어받은 실행 등)도 같은 말이어야 한다 — 실패널 끄기 화면이 이 경로였다.
  testWidgets('일반 결과 화면: 끄기 확인 성공도 켜기와 같은 틀, 겹치는 줄 없음', (tester) async {
    tester.view.physicalSize = const Size(800, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: KioskDoneView(
      success: true,
      label: '공기청정기',
      target: _purifier,
      executionMode: 'real',
      route: 'thinq',
      confirmation: '설정 변경을 확인했어요',
      resultConfirmation: 'state_confirmed',
      detail: '전원 끄기로 바꿨어요.',
      onDismiss: () {},
    ))));
    expect(find.text('공기청정기가 꺼졌어요'), findsOneWidget);
    expect(find.text(_seen), findsOneWidget);
    expect(find.textContaining('LG 가전 ·'), findsNothing);
    expect(find.textContaining('가전 설정을 확인했어요'), findsNothing);
    expect(find.textContaining('설정 변경을 확인했어요'), findsNothing);
    expect(find.textContaining('전원 끄기로 바꿨어요'), findsNothing);
    expect(find.textContaining('확인했어요'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
