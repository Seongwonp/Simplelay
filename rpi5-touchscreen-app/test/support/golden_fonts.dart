// 골든(눈으로 보는 화면 이미지) 시험이 쓰는 글꼴을 싣는다 — 세 골든 시험이 같은 규칙을 쓴다.
//
// 아이콘 글꼴은 Flutter SDK 안에 있다. 예전에는 한 PC의 고정 경로(C:\flutter\flutter\…)를
// 읽어 다른 PC에서 시험이 돌지 않거나(B6, 2026-10-15) 아이콘이 네모로 찍혔다.
// 순서: FLUTTER_ROOT(flutter 도구가 넣어 준다) → 시험 실행 파일(flutter_tester)이 놓인 SDK 경로.
// 둘 다 없으면 네모 아이콘을 조용히 찍지 않고 바로 실패한다.
import 'dart:io';

import 'package:flutter/services.dart';

const _iconRel = 'bin/cache/artifacts/material_fonts/materialicons-regular.otf';

/// 아이콘 글꼴 파일. 찾지 못하면 어디를 봤는지 적어 실패한다.
File materialIconsFont() {
  final tried = <String>[];
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) {
    final f = File('$root/$_iconRel');
    if (f.existsSync()) return f;
    tried.add(f.path);
  }
  // flutter_tester는 <SDK>/bin/cache/artifacts/engine/<플랫폼>/ 아래에 있다.
  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/$_iconRel');
    if (f.existsSync()) return f;
    tried.add(f.path);
    dir = dir.parent;
  }
  throw StateError('아이콘 글꼴을 찾지 못했어요(FLUTTER_ROOT를 확인해 주세요): ${tried.join(', ')}');
}

/// 아이콘 글꼴과 한글 글꼴(맑은 고딕)을 'MaterialIcons'·'Malgun'으로 싣는다.
Future<void> loadGoldenFonts() async {
  final icons = materialIconsFont().readAsBytesSync();
  await (FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(icons.buffer))))
      .load();
  final korean = File(r'C:\Windows\Fonts\malgun.ttf').readAsBytesSync();
  await (FontLoader('Malgun')
        ..addFont(Future.value(ByteData.view(korean.buffer))))
      .load();
}
