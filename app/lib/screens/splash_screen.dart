import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/startup_provider.dart';
import '../theme/app_colors.dart';

/// 앱 이름을 한 번 보여주고, 준비가 끝나면 바로 비켜준다.
///
/// 안드로이드 네이티브 스플래시는 흰 배경 하나다. 여기서 갑자기 그라데이션이나
/// 카드가 나오면 앱을 두 번 켠 것처럼 보이므로, 같은 바탕에 글자만 얹는다.
/// 반짝임·회전·억지 지연은 넣지 않는다 -- 기다리게 만드는 연출은 기다림을
/// 짧게 만들지 않는다.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  /// 결정은 한 번뿐이다. provider가 다시 값을 내도 화면을 또 바꾸지 않는다.
  bool _routed = false;

  @override
  void initState() {
    super.initState();
    _decideOnce();
  }

  Future<void> _decideOnce() async {
    late final String route;
    try {
      route = await ref.read(startupRouteProvider.future);
    } catch (_) {
      // 시작 준비가 실패해도 시작 화면에 갇히지는 않는다. 홈은 가전이
      // 0대인 상태를 정상으로 그릴 수 있다.
      route = '/';
    }
    if (!mounted || _routed) return;
    _routed = true;
    context.go(route);
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: SplashWordmark()),
      );
}

/// 시작 화면의 글자. 골든이 이것만 따로 찍는다.
class SplashWordmark extends StatelessWidget {
  const SplashWordmark({super.key});

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'SimpleLay',
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '복잡한 가전을 더 간단하게',
            style: TextStyle(fontSize: 16, color: context.appMuted),
          ),
        ],
      );
}
