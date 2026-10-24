// 10/24 웹 점검: 요청 번호를 `nextInt(1 << 32)`로 만들었는데, 웹(JavaScript)에서는 `1 << 32`가 0이라 nextInt(0)이 던져
// 승인 '지금 하기'가 본체에 닿지 않고 화면이 회색이 됐다. 키오스크 코드는 웹에서도 돈다(브라우저 점검·미리보기).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay_touchscreen/services/kiosk_api_service.dart';

void main() {
  test('키오스크 코드에 웹에서 0이 되는 32비트 이상 시프트가 없다', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final text = f.readAsStringSync();
      if (RegExp(r'<<\s*(3[2-9]|[4-9]\d)').hasMatch(text)) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });

  test('요청 번호는 매번 다르고 형식이 같다', () {
    final a = newKioskRequestId();
    final b = newKioskRequestId();
    expect(a, startsWith('kiosk-'));
    expect(a, isNot(b));
  });
}
