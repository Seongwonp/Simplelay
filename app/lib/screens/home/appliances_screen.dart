part of '../home_screen.dart';

/// 가전 탐색만 담당한다. 상태·등록·상세 연결은 홈과 같은 판정을 공유한다.
class AppliancesScreen extends StatelessWidget {
  const AppliancesScreen({super.key});

  @override
  Widget build(BuildContext context) => const HomeScreen(appliancesOnly: true);
}
