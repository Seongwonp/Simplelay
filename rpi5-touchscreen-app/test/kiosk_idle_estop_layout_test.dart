// 비상정지 띠 + 안내 카드 + 예보 + 가전 줄이 한 화면에 함께 있을 때(2026-10-06 실패널
// 15.8형 1920x1080에서 본 결함) 아무것도 잘리지 않는지 본다.
//
// 결함: 평소 화면에서 "내 가전" 줄과 안내 카드("약 드실 시간이에요…")가 떠 있는데
// /status.estop_latched로 위쪽 띠가 생기면 평소 화면 전체가 아래로 밀려, 안내 아래
// 예보 줄("0시 3시 6시 9시"와 기온)이 가전 줄에 걸려 반쯤 잘렸다.
//
// 판정 규칙(kiosk_large_text_layout_test.dart와 같은 방식, 맑은 고딕으로 잰다):
// - 레이아웃 예외가 없다.
// - 띠·시계·안내·가전 이름은 화면 안, 스크롤 없이 보이는 영역 안에 다 그려진다.
// - 예보는 **다 보이거나 일부러 숨긴다** — 반쯤 걸린 상태는 없다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/models/ambient.dart';
import 'package:simplelay_touchscreen/models/appliance.dart';
import 'package:simplelay_touchscreen/models/estop.dart';
import 'package:simplelay_touchscreen/theme/kiosk_colors.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/estop_banner.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/idle_view.dart';
import 'package:simplelay_touchscreen/widgets/kiosk/kiosk_canvas.dart';

const _fontPath = r'C:\Windows\Fonts\malgun.ttf';
final _hasFont = File(_fontPath).existsSync();

const _tipText = '약 드실 시간이에요. 아직 안 드셨으면 지금 챙겨 드세요';

const _hourly = [
  AmbientHour(label: '0시', icon: 'clear', temp: 14, precip: false),
  AmbientHour(label: '3시', icon: 'partly', temp: 13, precip: false),
  AmbientHour(label: '6시', icon: 'cloudy', temp: 12, precip: false),
  AmbientHour(label: '9시', icon: 'clear', temp: 15, precip: false),
];

const _washer = ApplianceMap(
    id: 'washer', name: '세탁기', category: 'washing_machine', rows: 1, cols: 1, buttons: []);

KioskIdleView _idle() => KioskIdleView(
      now: DateTime(2026, 10, 6, 23, 41),
      connected: true,
      ambient: const AmbientInfo(
        greeting: '편안한 밤 보내세요.',
        tip: AmbientTip(kind: 'routine', text: _tipText, icon: 'notice'),
        hourly: _hourly,
      ),
      connections: const [
        ConnectionItem(id: 'network', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'press', state: 'ok', title: '', message: ''),
        ConnectionItem(id: 'plug', state: 'ok', title: '', message: ''),
      ],
      appliances: const [kMicrowaveAppliance, _washer, kInductionAppliance],
      running: const {'washer'},
      temperature: 23,
      humidity: 58,
      onSelectAppliance: (_) {},
      onOpenConnection: (_) {},
      onDndGesture: () {},
    );

Future<void> _pump(WidgetTester tester,
    {required bool band, double scale = 1.0}) async {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Malgun', brightness: Brightness.dark),
    home: Builder(builder: (context) {
      // 실제 앱(kiosk_screen)과 같은 순서: 배율 → 캔버스 → Scaffold → 위 3px →
      // 띠 레이아웃(띠가 위 한 줄을 차지하고 화면은 그 아래 남은 자리).
      return MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: KioskCanvas(
          child: Scaffold(
            backgroundColor: KioskColors.bg,
            body: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: KioskEstopLayout(
                banner: band
                    ? const KioskEstopBanner(detail: "비상 버튼이 눌려 있어요 — 풀고 '해제하기'를 눌러야 다시 쓸 수 있어요")
                    : null,
                child: _idle(),
              ),
            ),
          ),
        ),
      );
    }),
  ));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 화면 안에, 감싼 스크롤 영역의 보이는 부분 안에 다 그려졌나.
void _expectFullyVisible(WidgetTester tester, Finder f, {bool isText = true}) {
  expect(f, findsOneWidget, reason: '$f');
  if (isText) {
    expect(tester.renderObject<RenderParagraph>(f).didExceedMaxLines, isFalse,
        reason: '$f 말줄임');
  }
  final rect = tester.getRect(f);
  final screen = Offset.zero & tester.view.physicalSize;
  expect(
      screen.contains(rect.topLeft) &&
          screen.contains(rect.bottomRight - const Offset(0.01, 0.01)),
      isTrue,
      reason: '$f 화면 밖 $rect');
  for (final s in find.ancestor(of: f, matching: find.byType(Scrollable)).evaluate()) {
    final view = tester.getRect(find.byWidget(s.widget));
    expect(rect.top >= view.top - 0.5 && rect.bottom <= view.bottom + 0.5, isTrue,
        reason: '$f 가 잘렸다 — 글자 $rect, 보이는 영역 $view');
  }
}

void main() {
  setUpAll(() async {
    if (!_hasFont) return;
    final bytes = File(_fontPath).readAsBytesSync();
    await (FontLoader('Malgun')..addFont(Future.value(ByteData.view(bytes.buffer))))
        .load();
  });

  for (final scale in [1.0, 1.22]) {
    for (final band in [false, true]) {
      final what = '${band ? '비상정지 띠' : '띠 없음'} · 글자 $scale배';
      testWidgets('1920x1080 $what — 안내·예보·가전 줄이 잘리지 않아요', (tester) async {
        if (!_hasFont) return markTestSkipped('맑은 고딕 없음');
        await _pump(tester, band: band, scale: scale);
        expect(tester.takeException(), isNull);

        if (band) {
          // 평소 화면 상태 칩도 같은 말을 한다(평가 4차 10/18) — 띠 안의 제목을 본다.
          _expectFullyVisible(tester,
              find.descendant(of: find.byKey(const ValueKey('estop-banner')), matching: find.text(kEstopTitle)));
          _expectFullyVisible(tester, find.byKey(const ValueKey('estop-ack')),
              isText: false);
        }
        // 시계는 12시간제 + 오전/오후(평가 4차 10/18).
        _expectFullyVisible(tester, find.text('11:41'));
        _expectFullyVisible(tester, find.text('오후'));
        _expectFullyVisible(tester, find.text(_tipText));
        for (final name in ['세탁기', if (!band) '작동 중', '전자레인지']) {
          _expectFullyVisible(tester, find.text(name));
        }

        if (band) expect(find.text('작동 중'), findsNothing);
        // 예보는 다 보이거나 일부러 숨긴다 — 반쯤 걸린 채로 두지 않는다.
        final hours = find.byKey(const ValueKey('ambient-hours'));
        if (hours.evaluate().isNotEmpty) {
          _expectFullyVisible(tester, hours, isText: false);
          // 예보 칸 이름도 오전/오후(평가 4차 10/18).
          for (final label in ['오전 12시', '오전 3시', '오전 6시', '오전 9시', '14°', '15°']) {
            // 날짜 옆 바깥 기온(사용자 요청 10/18)도 같은 글자일 수 있다 — 예보 칸 안에서 찾는다.
            _expectFullyVisible(tester, find.descendant(of: hours, matching: find.text(label)));
          }
          // 예보가 가전 줄에 걸치지 않는다.
          final strip = tester.getRect(find.byKey(const ValueKey('strip-washer')));
          expect(tester.getRect(hours).bottom <= strip.top + 0.5, isTrue,
              reason: '예보 ${tester.getRect(hours)} 가 가전 줄 $strip 에 걸친다');
        }
        // 띠가 없고 보통 글씨면 예보는 함께 보여야 한다(UI 확정 §3-1).
        if (!band && scale == 1.0) expect(hours, findsOneWidget);
      });
    }
  }

  testWidgets('평소 화면 위계 — 시계 > 안내 > 예보, 모두 14pt 상당 이상', (tester) async {
    // 14pt(사용자편의 가이드 체크리스트, 고령층 키오스크 지침) ≈ 15.8형 1920x1080
    // (약 139.5 PPI)에서 27 물리 px, 캔버스 배율 2.05로 나누면 13.2 논리 px.
    await _pump(tester, band: false);
    double size(Finder f) => tester.widget<Text>(f).style!.fontSize!;
    final clock = size(find.text('11:41'));
    final tip = size(find.text(_tipText));
    final hour = size(find.text('오전 12시'));
    final appliance = size(find.text('세탁기'));
    expect(clock, greaterThan(tip));
    expect(tip, greaterThan(hour));
    for (final s in [tip, hour, appliance]) {
      expect(s, greaterThanOrEqualTo(14));
    }
  });
}
