// 폰 화면을 실제 이미지로 렌더한다 — 눈으로 확인하기 위한 도구다.
//
// 위젯 테스트는 "그 문구가 있다"까지만 확인한다. 큰 글씨에서 버튼 안 글자가 잘리거나,
// 근거 줄이 말줄임으로 사라지는 것은 테스트가 통과하면서도 벌어진다 — 실제로 키오스크
// 쪽에서 그 두 가지가 이 방식으로만 드러났다.
//
// 실행: flutter test test/screenshot_test.dart --update-goldens
//   -> test/goldens/*.png. 통과/실패를 다투는 골든이 아니라 **보기 위한** 산출물이다
//      (폰트 렌더가 환경마다 다르므로 CI에서 깨지는 것이 목적이 아니다).
//
// 참고: 테스트 환경에는 MaterialIcons 폰트가 없어 아이콘이 네모로 나온다. 실기기에는
// 정상이다(docs/screenshots의 실제 캡처 참고) — 여기서 볼 것은 레이아웃과 글자다.
// 다른 기기에서는 폰트 렌더가 달라 이미지가 어긋날 수 있다. 그때는
//   flutter test --exclude-tags screenshot
// 로 빼고 돌리면 된다.
@Tags(['screenshot'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/suggestion.dart';
import 'package:simplelay/screens/home_screen.dart';
import 'package:simplelay/theme/app_theme.dart';

import 'helpers/test_helpers.dart';

const _phoneSize = Size(390, 844);

Future<void> _shoot(
  WidgetTester tester,
  String name,
  Widget screen, {
  List<Suggestion> suggestions = const [],
  bool connected = true,
  bool light = false,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = _phoneSize;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    buildWithProviderState(
      suggestions: suggestions,
      overrides: connected ? connectedOverrides() : disconnectedOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        // 실제 테마를 쓴다 -- 기존 테스트 헬퍼는 ThemeData.dark()를 쓰고 있어서
        // 우리 팔레트가 화면에 어떻게 나오는지는 확인되지 않는다.
        theme: light
            ? AppTheme.light.copyWith(
                textTheme: AppTheme.light.textTheme.apply(fontFamily: 'Malgun'))
            : AppTheme.dark.copyWith(
                textTheme: AppTheme.dark.textTheme.apply(fontFamily: 'Malgun')),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
  // 제안 카드는 등장 애니메이션(_SlidingCard)을 거치므로 정착까지 기다린다.
  // pump 한 번으로는 화면에 아직 안 그려져 있어 빈 화면을 찍게 된다.
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('goldens/$name.png'),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  setUpAll(() async {
    final bytes = File(r'C:\Windows\Fonts\malgun.ttf').readAsBytesSync();
    final loader = FontLoader('Malgun')
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

  const suggestions = [
    Suggestion(
      sequenceId: 'a',
      label: '우유 데워줘',
      steps: ['BT-08', 'BT-03', 'BT-05'],
    ),
  ];

  testWidgets('홈 — 제안 있음 (다크)', (t) async {
    await _shoot(t, 'home_dark', const HomeScreen(), suggestions: suggestions);
  });

  testWidgets('홈 — 제안 있음 (라이트)', (t) async {
    await _shoot(t, 'home_light', const HomeScreen(),
        suggestions: suggestions, light: true);
  });

  testWidgets('홈 — 제안 없음·미연결', (t) async {
    await _shoot(t, 'home_empty', const HomeScreen(), connected: false);
  });

  testWidgets('홈 — 큰 글씨 (200%)', (t) async {
    await _shoot(t, 'home_large', const HomeScreen(),
        suggestions: suggestions, textScale: 2.0);
  });
}
