import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'appliance_provider.dart';

/// 앱을 열었을 때 **어디로 갈지 한 번만** 정한다.
///
/// 예전에는 이 결정이 두 군데로 흩어져 있었다: `main()`이 온보딩 여부를 미리
/// 읽고, 홈은 가전 목록이 올라오기 전에 이미 그려졌다. 그래서 가전을 가진
/// 사람도 '아직 등록한 가전이 없어요'를 한 프레임 보고 나서 화면이 바뀌었다 --
/// 앱이 자기 데이터를 잃어버린 것처럼 보이는 순간이다.
///
/// 여기서 필요한 것이 다 올라온 뒤에 경로 하나를 돌려주고, 시작 화면은 그
/// 값이 올 때까지만 서 있는다. 임의의 지연은 넣지 않는다 -- 빠른 기기에서는
/// 그만큼 그냥 기다리는 시간이고, 느린 기기에서는 어차피 모자란다.
final startupRouteProvider = FutureProvider<String>((ref) async {
  await ref.watch(applianceStartupProvider.future);
  return await _onboardingDone() ? '/' : '/onboarding';
});

Future<bool> _onboardingDone() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('onboarding_done') ?? false;
  } catch (_) {
    // 저장소를 못 읽는다고 앱이 시작 화면에 갇히면 안 된다. 온보딩을 이미
    // 마친 사람에게 한 번 더 보여주는 쪽이, 아무 데도 못 가는 것보다 낫다.
    return false;
  }
}
