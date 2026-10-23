import 'package:flutter/material.dart';
import '../widgets/estop_banner.dart';
import '../widgets/voice_stop_indicator.dart';
import 'app_shell.dart' show RunningStopStrip;

/// 탭 밖 관리 화면에서도 진행 중/상태 미확인 작업의 정지를 잃지 않는다.
class StandaloneTaskFrame extends StatelessWidget {
  const StandaloneTaskFrame({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: child,
        bottomNavigationBar: const SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            EstopBanner(), VoiceStopIndicator(), RunningStopStrip(),
          ]),
        ),
      );
}
