// 상태 배지 글자 대비(평가 3차 2026-10-18 — 기록의 회색 '연습' 배지가 흐렸다).
//
// 배지는 화면에 그려진 그대로 잰다: 글자색 대 (배지 면 → 카드·바탕 위에 겹친 색).
// 모든 갈래 4.5:1 이상, 회색(중립) 배지는 보조 글씨 목표(7:1)까지 — 회색이 결과를 말하는 자리다
// ('연습'·'받았어요'·'이미 그래요').
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/theme/app_colors.dart';
import 'package:simplelay/theme/app_theme.dart';
import 'package:simplelay/widgets/status_badge.dart';

import 'contrast_test.dart' show contrast;

void main() {
  for (final dark in [false, true]) {
    for (final tone in BadgeTone.values) {
      testWidgets('${dark ? '다크' : '라이트'} ${tone.name} 배지 대비', (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          home: Scaffold(
            body: Center(child: StatusBadge(icon: Icons.science_outlined, label: '연습', tone: tone)),
          ),
        ));
        final text = tester.widget<Text>(find.text('연습'));
        final box = tester.widget<Container>(
            find.ancestor(of: find.text('연습'), matching: find.byType(Container)).first);
        final fill = (box.decoration as BoxDecoration).color ?? Colors.transparent;
        final fg = text.style!.color!;
        final grounds = dark
            ? [AppColors.background, AppColors.surfaceLow]
            : [AppColors.backgroundLight, AppColors.surfaceLowLight];
        final need = tone == BadgeTone.neutral ? 7.0 : 4.5;
        for (final g in grounds) {
          final c = contrast(fg, Color.alphaBlend(fill, g));
          expect(c, greaterThanOrEqualTo(need), reason: '$tone on $g: ${c.toStringAsFixed(2)}');
        }
      });
    }
  }
}
