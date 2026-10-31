import '../providers/rpi_api_provider.dart' show normalizeRpiUrl;

/// 본체 QR의 내용(`simplelay://pair?host=...&code=...`, rpi/api/pairing.py).
///
/// 앱 안 스캐너·딥링크·코드 칸에 붙여 넣은 값이 모두 이 규칙 하나로 판단한다.
class PairingQr {
  const PairingQr({required this.host, required this.code});

  /// 정규화한 본체 주소.
  final String host;
  final String code;

  /// 본체 연결용 QR이 아니면 null.
  static PairingQr? tryParse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'simplelay' || uri.host != 'pair') {
      return null;
    }
    final code = uri.queryParameters['code'] ?? '';
    final host = normalizeRpiUrl(uri.queryParameters['host'] ?? '');
    if (!isPairingCode(code) || !isPairingHost(host)) return null;
    return PairingQr(host: host, code: code);
  }
}

const kNotPairingQrMessage = '본체 연결용 QR이 아니에요. 본체 화면의 QR을 다시 찍어 주세요.';

bool isPairingCode(String code) => RegExp(r'^[0-9]{6}$').hasMatch(code);

/// 연결 코드를 보내도 되는 모양의 주소인가. 정규화한 값을 받는다.
bool isPairingHost(String host) {
  final uri = Uri.tryParse(host);
  return uri != null &&
      ['http', 'https'].contains(uri.scheme) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      (uri.path.isEmpty || uri.path == '/');
}
