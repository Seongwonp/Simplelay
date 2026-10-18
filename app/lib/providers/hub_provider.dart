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

/// 설정 맨 아래 '개발자' 줄을 이 앱 실행 동안 열었는가 — 앱 정보 화면의 'SimpleLay' 이름을 [kDeveloperUnlockTaps]번
/// 누르면 열린다(평가 17차 10/18: 개발 모드 본체에서 '개발자' 줄이 가족에게 그대로 보였다). 앱을 다시 켜면 닫힌다.
/// 숨김일 뿐 접근 제한이 아니다 — 개발자 기능은 여전히 본체 개발자 모드·개발자 토큰이 막는다.
final developerUnlockedProvider = StateProvider<bool>((ref) => false);

/// 앱 정보 이름을 몇 번 눌러야 '개발자' 줄이 열리는지.
const kDeveloperUnlockTaps = 7;

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
