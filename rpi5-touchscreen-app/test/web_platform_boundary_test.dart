// 웹 배포(/kiosk/)와 네이티브(RPi) 빌드가 같은 소스를 쓰기 위한 경계 검사.
//
// 본선 준비 평가(9/21) P0: 설정 저장·음성 안내가 dart:io(File·Process)를
// 직접 써서 웹 빌드의 첫 진입·음성이 깨질 수 있었다. 플랫폼 입출력은
// *_io.dart / *_web.dart 쌍에만 두고, 나머지 코드는 조건부 import로만
// 닿게 한다. 새 코드가 경계를 넘으면 여기서 실패한다.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

String _name(File f) => f.uri.pathSegments.last;

void main() {
  test('dart:io는 *_io.dart 파일에서만 import한다', () {
    final offenders = [
      for (final f in _libFiles())
        if (RegExp(r'''import\s+['"]dart:io['"]''').hasMatch(f.readAsStringSync()) &&
            !_name(f).endsWith('_io.dart'))
          f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('dart:html은 *_web.dart 파일에서만 import한다', () {
    final offenders = [
      for (final f in _libFiles())
        if (RegExp(r'''import\s+['"]dart:html['"]''').hasMatch(f.readAsStringSync()) &&
            !_name(f).endsWith('_web.dart'))
          f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('*_io.dart는 웹 대안이 있는 조건부 import로만 쓰인다', () {
    final files = _libFiles();
    for (final io in files.where((f) => _name(f).endsWith('_io.dart'))) {
      final ioName = _name(io);
      final webName = ioName.replaceFirst(RegExp(r'_io\.dart$'), '_web.dart');
      expect(files.any((f) => _name(f) == webName), isTrue,
          reason: '$ioName에 짝이 되는 $webName이 없다');
      for (final user in files) {
        final src = user.readAsStringSync();
        if (!src.contains("'$ioName'")) continue;
        final pattern = RegExp(
          "'${RegExp.escape(ioName)}'" r'\s+if\s*\(dart\.library\.html\)\s*'
          "'${RegExp.escape(webName)}'",
        );
        expect(
          pattern.hasMatch(src),
          isTrue,
          reason: '${user.path}가 $ioName을 조건부 import 없이 쓴다',
        );
      }
    }
  });
}
