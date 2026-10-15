// 키오스크 문구 개선 — 폰 안 A(2026-10-15, docs/키오스크-문구-개선-계획-2026-10-15.md §8).
// 결과·정지 문장은 확인한 만큼만(원칙 0-1~3), '연습/모의'는 '연습'으로, 이름이 다른 곳은 처음 한 번 이어 준다.
// 폰은 이름 바꾸기를 하지 않는다 — 누름 장치·허브·방해 금지는 그대로 둔다.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simplelay/models/command_result.dart';
import 'package:simplelay/providers/ble_provider.dart';
import 'package:simplelay/screens/settings_screen.dart';
import 'package:simplelay/widgets/dnd_bottom_sheet.dart';

import '../helpers/test_helpers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('정지 결과 문장 — 확인한 단계만큼, 할 일 한 가지', () {
    test('보냄(sent)에는 "실행을 멈췄어요"가 앞에 붙지 않고, 모른다고 말한다', () {
      final m = finishedMessage(kind: ResultKind.stopped, stopLevel: 'sent');
      expect(m, isNot(contains('실행을 멈췄어요')));
      expect(m, contains('멈추라고 보냈어요'));
      expect(m, contains('멈췄는지 아직 몰라요'));
      expect(m, contains('가전을 직접 봐 주세요'));
    });

    test('모션 보드 받음(mcu_ack)은 멈췄다고 하지 않는다', () {
      final m = finishedMessage(kind: ResultKind.stopped, stopLevel: 'mcu_ack');
      expect(m, isNot(contains('실행을 멈췄어요')));
      expect(m, contains('멈췄는지는 확인 못 했어요'));
    });

    test('멈춤 확인(verified)은 누름 장치가 멈췄다고 — 가전은 직접', () {
      final m = finishedMessage(kind: ResultKind.stopped, stopLevel: 'verified');
      expect(m, startsWith('누름 장치가 멈췄어요'));
      expect(m, contains('가전의 정지·취소 버튼을 직접 눌러 주세요'));
    });

    test('단계를 모르면 정지 요청으로 실행이 끝났다고까지만', () {
      final m = finishedMessage(kind: ResultKind.stopped);
      expect(m, isNot(contains('실행을 멈췄어요')));
      expect(m, contains('멈췄는지 직접 봐 주세요'));
    });
  });

  group('성공·안전 정지 문장', () {
    test('실제 실행 성공은 버튼을 다 눌렀다고, 가전은 직접', () {
      final m = finishedMessage(kind: ResultKind.success, executionMode: 'real');
      expect(m, '버튼을 다 눌렀어요. 가전이 움직이는지는 직접 봐 주세요.');
    });

    test('연습 성공은 연습이라고 — 모의라고 섞어 쓰지 않는다', () {
      final m = finishedMessage(kind: ResultKind.success, executionMode: 'mock');
      expect(m, contains('연습'));
      expect(m, isNot(contains('모의')));
      final thinq = finishedMessage(
          kind: ResultKind.success, executionMode: 'mock', route: 'thinq');
      expect(thinq, isNot(contains('모의')));
    });

    test('안전 정지는 가전을 먼저 보고, 이미 켜졌다면 다시 시도하지 말라고 한다', () {
      final m = finishedMessage(kind: ResultKind.safetyStop);
      expect(m, contains('가전을 먼저 봐 주세요'));
      expect(m, contains('이미 켜졌다면 다시 시도하지 마세요'));
      expect(m, isNot(contains('두 번 누르지 않')));
    });

    test('확인 칩 — 연습은 연습, 실제 동작 확인은 전력 사용이 늘었다(켜졌다가 아니다)', () {
      for (final c in ['operation_confirmed', 'press_confirmed', 'state_confirmed']) {
        final label = confirmationLabel(confirmation: c, executionMode: 'mock')!;
        expect(label, isNot(contains('모의')), reason: label);
      }
      expect(confirmationLabel(confirmation: 'operation_confirmed', executionMode: 'real'),
          '전력 사용이 늘었어요');
    });
  });

  testWidgets('설정 허브 줄 — 키오스크에서 부르는 이름을 이어 준다', (tester) async {
    tester.view.physicalSize = const Size(400, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildScreen(const SettingsScreen(), overrides: [
      scanResultsProvider.overrideWith((ref) => Stream.value(const <ScanResult>[])),
      ...installedOverrides([kTestAppliance]),
    ]));
    await tester.pump();
    expect(find.textContaining("키오스크에서는 'SimpleLay 본체'라고 불러요"), findsOneWidget);
  });

  testWidgets('방해 금지 창 — 키오스크의 제안 잠시 쉬기와 같다고 이어 준다', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDndSheet(context),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text("키오스크의 '제안 잠시 쉬기'와 같아요"), findsOneWidget);
  });

  test("사용자에게 보이는 폰 문자열에 '모의'가 없다(개발자 도구 제외)", () {
    // 개발자 도구·개발자 설정·내부 오류 문장·개발 빌드 전용 단추는 기술 용어로 둔다.
    const allowed = [
      'developer_console_screen.dart',
      'developer_section.dart',
      'rpi_api_service.dart',
      'home_screen.dart',
    ];
    final literal = RegExp(r"'[^'\n]*모의[^'\n]*'");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (allowed.any((a) => f.path.endsWith(a))) continue;
      for (final line in f.readAsLinesSync()) {
        if (line.trimLeft().startsWith('//')) continue;
        for (final m in literal.allMatches(line)) {
          // 판정용 정규식·비교값(옛 서버 문장 걸러 내기)은 사용자 문장이 아니다.
          if (line.contains('RegExp(') || line.contains('.contains(')) continue;
          fail('${f.path}: ${m.group(0)}');
        }
      }
    }
  });
}
