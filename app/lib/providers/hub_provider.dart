import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hub.dart';
import 'rpi_api_provider.dart';

/// 허브 `/status` 중 탭 구조가 쓰는 값. 닿지 않거나 실패하면 null.
///
/// 연결이 바뀔 때마다 다시 묻는다. 서버의 개발자 모드는 환경 변수라 실행
/// 중에 바뀌지 않으므로 주기 조회는 하지 않는다.
final hubStatusProvider = FutureProvider<HubStatus?>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  final connection = ref.watch(rpiConnectionProvider);
  if (api == null || connection != RpiConnectionState.connected) return null;
  try {
    return await api.hubStatus();
  } catch (_) {
    return null;
  }
});

/// 서버가 개발자 모드를 켰는가. 모르면(연결 전·실패·옛 서버) **꺼진 것**으로 본다.
final developerModeProvider = Provider<bool>(
  (ref) => ref.watch(hubStatusProvider).valueOrNull?.developerMode ?? false,
);

/// 개발자 탭은 허브가 허용할 때만 표시한다.
final showDeveloperTabProvider = Provider<bool>(
  (ref) => ref.watch(developerModeProvider),
);

/// 허브에 저장된 위치. 실패는 null(모름 -- '위치 없음'과 구분한다).
final hubLocationProvider = FutureProvider.autoDispose<HubLocation?>((ref) async {
  final api = ref.watch(rpiApiServiceProvider);
  if (api == null) return null;
  try {
    return await api.hubLocation();
  } catch (_) {
    return null;
  }
});
