import 'package:multicast_dns/multicast_dns.dart';

/// Android의 시스템 DNS 리졸버는 `.local`(mDNS) 호스트명을 해석하지 못한다 —
/// `http://simplelay.local:8000` 기본값이 대부분의 안드로이드 폰에서 영원히
/// unreachable이었던 원인. 이 리졸버가 앱에서 직접 mDNS A(IPv4) 질의를 보내
/// IP를 알아내고, 호출자는 알아낸 IP로 URL을 교체해 저장한다.
///
/// 실패(타임아웃·소켓 오류·미지원 기기)는 전부 null — 호출자는 홈 화면의
/// "주소 입력" 동선으로 폴백한다. 일부 기기는 멀티캐스트 수신에 WifiManager
/// MulticastLock이 필요해 순수 Dart 구현으로는 응답을 못 받을 수 있다.
class MdnsResolver {
  Future<String?> resolveIPv4(
    String host, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final client = MDnsClient();
    try {
      await client.start();
      final stream = client
          .lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(host),
          )
          .timeout(timeout);
      await for (final record in stream) {
        return record.address.address;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.stop();
    }
  }
}
