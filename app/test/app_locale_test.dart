// 앱 언어(접근성 검토 10/19) — 기본(영어) 문구면 화면 낭독(TalkBack)이 뒤로 가기·지우기·닫기를
// 'Back'·'Delete'·'Dismiss'로 읽었다. 앱이 한국어 기본 문구를 쓰는지 본다.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/main.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('앱은 한국어 기본 문구로 뜬다', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SimpleLayApp()));
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.locale, const Locale('ko'));
    expect(app.supportedLocales, [const Locale('ko')]);
    final context = tester.element(find.byType(Navigator).first);
    final l = MaterialLocalizations.of(context);
    expect(l.backButtonTooltip, '뒤로');
    expect(l.deleteButtonTooltip, '삭제');
    expect(l.modalBarrierDismissLabel, isNot('Dismiss'));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('뒤로 가기 버튼의 낭독 이름이 한국어다', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: kAppLocale,
      supportedLocales: kAppSupportedLocales,
      localizationsDelegates: kAppLocalizationsDelegates,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => Scaffold(appBar: AppBar(title: const Text('둘째')), body: const SizedBox()))),
          child: const Text('열기'),
        ),
      ),
    ));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('뒤로'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
  });
}
