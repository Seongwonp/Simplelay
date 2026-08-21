import 'package:flutter_test/flutter_test.dart';
import 'package:simplelay/providers/rpi_api_provider.dart';

void main() {
  group('normalizeRpiUrl — 스킴·포트 없는 입력도 완전한 URL로', () {
    test('IP만 입력하면 http://와 :8000을 채운다', () {
      expect(normalizeRpiUrl('192.168.0.5'), 'http://192.168.0.5:8000');
    });

    test('호스트명 + 포트는 스킴만 채운다', () {
      expect(normalizeRpiUrl('rpi5.local:9000'), 'http://rpi5.local:9000');
    });

    test('완전한 URL은 그대로 둔다', () {
      expect(
        normalizeRpiUrl('http://192.168.0.42:8000'),
        'http://192.168.0.42:8000',
      );
    });

    test('앞뒤 공백과 트레일링 슬래시를 정리한다', () {
      expect(
        normalizeRpiUrl('  http://192.168.0.5:8000/  '),
        'http://192.168.0.5:8000',
      );
    });

    test('빈 입력은 빈 문자열 그대로 (호출자가 기본값 처리)', () {
      expect(normalizeRpiUrl('   '), '');
    });
  });
}
