import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 빌드 시점에 못 박는 데모 기본값 — `--dart-define=SIMPLELAY_DEMO=true`.
///
/// 백엔드의 `SIMPLELAY_*` env 게이트와 같은 규칙이다: 실기기 의존이나
/// 가짜 데이터는 명시적으로 켠 것만 동작하고, 기본은 꺼짐이다.
const kDemoBuildDefault = bool.fromEnvironment('SIMPLELAY_DEMO');

const _kDemoKey = 'demo_mode';

/// 데모 세션 — 가짜 센서·가짜 결과를 화면에 주입해도 되는 상태.
///
/// 예전에는 이 주입이 `kDebugMode`에만 걸려 있었다. 그러면 **실기기에 물린
/// 디버그 빌드**에서도 가짜 센서가 섞인다 — 실제로는 버튼이 안 눌린 실행이
/// 화면에서는 성공으로 끝난다. 폐루프의 존재 이유가 "눌림을 확인했는가"인데
/// 그 확인을 화면이 위조하게 되는 것이라, 디버그 빌드라는 이유만으로는
/// 켜지지 않게 했다.
class DemoModeNotifier extends StateNotifier<bool> {
  DemoModeNotifier() : super(kDemoBuildDefault) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(_kDemoKey) ?? kDemoBuildDefault;
  }

  Future<void> set(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDemoKey, value);
  }
}

final demoModeProvider = StateNotifierProvider<DemoModeNotifier, bool>(
  (_) => DemoModeNotifier(),
);
