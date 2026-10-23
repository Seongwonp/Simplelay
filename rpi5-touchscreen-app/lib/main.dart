import 'package:flutter/material.dart';

import 'screens/kiosk_screen.dart';
import 'services/kiosk_settings_store.dart';
import 'theme/kiosk_colors.dart';

void main() => runApp(const SimpleLayKioskApp());

class SimpleLayKioskApp extends StatelessWidget {
  const SimpleLayKioskApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SimpleLay',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: KioskColors.brightness,
          scaffoldBackgroundColor: KioskColors.bg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: KioskColors.primary,
            brightness: KioskColors.brightness,
          ),
        ),
        // 설정 영속화는 프로덕션에서만 — 테스트는 미주입(세션 한정)으로
        // 실제 홈 디렉터리 파일을 건드리지 않는다
        home: KioskScreen(settings: KioskSettingsStore()),
      );
}
