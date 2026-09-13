import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/dev_api_service.dart';
import 'rpi_api_provider.dart';

// ── 개발자 토큰 (서버 SIMPLELAY_DEV_TOKEN과 짝) ─────────────────────────────
//
// 일반 API 키와 따로 둔다 -- 권한이 다르다. 이 값이 없으면 개발자 API
// 클라이언트 자체를 만들지 않는다.

class DevTokenNotifier extends StateNotifier<String?> {
  DevTokenNotifier() : super(null) {
    _load();
  }

  /// 테스트용 -- 기기 저장소를 읽지 않고 값을 세운다.
  DevTokenNotifier.seeded(super.token);

  static const _key = 'dev_token';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    state = prefs.getString(_key);
  }

  Future<void> save(String token) async {
    final trimmed = token.trim();
    state = trimmed.isEmpty ? null : trimmed;
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, trimmed);
    }
  }

  Future<void> clear() => save('');
}

final devTokenProvider = StateNotifierProvider<DevTokenNotifier, String?>(
  (ref) => DevTokenNotifier(),
);

/// 서버 주소와 개발자 토큰이 모두 있을 때만 만든다.
///
/// 데모 모드 분기는 여기 없다 -- 개발자 API는 서버 쪽에서 이미 모의
/// 어댑터만 쓰고(Phase 2 계약), 폰의 데모 모드는 일반 실행 경로의 개념이다.
final devApiServiceProvider = Provider<DevApiService?>((ref) {
  final url = ref.watch(rpiUrlProvider);
  final token = ref.watch(devTokenProvider);
  if (url == null || url.isEmpty || token == null) return null;
  final service = DevApiService(
    url,
    devToken: token,
    apiKey: ref.watch(rpiApiKeyProvider),
    client: ref.watch(rpiHttpClientProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});
