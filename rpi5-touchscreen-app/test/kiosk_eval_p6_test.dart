// 평가 6차(2026-10-18) 지적 수리 — 키오스크 6단계. 옛 코드에도 있는 공개 구성만 써서 옛 코드에서 실패하는 것을 확인한다.
//
// 1. 가전 타일은 폰처럼 **상태 띠** — 타일 아래 띠(색 면 + 아이콘 + 짧은 말). 회색 '눌러 드려요' 반복 없음.
//    준비됐어요(회색) · 켜져 있어요(초록, 읽은 켜짐만) · 작동 중 · 설정이 필요해요(주황) · 지금 못 써요(회색=끊김, 빨강=비상).
//    서버가 보낸 사용자 가전(is_custom)에 사진 위치(panel_mapping)가 없으면 폰과 같은 판정으로 '설정이 필요해요'.
//    is_custom을 서버가 말하지 않으면 단정하지 않는다.
// 2. 아이콘: 공기청정기(서버 category air_purifier)는 바람, 선풍기(서버 모의 선풍기 id 'fan')는 바람 계열. 앱 모음 격자 없음.
// 3. 루틴 크기: '버튼 N번' → '누를 버튼 N개', LG 가전 단계는 결과 말('공기청정기 켜기').
// 4. 연습 동작 중: 제목과 본문이 같은 상태를 말한다('연습이 끝났어요'), 할 일은 '빨간 정지를 눌러 보세요' 하나,
//    조준경 아이콘 없음.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/appliance_strip.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/hold_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/manual_view.dart';

Future<void> _pump(WidgetTester tester, Widget child, {double scale = 1.0}) async {
  tester.view.physicalSize = const Size(800, 480);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(800, 480), textScaler: TextScaler.linear(scale)),
      child: Scaffold(backgroundColor: KioskColors.bg, body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

const _estopDetail = "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요";

/// 서버 `/appliances` 한 항목 꼴.
ApplianceMap _server(String id, String name, String category,
    {bool? custom, Object? mapping, String control = 'physical', String readiness = 'operable'}) {
  return applianceFromServerJson({
    'id': id,
    'name': name,
    'category': category,
    'rows': 1,
    'cols': 1,
    'buttons': <dynamic>[],
    if (custom != null) 'is_custom': custom,
    'control_path': control,
    'can_execute': true,
    'readiness': readiness,
    'panel_mapping': mapping,
  });
}

final _microwave = _server('microwave', '전자레인지', 'microwave', custom: false);
final _air = _server('air_purifier', '공기청정기', 'air_purifier', custom: false, control: 'thinq');
final _washer = _server('washer', '세탁기', 'washing_machine', custom: true);
final _intercom = _server('intercom', '인터폰', 'intercom', custom: true);
final _mapped = _server('rice', '밥솥', 'rice_cooker', custom: true, mapping: {
  'photo': {'width': 640, 'height': 480},
  'corners_px': <dynamic>[],
  'buttons_px': <String, dynamic>{},
});

const _ok = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'plug', state: 'ok', title: '', message: ''),
];

const _pressDown = [
  ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
  ConnectionItem(id: 'press', state: 'error', title: '누름 장치와 연결이 끊겼어요', message: ''),
  ConnectionItem(id: 'plug', state: 'ok', title: '', message: ''),
];

KioskIdleView _idle(List<ApplianceMap> list,
        {List<ConnectionItem> connections = _ok,
        Set<String> running = const {},
        Set<String> on = const {}}) =>
    KioskIdleView(
      now: DateTime(2026, 10, 18, 3, 29),
      connected: true,
      connections: connections,
      appliances: list,
      running: running,
      on: on,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
      onSettingsGesture: () {},
      onEstopGuide: () {},
    );

List<String> _allTexts(WidgetTester tester) => [
      for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText)))
        p.text.toPlainText(),
    ];

/// 사용자 결정(10/19): 상태 띠를 없앴다 — 문제가 있을 때만 오른쪽 위 표시. 없으면 null.
KioskTileIssue? _issue(WidgetTester tester, String id) {
  final f = find.byKey(ValueKey('tile-mark-$id'));
  return f.evaluate().isEmpty ? null : tester.widget<KioskTileMarkButton>(f).issue;
}

Color? _icon(WidgetTester tester, String id) =>
    tester.widget<Icon>(find.byKey(ValueKey('tile-icon-$id'))).color;

void main() {
  // 평가 6차의 상태 띠는 사용자 결정(10/19)으로 아이콘 + 이름 + 문제 표시로 바뀌었다. 판정(무엇이 준비됨·설정·쓸 수 없음인지)은 그대로.
  group('1. 가전 타일 상태', () {
    testWidgets("평소 가전은 표시 없음 — '눌러 드려요'·'준비됐어요'를 되풀이하지 않는다", (tester) async {
      await _pump(tester, _idle([_microwave, _mapped]));
      expect(find.text('눌러 드려요'), findsNothing);
      expect(find.text('준비됐어요'), findsNothing);
      expect(_issue(tester, 'microwave'), isNull);
      expect(_issue(tester, 'rice'), isNull, reason: '사진 위치를 맞춘 사용자 가전은 준비됨');
    });

    // 접근성 감사(10/18): 설정은 어르신 할 일이 아니다 — 본체는 경고 '!'가 아니라 설정 톱니(가족이 휴대폰에서 설정해요).
    testWidgets("폰에서 '설정이 필요해요'인 가전(사용자 가전, 사진 위치 없음)은 키오스크에서 톱니 표시",
        (tester) async {
      await _pump(tester, _idle([_washer, _intercom, _microwave]));
      expect(_issue(tester, 'washer')?.mark, KioskTileMark.setup);
      expect(_issue(tester, 'intercom')?.mark, KioskTileMark.setup);
      expect(_issue(tester, 'washer')?.text, kTilePanelSetup);
      expect(_issue(tester, 'microwave'), isNull);
    });

    test('서버가 is_custom을 말하지 않으면 설정 필요라고 단정하지 않는다', () {
      final a = _server('washer', '세탁기', 'washing_machine');
      expect(a.needsPanelMapping, isFalse);
      expect(_washer.needsPanelMapping, isTrue);
      expect(_mapped.needsPanelMapping, isFalse);
      expect(_air.needsPanelMapping, isFalse, reason: 'LG 가전은 누를 자리가 없다');
    });

    // 사용자 결정(10/19, 두 번째): 밝기 = 켜짐·작동 중 — 켜짐은 흰 아이콘(밝게), 꺼짐·모름·쉬는 중은 tileDim(흐리게). 강조색은 쓰지 않는다.
    // 누름 장치 가전은 켜짐을 읽을 수 없어 실행 중일 때만 밝다 — 준비된 전자레인지는 흐리다.
    testWidgets('켜짐은 아이콘 밝게 — 쉬는 누름 장치 가전과 갈린다', (tester) async {
      await _pump(tester, _idle([_microwave, _air, _mapped], running: {'rice'}, on: {'air_purifier'}));
      expect(_icon(tester, 'air_purifier'), Colors.white);
      expect(_issue(tester, 'air_purifier'), isNull);
      expect(_icon(tester, 'microwave'), KioskColors.tileDim);
      expect(_icon(tester, 'rice'), Colors.white, reason: '지금 실행 중인 누름 장치 가전은 밝다');
    });

    // 출시 검토(10/18): 쓸 수 없음은 이유와 상관없이 한 모양 — 이제 '!' 표시(10/19), 이유는 문장.
    testWidgets("누름 장치 끊김·비상 버튼 모두 같은 '!' 표시", (tester) async {
      await _pump(tester, _idle([_microwave, _air], connections: _pressDown));
      expect(_issue(tester, 'microwave'), const KioskTileIssue(KioskTileMark.unusable, kTileUnusablePress));

      await _pump(
          tester,
          KioskEstopLayout(
            banner: KioskEstopBanner(detail: _estopDetail, onRequest: () {}),
            child: _idle([_microwave, _air]),
          ));
      expect(_issue(tester, 'microwave'), const KioskTileIssue(KioskTileMark.unusable, kTileUnusableEstop));
    });

    test('LG 가전 작업 중은 짧게 바꾸는 중(화면 읽기)', () {
      expect(kioskTileStateWord(_air, running: true), '바꾸는 중');
      expect(kioskTileIssue(_air, running: true), isNull);
    });
  });

  group('2. 아이콘', () {
    test('공기청정기는 바람, 서버 모의 선풍기는 바람 계열, 모르는 종류도 앱 모음 격자가 아니다', () {
      expect(_air.icon, Icons.air);
      expect(_server('fan', '선풍기(모의)', 'other', custom: false).icon, Icons.wind_power);
      expect(_server('x', '기타', 'other', custom: true).icon, isNot(Icons.widgets_outlined));
      expect(applianceIconFor('other'), isNot(Icons.widgets_outlined));
    });

    testWidgets('평소 화면 타일에 앱 모음 격자 아이콘이 없다', (tester) async {
      await _pump(tester, _idle([_air, _microwave, _server('x', '기타', 'other', custom: false)]));
      expect(find.byIcon(Icons.widgets_outlined), findsNothing);
      expect(find.byIcon(Icons.air), findsWidgets);
    });
  });

  group("3. '누를 버튼 N개'·LG 가전 결과 말", () {
    test('누르기 단계는 누를 버튼 수, LG 가전 단계는 결과 말', () {
      final r = KioskRoutine.fromJson({
        'id': 'r',
        'name': '저녁',
        'steps': [
          {'kind': 'press_sequence', 'appliance_id': 'microwave', 'buttons': ['즉석밥', '시작', '취소']},
          {
            'kind': 'thinq_command',
            'appliance_id': 'air_purifier',
            'action': 'set_power',
            'args': {'power': 'POWER_ON'},
          },
        ],
      });
      final label = r.sizeLabelWith(const {'air_purifier': '공기청정기'});
      expect(label, contains('누를 버튼 3개'));
      expect(label, contains('공기청정기 켜기'));
      expect(label, isNot(contains('번')));
    });

    testWidgets("내 가전 화면 루틴 칸은 '누를 버튼 3개'", (tester) async {
      await _pump(
          tester,
          KioskManualView(
            appliance: kMicrowaveAppliance,
            onExecute: (_) {},
            onCancel: () {},
            routines: const [KioskRoutine(id: 'm', name: '아침 데우기', pressCount: 3)],
            onRoutine: (_) {},
          ));
      final all = _allTexts(tester).join('\n');
      expect(all, contains('누를 버튼 3개'));
      expect(all, isNot(contains('버튼 3번')));
    });
  });

  // 평가 11차(10/18): 정지 안내는 고르는 말(kPracticeStopHint) — '빨간 정지를 눌러 보세요'는 까닭 없는 지시였다.
  testWidgets("4. 연습 동작 중: 제목·본문이 같은 상태, 정지 안내는 한 줄, 조준경 없음", (tester) async {
    await _pump(
        tester,
        KioskHoldView(
          appliance: kMicrowaveAppliance,
          holdState: 'hovering_stop',
          stopButton: '취소',
          executionMode: 'mock',
          elapsed: Duration.zero,
          buttonsPressed: 3,
          onStop: () {},
        ));
    final all = _allTexts(tester);
    expect(all.join('\n'), isNot(contains('연습 중')), reason: "'연습 중' 제목 + '연습을 마쳤어요' 본문은 서로 다른 말");
    expect(all.where((t) => t.contains('연습이 끝났어요')).length, 1);
    // 평가 14차(10/18): 연습을 마친 대기에는 정지 안내 문장을 두지 않는다.
    expect(all.where((t) => t.contains('눌러 볼 수')), isEmpty);
    expect(all.where((t) => t.contains('눌러')).length, 0, reason: '정지 안내 문장 없음');
    expect(find.byIcon(Icons.my_location), findsNothing);
    // 정지 단추는 그대로.
    expect(find.byKey(const ValueKey('hold-stop')), findsOneWidget);
  });
}
