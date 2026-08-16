import 'package:flutter/material.dart';

import 'screens/kiosk_screen.dart';
import 'theme/kiosk_colors.dart';

void main() => runApp(const SimpleLayKioskApp());

class SimpleLayKioskApp extends StatelessWidget {
  const SimpleLayKioskApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SimpleLay',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: KioskColors.bg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: KioskColors.primary,
            brightness: Brightness.dark,
          ),
        ),
        home: const KioskScreen(),
      );
}
